import CryptoKit
import Darwin
import Foundation
import SQLite3

struct BackupEnvelope: Codable {
  var version = 1
  var appVersion = AppInfo.version
  var createdAt = Date()
  var payload: Data
  var sha256: String
}
final class Database {
  static let groupID = "5G96498KGJ.com.gaoseries.GaoYueGong"
  let directory: URL
  private var db: OpaquePointer?
  static func location() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["GAOYUEGONG_TEST_DIRECTORY"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    else { throw AppError("共享容器不可用，请重新安装签名版本 / Shared container unavailable") }
    return url.appendingPathComponent("Monthly", isDirectory: true)
  }
  /// Only the app may initialize a genuinely new store; extensions always open existing data.
  static func openForApplication(hasExistingUserSettings: Bool) throws -> Database {
    let directory = try location()
    let file = directory.appendingPathComponent("monthly.sqlite")
    if FileManager.default.fileExists(atPath: file.path) {
      return try Database(directory: directory)
    }
    guard !hasExistingUserSettings else {
      throw AppError("原有数据库缺失，请从备份恢复；不会创建空白资料 / Existing database missing; restore a backup")
    }
    return try Database(directory: directory, createIfMissing: true)
  }
  init(
    directory: URL? = nil, createIfMissing: Bool = false, readOnly: Bool = false,
    busyTimeoutMilliseconds: Int = 250
  ) throws {
    self.directory = try directory ?? Self.location()
    let fm = FileManager.default
    let file = self.directory.appendingPathComponent("monthly.sqlite")
    var createdNewFile = false
    if !fm.fileExists(atPath: file.path) {
      guard createIfMissing, !readOnly else {
        throw AppError("数据库缺失，已保留现有资料；请打开 App 检查或从备份恢复 / Database missing; existing files preserved")
      }
      var isDirectory: ObjCBool = false
      if fm.fileExists(atPath: self.directory.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue, try fm.contentsOfDirectory(atPath: self.directory.path).isEmpty else {
          throw AppError("发现已有资料但数据库缺失，请从备份恢复 / Existing files found without a database; restore a backup")
        }
      } else {
        try fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
      }
      // O_EXCL prevents a concurrent initializer's file from being replaced or truncated.
      let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
      guard descriptor >= 0 else {
        throw AppError("无法安全初始化数据库，请重试；现有文件未被替换 / Could not exclusively initialize database; retry")
      }
      Darwin.close(descriptor)
      createdNewFile = true
    }
    do {
      let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
      guard sqlite3_open_v2(file.path, &db, flags, nil) == SQLITE_OK else {
        throw AppError("数据库无法打开，现有资料已保留 / Cannot open database; existing data preserved")
      }
      // Four attempts with 250 ms waits plus short backoff keep the default lock budget below 2 s.
      sqlite3_busy_timeout(db, Int32(max(0, min(250, busyTimeoutMilliseconds))))
      if !createdNewFile {
        // Validate before any PRAGMA/schema writes, including when a caller permits initialization.
        _ = try readRecord()
      }
      if !readOnly {
        try withBusyRetry {
          if try journalMode() != "wal" { try exec("PRAGMA journal_mode=WAL") }
          try exec("PRAGMA synchronous=FULL")
        }
      }
      if createdNewFile {
        try withBusyRetry {
          try exec("BEGIN IMMEDIATE")
          do {
            try exec("CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)")
            try write(State())
            try exec("COMMIT")
          } catch {
            try? exec("ROLLBACK")
            throw error
          }
        }
      }
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }
  deinit { sqlite3_close(db) }
  private func journalMode() throws -> String {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &st, nil) == SQLITE_OK else {
      throw error()
    }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { throw error() }
    return String(cString: c).lowercased()
  }
  private var busy: Bool { sqlite3_errcode(db) & 0xFF == SQLITE_BUSY }
  /// 数据库忙时最多 4 次尝试；只重试 busy，不能把读取失败当成空状态。
  /// WAL 模式下 COMMIT/写入撞见他人提交会立即返回 BUSY_SNAPSHOT（不等待 busy 超时），
  /// 只能整体重试事务；忙碌判定取自错误构造时捕获的标记，因为回滚会清除连接上的错误码。
  private func withBusyRetry<T>(_ body: () throws -> T) throws -> T {
    var attempt = 0
    while true {
      do { return try body() } catch let e as AppError {
        attempt += 1
        guard attempt < 4, e.busy else { throw e }
        Thread.sleep(forTimeInterval: 0.025 * Double(attempt))
      }
    }
  }
  private func error() -> AppError {
    var e = AppError(
      "数据库操作失败 / Database error \(sqlite3_errcode(db)): \(String(cString:sqlite3_errmsg(db)))"
    )
    e.busy = busy
    return e
  }
  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      var e = error()
      e.message += " [\(sql.prefix(40))]"
      throw e
    }
  }
  func read() throws -> State {
    try readRecord().state
  }
  /// State and its exact stored bytes come from the same SELECT snapshot.
  /// Consumers hash payload, not a re-encoding of Set-containing State values.
  func readRecord() throws -> (state: State, payload: Data) {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT json FROM state WHERE id=1", -1, &st, nil) == SQLITE_OK
    else { throw error() }
    defer { sqlite3_finalize(st) }
    let result = sqlite3_step(st)
    guard result != SQLITE_DONE else {
      throw AppError("业务记录缺失，不会创建空白资料；请从备份恢复 / Saved record missing; restore a backup")
    }
    guard result == SQLITE_ROW else {
      throw error()
    }
    guard let ptr = sqlite3_column_blob(st, 0), sqlite3_column_bytes(st, 0) > 0 else {
      throw AppError("业务记录为空，已保留原文件 / Saved record is empty; original file preserved")
    }
    let payload = Data(bytes: ptr, count: Int(sqlite3_column_bytes(st, 0)))
    struct Version: Decodable { var schemaVersion: Int; var rulesVersion: Int }
    let version: Version
    do { version = try JSONDecoder().decode(Version.self, from: payload) }
    catch { throw AppError("业务数据无法解码，已保留原文件 / Saved data is unreadable; original file preserved") }
    guard version.schemaVersion == 1, version.rulesVersion == 1 else {
      throw AppError("存档版本不受支持，请使用匹配的应用版本；原文件已保留 / Unsupported save version; original file preserved (schema \(version.schemaVersion), rules \(version.rulesVersion))")
    }
    let s: State
    do { s = try JSONDecoder().decode(State.self, from: payload) }
    catch { throw AppError("业务数据无法解码，已保留原文件 / Saved data is unreadable; original file preserved") }
    try Engine.validate(s)
    return (s, payload)
  }
  private func write(_ s: State) throws {
    let data = try JSONEncoder().encode(s)
    var st: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state(id,json) VALUES(1,?)", -1, &st, nil)
        == SQLITE_OK
    else { throw error() }
    defer { sqlite3_finalize(st) }
    let rc = data.withUnsafeBytes {
      sqlite3_bind_blob(
        st, 1, $0.baseAddress, Int32(data.count),
        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard rc == SQLITE_OK, sqlite3_step(st) == SQLITE_DONE else { throw error() }
  }
  // BEGIN IMMEDIATE serializes cross-process read-modify-write. Never save a stale view snapshot.
  @discardableResult func transaction(_ operation: (inout State) throws -> Void) throws -> State {
    try withBusyRetry {
      try exec("BEGIN IMMEDIATE")
      do {
        var s = try read()
        let previousUpdatedAt = s.updatedAt
        let previousContent = try Self.canonicalContent(s)
        try operation(&s)
        try Engine.validate(s)
        if try Self.canonicalContent(s) != previousContent {
          s.updatedAt = Date()
          try write(s)
        } else {
          s.updatedAt = previousUpdatedAt
        }
        try exec("COMMIT")
        return s
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
  }
  /// Codable Sets are unordered. Normalize the three persisted Sets before comparing business data.
  private static func canonicalContent(_ state: State) throws -> Data {
    let encoded = try JSONEncoder().encode(state)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
      var pet = object["pet"] as? [String: Any]
    else { throw AppError("无法校验资料变更 / Cannot validate data changes") }
    object.removeValue(forKey: "updatedAt")
    object["tombstones"] = state.tombstones.sorted()
    pet["displayed"] = state.pet.displayed.sorted()
    pet["titles"] = state.pet.titles.sorted()
    object["pet"] = pet
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  static func backup(_ s: State) throws -> Data {
    let data = try JSONEncoder().encode(s)
    return try JSONEncoder().encode(
      BackupEnvelope(
        payload: data, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
  }
  static func decode(_ data: Data) throws -> (State, Date) {
    guard data.count < 50_000_000 else { throw AppError("备份文件过大 / Backup too large") }
    let b = try JSONDecoder().decode(BackupEnvelope.self, from: data)
    guard b.version == 1,
      b.sha256 == SHA256.hash(data: b.payload).map({ String(format: "%02x", $0) }).joined()
    else { throw AppError("备份版本或校验不匹配 / Invalid backup") }
    let s = try JSONDecoder().decode(State.self, from: b.payload)
    try Engine.validate(s)
    return (s, b.createdAt)
  }
  func snapshot() throws {
    let s = try read()
    let folder = directory.appendingPathComponent("Backups")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent("daily-\(Engine.day(Date(),s)).monthlybackup")
    guard !FileManager.default.fileExists(atPath: target.path) else { return }
    try Self.backup(s).write(to: target, options: .atomic)
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("daily-") }.sorted {
      $0.lastPathComponent > $1.lastPathComponent
    }
    for file in files.dropFirst(7) { try FileManager.default.removeItem(at: file) }
  }
  func restore(_ replacement: State) throws {
    try Engine.validate(replacement)
    try withBusyRetry {
      try exec("BEGIN IMMEDIATE")
      do {
        let folder = directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = try? read() {
          try Self.backup(old).write(
            to: folder.appendingPathComponent("before-restore-\(UUID()).monthlybackup"),
            options: .atomic)
        } else {
          var st: OpaquePointer?
          guard sqlite3_prepare_v2(db, "SELECT json FROM state WHERE id=1", -1, &st, nil) == SQLITE_OK
          else { throw error() }
          defer { sqlite3_finalize(st) }
          guard sqlite3_step(st) == SQLITE_ROW, let ptr = sqlite3_column_blob(st, 0) else {
            throw error()
          }
          let raw = Data(bytes: ptr, count: Int(sqlite3_column_bytes(st, 0)))
          try raw.write(
            to: folder.appendingPathComponent("unreadable-\(UUID()).json"), options: .atomic)
        }
        try write(replacement)
        try exec("COMMIT")
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
  }
  func erase() throws {
    _ = try transaction { $0 = State() }
    let folder = directory.appendingPathComponent("Backups")
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
    try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    try exec("VACUUM")
  }
}
