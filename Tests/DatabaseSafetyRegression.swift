import Foundation
import SQLite3

/// Headless, isolated persistence tests. No real App Group or app process is accessed.
@main struct DatabaseSafetyRegression {
  struct Failure: Error, CustomStringConvertible { let description: String }
  static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(description: message) }
  }
  @discardableResult static func rejects(_ operation: () throws -> Void) throws -> Error {
    var failure: Error?
    do { try operation() } catch { failure = error }
    guard let failure else { throw Failure(description: "Unsafe operation unexpectedly succeeded") }
    return failure
  }
  static func sql(_ database: OpaquePointer?, _ statement: String) throws {
    try expect(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed")
  }
  static func openRaw(_ file: URL) throws -> OpaquePointer {
    var result: OpaquePointer?
    try expect(sqlite3_open(file.path, &result) == SQLITE_OK && result != nil, "Fixture open failed")
    return result!
  }
  static func writeRaw(_ payload: Data, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let raw = try openRaw(directory.appendingPathComponent("monthly.sqlite"))
    defer { sqlite3_close(raw) }
    try sql(raw, "CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL)")
    var statement: OpaquePointer?
    try expect(sqlite3_prepare_v2(raw, "INSERT INTO state VALUES(1, ?)", -1, &statement, nil) == SQLITE_OK, "Fixture prepare failed")
    defer { sqlite3_finalize(statement) }
    let bind = payload.withUnsafeBytes {
      sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    try expect(bind == SQLITE_OK && sqlite3_step(statement) == SQLITE_DONE, "Fixture insert failed")
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("monthly-database-safety-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try openingSafety(root)
    try applicationInitialization(root)
    try concurrentInitialization(root)
    try unchangedTimestamps(root)
    try lockContention(root)
    try dateDerivations()
    print("PASS Database: safe default/pristine-only initialization; corrupt/empty/future schema preserved; exact read payload; read-only access; no-op timestamps; bounded busy failure/retry; month/day/timezone derivations")
  }

  static func openingSafety(_ root: URL) throws {
    let fm = FileManager.default
    let missing = root.appendingPathComponent("missing/Monthly")
    try rejects { _ = try Database(directory: missing) }
    try rejects { _ = try Database(directory: missing, readOnly: true) }
    try expect(!fm.fileExists(atPath: root.path), "Default open created a missing directory")

    let fixtures: [(String, Data?)] = [
      ("zero", nil), ("missing-table", nil), ("missing-row", nil),
      ("corrupt-sqlite", nil), ("corrupt-json", Data("{broken".utf8)),
      ("future-schema", Data("{\"schemaVersion\":2,\"rulesVersion\":1}".utf8)),
      ("future-rules", Data("{\"schemaVersion\":1,\"rulesVersion\":2}".utf8))
    ]
    for (name, payload) in fixtures {
      let directory = root.appendingPathComponent(name)
      let file = directory.appendingPathComponent("monthly.sqlite")
      if let payload {
        try writeRaw(payload, to: directory)
      } else {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        switch name {
        case "zero": try Data().write(to: file)
        case "corrupt-sqlite": try Data("not a database".utf8).write(to: file)
        default:
          let raw = try openRaw(file)
          do {
            try sql(raw, name == "missing-row"
              ? "CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)"
              : "CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES('keep')")
          } catch { sqlite3_close(raw); throw error }
          sqlite3_close(raw)
        }
      }
      let bytes = try Data(contentsOf: file)
      let names = try fm.contentsOfDirectory(atPath: directory.path).sorted()
      for (create, readOnly) in [(false, false), (true, false), (false, true)] {
        let error = try rejects {
          _ = try Database(directory: directory, createIfMissing: create, readOnly: readOnly)
        }
        try expect(error is AppError, "Persistence failure did not produce a user-facing error")
        if name.hasPrefix("future-") {
          try expect(error.localizedDescription.contains("Unsupported save version"), "Future save was not identified clearly")
        }
        try expect(try Data(contentsOf: file) == bytes, "Rejected \(name) changed database bytes")
        try expect(try fm.contentsOfDirectory(atPath: directory.path).sorted() == names, "Rejected \(name) created extra files")
      }
    }
    let evidence = root.appendingPathComponent("old-evidence")
    try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
    try Data("existing attachment".utf8).write(to: evidence.appendingPathComponent("attachment.pdf"))
    try rejects { _ = try Database(directory: evidence, createIfMissing: true) }
    try expect(!fm.fileExists(atPath: evidence.appendingPathComponent("monthly.sqlite").path), "Existing files were mistaken for a new store")
  }

  static func applicationInitialization(_ root: URL) throws {
    let key = "GAOYUEGONG_TEST_DIRECTORY"
    let previous = ProcessInfo.processInfo.environment[key]
    defer {
      if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
    }
    let fm = FileManager.default
    let directory = root.appendingPathComponent("app-initialization")
    setenv(key, directory.path, 1)
    try rejects { _ = try Database.openForApplication(hasExistingUserSettings: true) }
    try expect(!fm.fileExists(atPath: directory.path), "Prior settings allowed a blank replacement")
    do {
      let first = try Database.openForApplication(hasExistingUserSettings: false)
      try first.transaction { $0.preferences.privacy = true }
      let reopened = try Database.openForApplication(hasExistingUserSettings: true)
      try expect(try reopened.read().preferences.privacy, "Application open lost existing settings")
    }
    try fm.removeItem(at: directory.appendingPathComponent("monthly.sqlite"))
    try rejects { _ = try Database.openForApplication(hasExistingUserSettings: true) }
    try expect(!fm.fileExists(atPath: directory.appendingPathComponent("monthly.sqlite").path), "Missing prior store was recreated")

    let evidence = root.appendingPathComponent("app-evidence")
    try fm.createDirectory(at: evidence.appendingPathComponent("Backups"), withIntermediateDirectories: true)
    setenv(key, evidence.path, 1)
    try rejects { _ = try Database.openForApplication(hasExistingUserSettings: false) }
    try expect(!fm.fileExists(atPath: evidence.appendingPathComponent("monthly.sqlite").path), "Backup evidence was ignored")
  }

  static func unchangedTimestamps(_ root: URL) throws {
    let directory = root.appendingPathComponent("timestamp")
    let now = Date()
    let benefit = BenefitItem(name: "Fixture reward")
    var seeded = State()
    seeded.preferences.timezone = "Asia/Shanghai"
    seeded.updatedAt = Date(timeIntervalSince1970: 1_000_000)
    seeded.pet.settledAt = now
    seeded.benefits = [benefit]
    seeded.tombstones = ["first", "second", "third"]
    seeded.pet.titles = ["title-a", "title-b", "title-c"]
    seeded.pet.furniture = [0, 1, 2]
    seeded.pet.displayed = [0, 1, 2]
    try Engine.claim(&seeded, benefitID: benefit.id, date: now, now: now)
    let original = try JSONEncoder().encode(seeded)
    try writeRaw(original, to: directory)
    for _ in 0..<4 {
      let connection = try Database(directory: directory)
      let before = try connection.readRecord()
      try expect(before.payload == original, "readRecord re-encoded the stored payload")
      let returned = try connection.transaction {
        try Engine.claim(&$0, benefitID: benefit.id, date: now, now: now)
        $0.tombstones = Set($0.tombstones.sorted().reversed())
        $0.pet.titles = Set($0.pet.titles.sorted().reversed())
        $0.pet.displayed = Set($0.pet.displayed.sorted().reversed())
        $0.updatedAt = Date()
      }
      let after = try connection.readRecord()
      try expect(after.payload == original, "No-op/repeated claim rewrote saved bytes")
      try expect(returned.updatedAt == seeded.updatedAt && after.state.updatedAt == seeded.updatedAt, "No-op changed business timestamp")
      try expect(after.state.claims.count == 1 && after.state.rewards.count == 1, "Repeated claim granted twice")
    }
    let writer = try Database(directory: directory)
    try writer.transaction { $0.benefits[0].name = "Changed reward" }
    let changed = try writer.readRecord()
    try expect(changed.state.updatedAt > seeded.updatedAt && changed.payload != original, "Real edit did not advance content revision")
    let reader = try Database(directory: directory, readOnly: true)
    try expect(try reader.readRecord().payload == changed.payload, "Read-only connection did not read latest bytes")
    try rejects { try reader.transaction { $0.benefits.removeAll() } }
    try expect(try writer.readRecord().payload == changed.payload, "Read-only action modified data")
  }

  final class Initializers {
    let lock = NSLock()
    var succeeded: Set<String> = []
    func record(_ key: String) { lock.lock(); defer { lock.unlock() }; succeeded.insert(key) }
  }
  static func concurrentInitialization(_ root: URL) throws {
    let directory = root.appendingPathComponent("concurrent-initialization")
    let result = Initializers()
    DispatchQueue.concurrentPerform(iterations: 12) { index in
      do {
        let database = try Database(directory: directory, createIfMissing: true)
        let key = "initializer-\(index)"
        try database.transaction { $0.tombstones.insert(key) }
        result.record(key)
      } catch {
        // An initializer observing a file before its first commit may fail safely and retry later.
      }
    }
    try expect(!result.succeeded.isEmpty, "No exclusive initializer succeeded")
    let database = try Database(directory: directory)
    let state = try database.read()
    try expect(state.tombstones == result.succeeded, "A concurrent initializer replaced previously committed data")
  }

  static func lockContention(_ root: URL) throws {
    let directory = root.appendingPathComponent("busy")
    let database = try Database(directory: directory, createIfMissing: true, busyTimeoutMilliseconds: 5)
    try database.transaction { $0.preferences.privacy = true }
    let original = try database.readRecord()
    let holder = try openRaw(directory.appendingPathComponent("monthly.sqlite"))
    defer { sqlite3_close(holder) }
    try sql(holder, "BEGIN IMMEDIATE")
    let began = ProcessInfo.processInfo.systemUptime
    let error = try rejects { try database.transaction { $0.preferences.privacy = false } }
    let elapsed = ProcessInfo.processInfo.systemUptime - began
    try expect((error as? AppError)?.busy == true, "Locked database lost busy classification")
    try expect(elapsed < 1.0, "Injected busy retries exceeded bounded budget")
    try expect(try database.readRecord().payload == original.payload, "Busy failure overwrote data")
    try sql(holder, "ROLLBACK")
    try database.transaction { $0.preferences.privacy = false }
    try expect(try !database.read().preferences.privacy, "Retry after lock release failed")
  }

  static func dateDerivations() throws {
    var state = State()
    state.preferences.timezone = "Asia/Shanghai"
    let timestamp = state.updatedAt
    let before = ISO8601DateFormatter().date(from: "2026-10-31T15:59:59Z")!
    let after = ISO8601DateFormatter().date(from: "2026-10-31T16:00:00Z")!
    let benefit = BenefitItem(name: "Month transition reward")
    state.benefits = [benefit]
    state.preferences.game = false
    try Engine.claim(&state, benefitID: benefit.id, date: before, now: before)
    try expect(Engine.dueBenefits(state, now: before).isEmpty, "Pre-midnight claim still due")
    try expect(Engine.dueBenefits(state, now: after).count == 1, "Midnight did not advance daily period")
    try expect(Engine.month(before, state) == "2026-10" && Engine.month(after, state) == "2026-11", "Month transition used device timezone")
    var subscription = Subscription(name: "Month-end subscription")
    subscription.plans[0].anchor = Engine.date("2026-01-31", state)
    subscription.plans[0].start = subscription.plans[0].anchor
    state.subscriptions = [subscription]
    try expect(Engine.day(Engine.dateFor(subscription.current, index: 1, state: state), state) == "2026-02-28", "Month-end February due date drifted")
    try expect(Engine.day(Engine.dateFor(subscription.current, index: 2, state: state), state) == "2026-03-31", "Month-end March due date drifted")
    _ = Engine.upcoming(state, now: after, days: 7)
    _ = Engine.pending(state, now: after.addingTimeInterval(172800))
    try expect(state.updatedAt == timestamp, "Date-only derivation changed business timestamp")
    state.preferences.timezone = "America/Los_Angeles"
    try expect(Engine.month(after, state) == "2026-10", "Stored timezone change did not affect derivation")
  }
}
