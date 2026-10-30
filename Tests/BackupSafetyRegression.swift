import Foundation
import SQLite3

enum AppDataLocations {
  static var appSupport: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_APP"]!) }
  static var groupContainer: URL? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_GROUP"]!) }
}

/// Synthetic files and an in-memory preference adapter only; never touches real app domains.
@main struct BackupSafetyRegression {
  struct Failure: Error, CustomStringConvertible { let description: String }
  final class MemoryPreferences: BackupPreferenceAccess {
    var values: [BackupPreferenceDomain: [String: Any]] = [:]
    var writes = 0
    var failOnWrite: Int?
    func read(_ domain: BackupPreferenceDomain) throws -> [String: Any]? { values[domain] }
    func write(_ value: [String: Any]?, to domain: BackupPreferenceDomain) throws {
      writes += 1
      if writes == failOnWrite { throw Failure(description: "Injected preference write failure") }
      values[domain] = value
    }
  }
  struct CurrentFiles { var app: [String: String]; var group: [String: String] }
  static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(description: message) }
  }
  @discardableResult static func rejects(_ operation: () throws -> Void) throws -> Error {
    var failure: Error?
    do { try operation() } catch { failure = error }
    guard let failure else { throw Failure(description: "Unsafe backup operation unexpectedly succeeded") }
    return failure
  }
  static func sql(_ connection: OpaquePointer?, _ statement: String) throws {
    try expect(sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed")
  }
  static func raw(_ url: URL) throws -> OpaquePointer {
    var connection: OpaquePointer?
    try expect(sqlite3_open(url.path, &connection) == SQLITE_OK && connection != nil, "Fixture SQLite open failed")
    return connection!
  }
  static func replacePayload(at file: URL, transform: ([String: Any]) -> [String: Any]) throws {
    let connection = try raw(file)
    defer { sqlite3_close(connection) }
    var statement: OpaquePointer?
    try expect(sqlite3_prepare_v2(connection, "SELECT json FROM state WHERE id=1", -1, &statement, nil) == SQLITE_OK, "Fixture read prepare failed")
    try expect(sqlite3_step(statement) == SQLITE_ROW, "Fixture state missing")
    let payload = Data(bytes: sqlite3_column_blob(statement, 0)!, count: Int(sqlite3_column_bytes(statement, 0)))
    sqlite3_finalize(statement)
    statement = nil
    let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
    let changed = try JSONSerialization.data(withJSONObject: transform(object), options: [.sortedKeys])
    try expect(sqlite3_prepare_v2(connection, "UPDATE state SET json=? WHERE id=1", -1, &statement, nil) == SQLITE_OK, "Fixture update prepare failed")
    defer { sqlite3_finalize(statement) }
    let bound = changed.withUnsafeBytes {
      sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    try expect(bound == SQLITE_OK && sqlite3_step(statement) == SQLITE_DONE, "Fixture state update failed")
  }
  static func currentFiles(app: URL, group: URL) throws -> CurrentFiles {
    try CurrentFiles(app: BackupIntegrity.manifest(app), group: BackupIntegrity.manifest(group))
  }
  static func verifyCurrent(_ before: CurrentFiles, app: URL, group: URL) throws {
    let after = try currentFiles(app: app, group: group)
    try expect(after.app == before.app && after.group == before.group, "Rejected restore changed existing files")
  }
  static func encodePreferences(_ value: [String: Any], to url: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url, options: .atomic)
  }
  static func refreshManifest(_ root: URL) throws {
    let file = root.appendingPathComponent("gqns-manifest.json")
    var manifest = try JSONDecoder().decode(BackupIntegrity.Manifest.self, from: Data(contentsOf: file))
    manifest.files = try BackupIntegrity.manifest(root)
    try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
  }
  static func zip(_ root: URL, to archive: URL) throws {
    let process = Process(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", root.path, archive.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let data = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try expect(process.terminationStatus == 0, "Fixture archive failed: " + (String(data: data, encoding: .utf8) ?? ""))
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("monthly-backup-safety-" + UUID().uuidString + ".noindex")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("App"), group = root.appendingPathComponent("Group")
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    try fm.createDirectory(at: group, withIntermediateDirectories: true)
    let environmentKeys = ["TEST_APP", "TEST_GROUP", "GQNS_RESTORE_ROOT"]
    let oldEnvironment = ProcessInfo.processInfo.environment
    defer {
      for key in environmentKeys {
        if let old = oldEnvironment[key] { setenv(key, old, 1) } else { unsetenv(key) }
      }
    }
    setenv("TEST_APP", app.path, 1)
    setenv("TEST_GROUP", group.path, 1)
    setenv("GQNS_RESTORE_ROOT", root.appendingPathComponent("Jobs").path, 1)
    let preferences = MemoryPreferences()
    preferences.values = [.standard: ["fixture": "archive-standard"], .module: ["fixture": "archive-module"]]
    let originalAccess = BackupIntegrity.preferences
    BackupIntegrity.preferences = preferences
    defer { BackupIntegrity.preferences = originalAccess }

    let document = Data("Public synthetic PDF and Word payload".utf8)
    try document.write(to: app.appendingPathComponent("paper.pdf"))
    try document.write(to: app.appendingPathComponent("paper.docx"))
    do {
      let database = try Database(directory: group.appendingPathComponent("Monthly"), createIfMissing: true)
      try database.transaction {
        $0.preferences.timezone = "Asia/Shanghai"
        $0.subscriptions = [Subscription(name: "Public backup fixture")]
      }
    }
    let auxiliary = try raw(group.appendingPathComponent("test.sqlite"))
    try sql(auxiliary, "PRAGMA journal_mode=WAL; CREATE TABLE t(value TEXT); INSERT INTO t VALUES('committed WAL data')")
    let archive = root.appendingPathComponent("backup.zip")
    do { _ = try AppBackupExport.export(appSupport: app, group: group, destination: archive) }
    catch { sqlite3_close(auxiliary); throw error }
    sqlite3_close(auxiliary)
    let (staged, manifest) = try AppBackupRestore.prepare(archive)
    try expect(manifest.files["AppGroupContainer/Monthly/monthly.sqlite"] != nil && manifest.files["preferences.plist"] != nil, "Export omitted essential data")
    try Data("new current document".utf8).write(to: app.appendingPathComponent("paper.pdf"))
    preferences.values = [.standard: ["fixture": "current-standard"], .module: ["fixture": "current-module"]]
    try AppBackupRestore.schedule(staged)
    let scheduled = try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: AppBackupRestore.pending))
    try AppBackupRestore.applyPending()
    try expect(try Data(contentsOf: app.appendingPathComponent("paper.pdf")) == document, "Roundtrip did not restore attachment")
    try expect(DailyBackup.integrityCheck(group.appendingPathComponent("test.sqlite")) == "ok", "WAL snapshot is corrupt")
    try expect(preferences.values[.standard]?["fixture"] as? String == "archive-standard" && preferences.values[.module]?["fixture"] as? String == "archive-module", "Roundtrip did not restore both preference domains")
    try expect(fm.fileExists(atPath: scheduled.safety.appendingPathComponent("ApplicationSupport/paper.pdf").path), "Successful restore did not retain safety files")

    try invalidArchives(archive: archive, root: root, app: app, group: group)
    try preferenceFailure(archive: archive, app: app, group: group, preferences: preferences)
    try crashRollback(archive: archive, root: root, app: app, group: group, preferences: preferences)
    try unreadableAttachment(archive: archive, app: app, group: group)

    let previousHash = try BackupIntegrity.hash(archive)
    try Data("not sqlite".utf8).write(to: group.appendingPathComponent("broken.sqlite"))
    try rejects { _ = try AppBackupExport.export(appSupport: app, group: group, destination: archive) }
    try expect(try BackupIntegrity.hash(archive) == previousHash, "Failed export replaced a known-good archive")
    let (tampered, _) = try AppBackupRestore.prepare(archive)
    try Data("tampered attachment".utf8).write(to: tampered.appendingPathComponent("ApplicationSupport-Monthly/paper.pdf"))
    try rejects { _ = try BackupIntegrity.verify(tampered) }
    print("PASS Backup: valid core/WAL/attachment roundtrip; missing/future/invalid core and malformed preferences rejected before moves; original files/preferences preserved; second-domain failure rollback including absent domain; crash reentry restores files and preferences; safety copies retained; unreadable attachment traversal rejected; failed export preserves archive; tampering rejected")
  }

  static func unreadableAttachment(archive: URL, app: URL, group: URL) throws {
    let fm = FileManager.default
    let folder = app.appendingPathComponent("unreadable-attachment-fixture")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("public-test.pdf")
    try Data("Public synthetic attachment behind an unreadable directory".utf8).write(to: file)
    defer {
      try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      try? fm.removeItem(at: folder)
    }
    let previousHash = try BackupIntegrity.hash(archive)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
    try expect(!fm.isReadableFile(atPath: file.path), "Fixture attachment was not made unreadable")
    try rejects { _ = try AppBackupExport.export(appSupport: app, group: group, destination: archive) }
    try expect(try BackupIntegrity.hash(archive) == previousHash, "Unreadable attachments replaced a known-good backup with a partial archive")
  }

  static func invalidArchives(archive: URL, root: URL, app: URL, group: URL) throws {
    let fm = FileManager.default
    let cases = ["missing-core", "future-schema", "invalid-state", "missing-preferences", "malformed-preferences", "missing-domain", "invalid-domain"]
    for name in cases {
      let (staged, _) = try AppBackupRestore.prepare(archive)
      try AppBackupRestore.schedule(staged)
      let job = try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: AppBackupRestore.pending))
      let before = try currentFiles(app: app, group: group)
      let priorPreferences = try BackupIntegrity.capturePreferences()
      let core = staged.appendingPathComponent("AppGroupContainer/Monthly/monthly.sqlite")
      let prefs = staged.appendingPathComponent("preferences.plist")
      switch name {
      case "missing-core": try fm.removeItem(at: core)
      case "future-schema":
        try replacePayload(at: core) { value in var value = value; value["schemaVersion"] = 999; return value }
      case "invalid-state":
        try replacePayload(at: core) { value in
          var value = value, pet = value["pet"] as! [String: Any]
          pet["fish"] = -1; value["pet"] = pet; return value
        }
      case "missing-preferences": try fm.removeItem(at: prefs)
      case "malformed-preferences": try Data("not a plist".utf8).write(to: prefs)
      case "missing-domain": try encodePreferences(["standard": ["fixture": "one domain only"]], to: prefs)
      default: try encodePreferences(["standard": "wrong type", "module": [String: Any]()], to: prefs)
      }
      // A matching checksum manifest must not make semantically invalid content restorable.
      try refreshManifest(staged)
      let invalidArchive = root.appendingPathComponent(name + ".zip")
      try zip(staged, to: invalidArchive)
      try rejects { _ = try AppBackupRestore.prepare(invalidArchive) }
      try verifyCurrent(before, app: app, group: group)
      try BackupIntegrity.verifyPreferences(priorPreferences)
      try rejects { try AppBackupRestore.applyPending() }
      try expect(!fm.fileExists(atPath: job.safety.path), "Invalid archive was not rejected before restore staging/moves")
      try verifyCurrent(before, app: app, group: group)
      try BackupIntegrity.verifyPreferences(priorPreferences)
      if fm.fileExists(atPath: AppBackupRestore.pending.path) { try fm.removeItem(at: AppBackupRestore.pending) }
      if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
    }
  }

  static func preferenceFailure(archive: URL, app: URL, group: URL, preferences: MemoryPreferences) throws {
    let fm = FileManager.default
    try Data("live attachment before failed restore".utf8).write(to: app.appendingPathComponent("paper.pdf"))
    try Data("live-only attachment".utf8).write(to: app.appendingPathComponent("keep-local.pdf"))
    preferences.values = [.standard: ["fixture": "original standard", "nested": ["number": 7]]]
    let original = try BackupIntegrity.capturePreferences()
    let before = try currentFiles(app: app, group: group)
    let (staged, _) = try AppBackupRestore.prepare(archive)
    try AppBackupRestore.schedule(staged)
    let job = try JSONDecoder().decode(AppBackupRestore.Job.self, from: Data(contentsOf: AppBackupRestore.pending))
    preferences.writes = 0
    preferences.failOnWrite = 2
    try rejects { try AppBackupRestore.applyPending() }
    preferences.failOnWrite = nil
    try verifyCurrent(before, app: app, group: group)
    try BackupIntegrity.verifyPreferences(original)
    try expect(preferences.values[.module] == nil, "Rollback converted an absent module domain into an empty domain")
    try expect(!fm.fileExists(atPath: AppBackupRestore.pending.path), "Successful rollback left an applying job behind")
    try expect(fm.fileExists(atPath: job.safety.appendingPathComponent("ApplicationSupport/keep-local.pdf").path), "Rollback consumed the original attachment safety copy")
    try expect(fm.fileExists(atPath: job.safety.appendingPathComponent("Group-Monthly/monthly.sqlite").path), "Rollback consumed the original core safety copy")
  }

  static func crashRollback(archive: URL, root: URL, app: URL, group: URL, preferences: MemoryPreferences) throws {
    let fm = FileManager.default
    preferences.values = [.module: ["fixture": "original module", "enabled": true]]
    let originalPreferences = try BackupIntegrity.capturePreferences()
    let before = try currentFiles(app: app, group: group)
    let (staged, _) = try AppBackupRestore.prepare(archive)
    let safety = root.appendingPathComponent("crash-safety")
    try fm.createDirectory(at: safety, withIntermediateDirectories: true)
    let appOperation = AppBackupRestore.Operation(source: staged.appendingPathComponent("ApplicationSupport-Monthly"), destination: app, previous: safety.appendingPathComponent("ApplicationSupport"), hadPrevious: true)
    let coreOperation = AppBackupRestore.Operation(source: staged.appendingPathComponent("AppGroupContainer/Monthly"), destination: group.appendingPathComponent("Monthly"), previous: safety.appendingPathComponent("Group-Monthly"), hadPrevious: true)
    let unstarted = AppBackupRestore.Operation(source: staged.appendingPathComponent("AppGroupContainer/test.sqlite"), destination: group.appendingPathComponent("test.sqlite"), previous: safety.appendingPathComponent("Group-test.sqlite"), hadPrevious: true)
    let newFile = group.appendingPathComponent("new-incoming.pdf")
    let newOperation = AppBackupRestore.Operation(source: staged.appendingPathComponent("ApplicationSupport-Monthly/paper.pdf"), destination: newFile, previous: safety.appendingPathComponent("Group-new-incoming.pdf"), hadPrevious: false)
    var job = AppBackupRestore.Job(staged: staged, safety: safety)
    job.operations = [appOperation, coreOperation, unstarted, newOperation]
    job.originalPreferences = originalPreferences
    job.applying = true
    try JSONEncoder().encode(job).write(to: AppBackupRestore.pending, options: .atomic)
    for operation in [appOperation, coreOperation] {
      try fm.moveItem(at: operation.destination, to: operation.previous)
      try fm.copyItem(at: operation.source, to: operation.destination)
    }
    try fm.copyItem(at: newOperation.source, to: newFile)
    try preferences.write(["fixture": "partially applied incoming standard"], to: .standard)
    // Simulate an already-restored operation before a second crash: rollback must be repeatable.
    try fm.removeItem(at: app)
    try fm.copyItem(at: appOperation.previous, to: app)
    do { try AppBackupRestore.applyPending() } catch {}
    try verifyCurrent(before, app: app, group: group)
    try BackupIntegrity.verifyPreferences(originalPreferences)
    try expect(preferences.values[.standard] == nil, "Crash rollback lost original standard-domain absence")
    try expect(!fm.fileExists(atPath: AppBackupRestore.pending.path), "Crash rollback did not complete the journal")
    try expect(fm.fileExists(atPath: appOperation.previous.path) && fm.fileExists(atPath: coreOperation.previous.path), "Crash rollback consumed safety copies")
    try AppBackupRestore.applyPending()
    try verifyCurrent(before, app: app, group: group)
    try BackupIntegrity.verifyPreferences(originalPreferences)
  }
}
