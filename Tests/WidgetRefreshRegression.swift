import Darwin
import Foundation
import SQLite3

/// Tests provider data flow with synthetic records, never widgets or real user containers.
@main struct WidgetRefreshRegression {
  struct Failure: Error, CustomStringConvertible { let description: String }
  static let now = ISO8601DateFormatter().date(from: "2026-10-18T04:00:00Z")!
  static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(description: message) }
  }
  static func sql(_ database: OpaquePointer?, _ statement: String) throws {
    try expect(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK, "Fixture SQL failed")
  }
  static func raw(_ directory: URL) throws -> OpaquePointer {
    var pointer: OpaquePointer?
    try expect(sqlite3_open(directory.appendingPathComponent("monthly.sqlite").path, &pointer) == SQLITE_OK && pointer != nil, "Fixture open failed")
    return pointer!
  }
  static func syncFile(_ directory: URL, _ name: String) -> URL {
    directory.appendingPathComponent("WidgetSync").appendingPathComponent(name)
  }
  static func pending(_ directory: URL) throws -> MonthlyWidgetData.Pending {
    try JSONDecoder().decode(MonthlyWidgetData.Pending.self, from: Data(contentsOf: syncFile(directory, "pending-refresh.json")))
  }
  static func seed(_ directory: URL) throws -> MonthlyWidgetLoad {
    do {
      let db = try Database(directory: directory, createIfMissing: true)
      try db.transaction { state in
        state.preferences.timezone = "Asia/Shanghai"
        state.preferences.privacy = false
        state.preferences.game = false
        var sub = Subscription(name: "Fixture subscription")
        sub.plans[0].start = Engine.date("2026-10-01", state)
        sub.plans[0].anchor = Engine.date("2026-10-20", state)
        sub.plans[0].price = 30
        state.subscriptions = [sub]
        state.benefits = [BenefitItem(name: "Fixture daily"), BenefitItem(name: "Fixture weekly", kind: .weekly)]
      }
    }
    let result = MonthlyWidgetData.load(directory: directory, now: now, consumer: "fixture-initial")
    try expect(result.state != nil && result.failure == nil && !result.fromCache, "Fixture initial read failed")
    return result
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("monthly-widget-refresh-" + UUID().uuidString + ".noindex")
    defer { try? FileManager.default.removeItem(at: root) }
    try dataAndTime(root.appendingPathComponent("values"))
    try unavailableData(root)
    try reloadRequestFailure(root.appendingPathComponent("reload-request-lock"))
    try acknowledgedKindFailure(root.appendingPathComponent("acknowledged-kind-failure"))
    try publicationFailure(root.appendingPathComponent("cache-publication-failure"))
    try concurrency(root.appendingPathComponent("concurrent"))
    try timelineDates()
    print("PASS Widget refresh: original source/hash and separate clocks; CRUD/claim consistency; acknowledgement revision checks; failed-kind retry survives another kind's success; missing/corrupt/future/busy cache fallback; privacy on fallback; invalid-cache fail-closed; reload-request failure markers; truthful failed-publication timestamp; concurrent atomic publication; midnight/month/DST timeline derivations")
  }

  static func dataAndTime(_ directory: URL) throws {
    let first = try seed(directory)
    let firstState = first.state!
    let originalHash = first.sourceRevision
    let sourceTime = firstState.updatedAt
    let secondTime = now.addingTimeInterval(60)
    let second = MonthlyWidgetData.load(directory: directory, now: secondTime, consumer: "fixture-second")
    try expect(second.state?.updatedAt == sourceTime && second.sourceRevision == originalHash, "Read fabricated a source update")
    try expect(second.snapshotGeneratedAt == first.snapshotGeneratedAt && second.lastSuccessfulReadAt == secondTime,
      "Cache publication and read clocks were conflated: first=\(String(describing: first.snapshotGeneratedAt)), second=\(String(describing: second.snapshotGeneratedAt)), verified=\(String(describing: second.lastSuccessfulReadAt)), failure=\(String(describing: second.failure))")
    do {
      let db = try Database(directory: directory, readOnly: true)
      let record = try db.readRecord()
      try expect(second.sourceRevision == MonthlyWidgetData.revision(record.payload), "Revision does not identify exact source bytes")
    }

    try MonthlyWidgetData.recordReloadRequest(reason: "fixture-request", directory: directory, now: secondTime)
    _ = MonthlyWidgetData.load(directory: directory, now: secondTime.addingTimeInterval(1), consumer: "app-read")
    try expect(try pending(directory).needsRetry, "An app read acknowledged a widget request")
    _ = MonthlyWidgetData.load(directory: directory, now: secondTime.addingTimeInterval(2), consumer: "GaoYueGong/systemSmall/timeline", acknowledgesReload: true)
    try expect(try pending(directory).needsRetry && pending(directory).pendingKinds == ["GaoYueGongBenefits"], "One widget kind cleared the other kind's pending read")
    _ = MonthlyWidgetData.load(directory: directory, now: secondTime.addingTimeInterval(2), consumer: "GaoYueGong/systemMedium/timeline", acknowledgesReload: true)
    try expect(try pending(directory).needsRetry, "A second size acknowledged a different widget kind")
    _ = MonthlyWidgetData.load(directory: directory, now: secondTime.addingTimeInterval(2), consumer: "GaoYueGongBenefits/systemSmall/timeline", acknowledgesReload: true)
    try expect(try !pending(directory).needsRetry, "Both matching kinds did not acknowledge request")
    try expect(try pending(directory).acknowledgedConsumers.count == 3, "Per-consumer acknowledgement evidence was lost")

    try MonthlyWidgetData.recordReloadRequest(reason: "old-revision", directory: directory, now: secondTime.addingTimeInterval(3))
    do {
      let db = try Database(directory: directory)
      try db.transaction {
        $0.subscriptions[0].plans[0].price = 48
        $0.subscriptions[0].plans[0].anchor = Engine.date("2026-10-22", $0)
      }
    }
    let editedTime = secondTime.addingTimeInterval(4)
    let edited = MonthlyWidgetData.load(directory: directory, now: editedTime, consumer: "GaoYueGong/systemSmall/timeline", acknowledgesReload: true)
    try expect(edited.sourceRevision != originalHash && edited.snapshotGeneratedAt == editedTime, "Real edit retained old revision/publication time")
    let upcoming = Engine.upcoming(edited.state!, now: now, days: 7)
    try expect(upcoming.count == 1 && upcoming[0].price == 48, "Edited amount differs in provider state")
    try expect(Engine.day(upcoming[0].date, edited.state!) == "2026-10-22", "Edited due date differs in provider state")
    try expect(try pending(directory).needsRetry, "Mismatched revision cleared a pending request")
    try MonthlyWidgetData.recordReloadRequest(reason: "new-revision", directory: directory, now: editedTime)
    _ = MonthlyWidgetData.load(directory: directory, now: editedTime.addingTimeInterval(1), consumer: "GaoYueGong/systemSmall/timeline", acknowledgesReload: true)
    _ = MonthlyWidgetData.load(directory: directory, now: editedTime.addingTimeInterval(1), consumer: "GaoYueGongBenefits/systemSmall/timeline", acknowledgesReload: true)
    try expect(try !pending(directory).needsRetry, "New matching request did not acknowledge")

    let dailyID = edited.state!.benefits.first { $0.kind == .daily }!.id
    do {
      let db = try Database(directory: directory)
      try db.transaction { try Engine.claim(&$0, benefitID: dailyID, date: now, now: now) }
    }
    let claimed = MonthlyWidgetData.load(directory: directory, now: editedTime.addingTimeInterval(2), consumer: "claim-read")
    try expect(Engine.dueBenefits(claimed.state!, now: now).count == 1 && claimed.state!.claims.count == 1, "Claim count/state differs in provider")
    do {
      let reopened = try Database(directory: directory)
      try reopened.transaction { try Engine.claim(&$0, benefitID: dailyID, date: now, now: now) }
    }
    let duplicate = MonthlyWidgetData.load(directory: directory, now: editedTime.addingTimeInterval(3), consumer: "duplicate-read")
    try expect(duplicate.sourceRevision == claimed.sourceRevision && duplicate.state?.updatedAt == claimed.state?.updatedAt, "Duplicate claim fabricated content revision")
    do {
      let db = try Database(directory: directory)
      try db.transaction { $0.subscriptions.removeAll() }
    }
    let removed = MonthlyWidgetData.load(directory: directory, now: editedTime.addingTimeInterval(4), consumer: "delete-read")
    try expect(removed.state?.subscriptions.isEmpty == true && Engine.upcoming(removed.state!, now: now).isEmpty, "Deleted subscription survived provider read")
  }

  static func unavailableData(_ root: URL) throws {
    let fm = FileManager.default
    let pristine = root.appendingPathComponent("pristine")
    try fm.createDirectory(at: pristine, withIntermediateDirectories: true)
    let noStore = MonthlyWidgetData.load(directory: pristine, now: now, consumer: "new-widget")
    try expect(noStore.state == nil && noStore.failure == .missing, "New widget fabricated an initialized store")
    try expect(try fm.contentsOfDirectory(atPath: pristine.path).isEmpty, "Widget poisoned pristine app initialization with helper files")
    for kind in ["missing", "corrupt", "unsupported", "busy"] {
      let directory = root.appendingPathComponent("failure-" + kind)
      let good = try seed(directory)
      let cacheFile = syncFile(directory, "last-valid-v1.json")
      let cacheBefore = try Data(contentsOf: cacheFile)
      var held: OpaquePointer?
      switch kind {
      case "missing": try fm.removeItem(at: directory.appendingPathComponent("monthly.sqlite"))
      case "corrupt":
        let connection = try raw(directory)
        do { try sql(connection, "UPDATE state SET json = '{broken'") }
        catch { sqlite3_close(connection); throw error }
        sqlite3_close(connection)
      case "unsupported":
        let connection = try raw(directory)
        do { try sql(connection, "UPDATE state SET json = '{\"schemaVersion\":2,\"rulesVersion\":1}'") }
        catch { sqlite3_close(connection); throw error }
        sqlite3_close(connection)
      default:
        held = try raw(directory)
        try sql(held, "PRAGMA journal_mode=DELETE")
        try sql(held, "BEGIN EXCLUSIVE")
      }
      let attempted = now.addingTimeInterval(600)
      let failed = MonthlyWidgetData.load(directory: directory, now: attempted, consumer: "failure-read", acknowledgesReload: true)
      if let held { try sql(held, "ROLLBACK"); sqlite3_close(held) }
      let expected: WidgetReadFailure = kind == "missing" ? .missing : kind == "unsupported" ? .unsupported : kind == "busy" ? .busy : .unreadable
      try expect(failed.failure == expected && failed.fromCache && failed.state != nil, "\(kind) did not preserve last valid content with explicit failure")
      try expect(failed.state?.subscriptions.first?.plans.first?.price == 30, "\(kind) showed fabricated business values")
      try expect(failed.state?.preferences.privacy == true, "\(kind) fallback exposed stale privacy settings")
      try expect(failed.sourceRevision == good.sourceRevision && failed.state?.updatedAt == good.state?.updatedAt, "\(kind) changed source clock/revision")
      try expect(failed.snapshotGeneratedAt == good.snapshotGeneratedAt && failed.lastSuccessfulReadAt == good.lastSuccessfulReadAt && failed.attemptedAt == attempted, "\(kind) conflated failed attempt with successful read")
      try expect(try Data(contentsOf: cacheFile) == cacheBefore, "\(kind) replaced last valid cache")
      try expect(try pending(directory).needsRetry, "\(kind) failure did not retain retry state")
      if kind == "missing" {
        try expect(!fm.fileExists(atPath: directory.appendingPathComponent("monthly.sqlite").path), "Missing store was recreated by provider")
        try Data("invalid cache".utf8).write(to: cacheFile)
        let unavailable = MonthlyWidgetData.load(directory: directory, now: attempted.addingTimeInterval(1), consumer: "invalid-cache-read")
        try expect(unavailable.state == nil && unavailable.failure != nil, "Bad cache plus missing DB became a zero state")
      }
    }

    // A busy publication lock must still return a complete prior snapshot, with private details hidden.
    let lockedDirectory = root.appendingPathComponent("publication-busy")
    let prior = try seed(lockedDirectory)
    let lock = Darwin.open(syncFile(lockedDirectory, "publication.lock").path, O_RDWR)
    try expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "Fixture publication lock failed")
    let blocked = MonthlyWidgetData.load(directory: lockedDirectory, now: now.addingTimeInterval(1), consumer: "publication-blocked")
    flock(lock, LOCK_UN); Darwin.close(lock)
    try expect(blocked.failure == .busy && blocked.fromCache && blocked.sourceRevision == prior.sourceRevision, "Publication contention lost cached content")
    try expect(blocked.state?.preferences.privacy == true, "Publication contention exposed private cached details")
    let oldMarkers = try fm.contentsOfDirectory(atPath: syncFile(lockedDirectory, "").path).filter { $0.hasPrefix("retry-") }
    try expect(oldMarkers.count == 1, "Publication failure lost independent retry evidence")
    struct Marker: Codable { var attemptedAt: Date; var failure: WidgetReadFailure }
    let futureFile = syncFile(lockedDirectory, "retry-future-fixture.json")
    try JSONEncoder().encode(Marker(attemptedAt: now.addingTimeInterval(1000), failure: .busy)).write(to: futureFile)
    _ = MonthlyWidgetData.load(directory: lockedDirectory, now: now.addingTimeInterval(2), consumer: "app-retry")
    try expect(fm.fileExists(atPath: syncFile(lockedDirectory, oldMarkers[0]).path), "An app read cleared timeline retry evidence")
    _ = MonthlyWidgetData.load(directory: lockedDirectory, now: now.addingTimeInterval(3), consumer: "GaoYueGong/systemSmall/timeline", acknowledgesReload: true)
    try expect(!fm.fileExists(atPath: syncFile(lockedDirectory, oldMarkers[0]).path), "Successful provider read did not retire older retry evidence")
    try expect(fm.fileExists(atPath: futureFile.path), "Older provider read erased a newer failure marker")
  }

  final class Results {
    let lock = NSLock()
    var values: [MonthlyWidgetLoad] = []
    func append(_ item: MonthlyWidgetLoad) { lock.lock(); defer { lock.unlock() }; values.append(item) }
  }
  static func reloadRequestFailure(_ directory: URL) throws {
    let fm = FileManager.default
    _ = try seed(directory)
    try MonthlyWidgetData.recordReloadRequest(reason: "preserve-this-request", directory: directory, now: now)
    let pendingURL = syncFile(directory, "pending-refresh.json")
    let originalPending = try Data(contentsOf: pendingURL)
    let lock = Darwin.open(syncFile(directory, "publication.lock").path, O_RDWR)
    try expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "Fixture request lock failed")
    var held = true
    defer { if held { flock(lock, LOCK_UN); Darwin.close(lock) } }
    var failure: Error?
    do {
      try MonthlyWidgetData.recordReloadRequest(reason: "blocked-request", directory: directory, now: now.addingTimeInterval(1))
    } catch { failure = error }
    try expect(failure as? WidgetReadFailure == .busy, "Blocked reload request did not report lock failure")
    try expect(try Data(contentsOf: pendingURL) == originalPending, "Blocked request overwrote another pending request")
    let markers = try fm.contentsOfDirectory(atPath: syncFile(directory, "").path).filter { $0.hasPrefix("retry-") }
    try expect(markers.count == 1, "Blocked reload request lost durable retry evidence")
    flock(lock, LOCK_UN); Darwin.close(lock); held = false
    _ = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(2), consumer: "GaoYueGong/systemSmall/timeline", acknowledgesReload: true)
    try expect(!fm.fileExists(atPath: syncFile(directory, markers[0]).path), "Successful timeline did not retire blocked-request marker")
    try expect(try pending(directory).pendingKinds == ["GaoYueGongBenefits"], "Timeline acknowledgment lost the other widget kind")
  }

  static func publicationFailure(_ directory: URL) throws {
    let fm = FileManager.default
    let initial = try seed(directory)
    let folder = directory.appendingPathComponent("WidgetSync")
    let cacheFile = syncFile(directory, "last-valid-v1.json")
    let originalCache = try Data(contentsOf: cacheFile)
    do {
      let db = try Database(directory: directory)
      try db.transaction { $0.subscriptions[0].plans[0].price = 63 }
    }
    // Deny directory replacement only in this synthetic fixture; the existing lock remains usable.
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    let failed = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(5), consumer: "failed-publication")
    try expect(failed.failure == .publication && !failed.fromCache, "Fixture did not exercise atomic publication failure")
    try expect(failed.state?.subscriptions.first?.current.price == 63 && failed.sourceRevision != initial.sourceRevision, "Publication failure lost successfully read new source data")
    try expect(failed.snapshotGeneratedAt == nil, "Failed publication fabricated a new cache publication timestamp")
    try expect(try Data(contentsOf: cacheFile) == originalCache, "Failed publication damaged last valid cache")
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let recovered = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(6), consumer: "recovered-publication")
    try expect(recovered.failure == nil && recovered.snapshotGeneratedAt == now.addingTimeInterval(6), "Successful retry did not publish the changed revision")
  }

  static func acknowledgedKindFailure(_ directory: URL) throws {
    _ = try seed(directory)
    let overview = "GaoYueGong/systemSmall/timeline"
    let benefits = "GaoYueGongBenefits/systemSmall/timeline"
    try MonthlyWidgetData.recordReloadRequest(reason: "both-kinds", directory: directory, now: now)
    _ = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(1), consumer: overview, acknowledgesReload: true)
    _ = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(2), consumer: benefits, acknowledgesReload: true)
    try expect(try !pending(directory).needsRetry && pending(directory).pendingKinds.isEmpty, "Fixture did not acknowledge both widget kinds")

    let holder = try raw(directory)
    defer { sqlite3_close(holder) }
    try sql(holder, "PRAGMA journal_mode=DELETE")
    try sql(holder, "BEGIN EXCLUSIVE")
    let failed = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(3), consumer: benefits, acknowledgesReload: true)
    try sql(holder, "ROLLBACK")
    try expect(failed.failure == .busy && failed.fromCache, "Fixture did not fail the previously acknowledged benefits read")
    try expect(try pending(directory).needsRetry && pending(directory).pendingKinds == ["GaoYueGongBenefits"], "Read failure did not re-add the failed widget kind")

    _ = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(4), consumer: overview, acknowledgesReload: true)
    try expect(try pending(directory).needsRetry && pending(directory).pendingKinds == ["GaoYueGongBenefits"], "Overview success cleared an outstanding benefits retry")
    _ = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(5), consumer: benefits, acknowledgesReload: true)
    try expect(try !pending(directory).needsRetry && pending(directory).pendingKinds.isEmpty, "Recovered benefits read did not clear its own retry")

    // App-level and unknown consumers cannot safely narrow the failure to one widget kind.
    for (index, consumer) in ["app/read-failed", "unknown-consumer"].enumerated() {
      let time = now.addingTimeInterval(Double(10 + index * 4))
      try sql(holder, "BEGIN EXCLUSIVE")
      let failed = MonthlyWidgetData.load(directory: directory, now: time, consumer: consumer)
      try sql(holder, "ROLLBACK")
      try expect(failed.failure == .busy, "Fixture did not fail the non-widget read")
      try expect(try pending(directory).needsRetry && Set(pending(directory).pendingKinds) == Set(MonthlyWidgetData.kinds), "Non-widget failure did not conservatively re-add both kinds")
      _ = MonthlyWidgetData.load(directory: directory, now: time.addingTimeInterval(1), consumer: overview, acknowledgesReload: true)
      try expect(try pending(directory).needsRetry, "One kind cleared an app-level retry for both kinds")
      _ = MonthlyWidgetData.load(directory: directory, now: time.addingTimeInterval(2), consumer: benefits, acknowledgesReload: true)
      try expect(try !pending(directory).needsRetry, "Both successful kinds did not clear the app-level retry")
    }
  }

  static func concurrency(_ directory: URL) throws {
    let initial = try seed(directory)
    let values = Results()
    DispatchQueue.concurrentPerform(iterations: 12) { index in
      values.append(MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(Double(index)), consumer: "concurrent-\(index)"))
    }
    try expect(values.values.count == 12, "Concurrent provider call disappeared")
    try expect(values.values.allSatisfy { $0.state != nil && $0.sourceRevision == initial.sourceRevision }, "Concurrent publication returned partial/mixed snapshots")
    let final = MonthlyWidgetData.load(directory: directory, now: now.addingTimeInterval(30), consumer: "concurrent-final")
    try expect(final.failure == nil && final.sourceRevision == initial.sourceRevision, "Concurrent publication corrupted final cache")
    let cacheObject = try JSONSerialization.jsonObject(with: Data(contentsOf: syncFile(directory, "last-valid-v1.json"))) as! [String: Any]
    let payload = Data(base64Encoded: cacheObject["payload"] as! String)!
    try expect(cacheObject["sha256"] as? String == MonthlyWidgetData.revision(payload), "Concurrent cache checksum does not match payload")
  }

  static func timelineDates() throws {
    var state = State()
    state.preferences.timezone = "Asia/Shanghai"
    let octoberEnd = ISO8601DateFormatter().date(from: "2026-10-31T15:59:59Z")!
    let dates = MonthlyWidgetData.timelineDates(state: state, now: octoberEnd)
    try expect(dates.count == 8 && dates[0] == octoberEnd, "Timeline did not include current entry and seven boundaries")
    try expect(Engine.day(dates[1], state) == "2026-11-01" && dates[1].timeIntervalSince(octoberEnd) == 1, "Timeline missed business-timezone month boundary")
    let benefit = BenefitItem(name: "Boundary claim")
    state.benefits = [benefit]
    state.preferences.game = false
    try Engine.claim(&state, benefitID: benefit.id, date: octoberEnd, now: octoberEnd)
    try expect(Engine.dueBenefits(state, now: dates[0]).isEmpty && Engine.dueBenefits(state, now: dates[1]).count == 1, "Future entry did not recompute benefits")
    try expect(MonthlyWidgetData.nextRefresh(state: state, now: octoberEnd, failed: false) == dates[1], "Refresh request crossed business midnight")
    try expect(MonthlyWidgetData.nextRefresh(state: state, now: now, failed: true) == now.addingTimeInterval(900), "Failure retry policy is incorrect")
    state.preferences.timezone = "America/Los_Angeles"
    let beforeSpring = ISO8601DateFormatter().date(from: "2026-03-07T20:00:00Z")!
    let spring = MonthlyWidgetData.timelineDates(state: state, now: beforeSpring, days: 3)
    try expect(spring[2].timeIntervalSince(spring[1]) == 23 * 3600, "Spring DST used fixed 24-hour increments")
    let beforeFall = ISO8601DateFormatter().date(from: "2026-10-31T19:00:00Z")!
    let fall = MonthlyWidgetData.timelineDates(state: state, now: beforeFall, days: 3)
    try expect(fall[2].timeIntervalSince(fall[1]) == 25 * 3600, "Fall DST used fixed 24-hour increments")
    try expect(MonthlyWidgetData.timelineDates(state: nil, now: now) == [now], "Unreadable state fabricated derived future entries")
  }
}
