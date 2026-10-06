import CryptoKit
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
  init(directory: URL? = nil) throws {
    self.directory = try directory ?? Self.location()
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    guard
      sqlite3_open_v2(
        self.directory.appendingPathComponent("monthly.sqlite").path, &db,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else { throw AppError("数据库无法打开 / Cannot open database") }
    sqlite3_busy_timeout(db, 15_000)
    try withBusyRetry {
      // journal_mode=WAL 是启动期重入点：已是 WAL 时保持原样（只读查询），避免并发启动时争抢写锁。
      if try journalMode() != "wal" { try exec("PRAGMA journal_mode=WAL") }
      try exec("PRAGMA synchronous=FULL")
      try exec(
        "CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)")
      try exec("BEGIN IMMEDIATE")
      do {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM state", -1, &st, nil) == SQLITE_OK else {
          throw error()
        }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { throw error() }
        if sqlite3_column_int(st, 0) == 0 { try write(State()) }
        try exec("COMMIT")
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
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
  /// 数据库忙时有限重试（最多 9 次，间隔递增、封顶 0.5 秒）；非忙碌类错误直接抛出。
  /// WAL 模式下 COMMIT/写入撞见他人提交会立即返回 BUSY_SNAPSHOT（不等待 busy 超时），
  /// 只能整体重试事务；忙碌判定取自错误构造时捕获的标记，因为回滚会清除连接上的错误码。
  private func withBusyRetry<T>(_ body: () throws -> T) throws -> T {
    var attempt = 0
    while true {
      do { return try body() } catch let e as AppError {
        attempt += 1
        guard attempt < 10, e.busy else { throw e }
        Thread.sleep(forTimeInterval: min(0.5, 0.1 * Double(attempt)))
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
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT json FROM state WHERE id=1", -1, &st, nil) == SQLITE_OK
    else { throw error() }
    defer { sqlite3_finalize(st) }
    guard sqlite3_step(st) == SQLITE_ROW, let ptr = sqlite3_column_blob(st, 0) else {
      throw error()
    }
    let s = try JSONDecoder().decode(
      State.self, from: Data(bytes: ptr, count: Int(sqlite3_column_bytes(st, 0))))
    try Engine.validate(s)
    return s
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
        try operation(&s)
        try Engine.validate(s)
        s.updatedAt = Date()
        try write(s)
        try exec("COMMIT")
        return s
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
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
