import Foundation
import SQLite3

/// Uses only in-memory fixtures and an isolated temporary database. Never opens the App Group.
@main struct BenefitWidgetRegression {
  static func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  static func fixture() -> State {
    var state = State()
    state.preferences.timezone = "Asia/Shanghai"
    state.pet.settledAt = instant("2026-10-08T04:00:00Z")
    return state
  }

  static func rejects(_ operation: () throws -> Void) {
    do {
      try operation()
      preconditionFailure("Expected operation to reject invalid input")
    } catch {}
  }

  static func main() throws {
    let now = instant("2026-10-08T04:00:00Z")
    var state = fixture()
    let daily = BenefitItem(name: "Daily reward", createdAt: now)
    let weekly = BenefitItem(name: "Weekly reward", kind: .weekly, createdAt: now)
    state.benefits = [daily, weekly]

    // App and widget must derive the same keys from the stored timezone, including DST.
    assert(Engine.claimKey(daily, state, on: instant("2026-10-07T15:59:59Z")) == "\(daily.id)|daily|2026-10-07")
    assert(Engine.claimKey(daily, state, on: instant("2026-10-07T16:00:00Z")) == "\(daily.id)|daily|2026-10-08")
    assert(Engine.claimKey(weekly, state, on: instant("2026-10-04T15:59:59Z")) == "\(weekly.id)|weekly|2026-09-28")
    assert(Engine.claimKey(weekly, state, on: instant("2026-10-04T16:00:00Z")) == "\(weekly.id)|weekly|2026-10-05")
    assert(Engine.claimKey(weekly, state, on: instant("2027-01-01T04:00:00Z")) == "\(weekly.id)|weekly|2026-12-28")
    var dst = state
    dst.preferences.timezone = "America/Los_Angeles"
    let firstOneAM = instant("2026-11-01T08:30:00Z")
    let secondOneAM = instant("2026-11-01T09:30:00Z")
    assert(Engine.claimKey(daily, dst, on: firstOneAM) == Engine.claimKey(daily, dst, on: secondOneAM))

    // Duplicate taps and stale widget actions are no-ops, including game rewards.
    let fishBefore = state.pet.fish
    try Engine.claim(&state, benefitID: daily.id, date: now, now: now)
    let rewarded = state.pet.fish
    let hunger = state.pet.hunger
    assert(rewarded == fishBefore + 1)
    for _ in 0..<5 { try Engine.claim(&state, benefitID: daily.id, date: now, now: now) }
    assert(state.claims.count == 1 && state.rewards.count == 1)
    assert(state.pet.fish == rewarded && state.pet.hunger == hunger)
    assert(Engine.dueBenefits(state, now: now).map(\.id) == [weekly.id])
    try Engine.claim(&state, benefitID: weekly.id, date: now, now: now)
    let tomorrow = instant("2026-10-09T04:00:00Z")
    assert(Engine.dueBenefits(state, now: tomorrow).map(\.id) == [daily.id])
    try Engine.claim(&state, benefitID: weekly.id, date: tomorrow, now: tomorrow)
    assert(state.claims.count == 2 && state.rewards.count == 2)
    assert(Engine.dueBenefits(state, now: instant("2026-10-12T04:00:00Z")).count == 2)
    rejects { try Engine.claim(&state, benefitID: daily.id, date: tomorrow, now: now) }

    // Undo plus recheck keeps the reward tombstone. Backfills never issue rewards.
    let dailyKey = Engine.claimKey(daily, state, on: now)!
    state.claims.removeAll { $0.id == dailyKey }
    let rewardCount = state.rewards.count
    try Engine.claim(&state, benefitID: daily.id, date: now, now: now)
    assert(state.rewards.count == rewardCount)
    let yesterday = instant("2026-10-07T04:00:00Z")
    try Engine.claim(&state, benefitID: daily.id, date: yesterday, now: now)
    assert(state.claims.last?.backfill == true && state.rewards.count == rewardCount)

    // Paused, deleted, and no-longer-serviced benefits cannot be claimed from an old entry.
    var paused = fixture()
    var subscription = Subscription(name: "Linked subscription")
    subscription.plans[0].start = instant("2026-10-01T00:00:00Z")
    let linked = BenefitItem(name: "Linked reward", subscriptionID: subscription.id, createdAt: now)
    paused.subscriptions = [subscription]
    paused.benefits = [linked]
    assert(Engine.dueBenefits(paused, now: now).count == 1)
    paused.benefits[0].archived = true
    assert(Engine.dueBenefits(paused, now: now).isEmpty)
    rejects { try Engine.claim(&paused, benefitID: linked.id, date: now, now: now) }
    paused.benefits[0].archived = false
    paused.subscriptions[0].archived = true
    assert(Engine.dueBenefits(paused, now: now).isEmpty)
    rejects { try Engine.claim(&paused, benefitID: linked.id, date: now, now: now) }
    paused.subscriptions[0].archived = false
    paused.subscriptions[0].cancelledAt = yesterday
    paused.subscriptions[0].serviceEnd = now
    assert(Engine.dueBenefits(paused, now: now).count == 1)
    assert(Engine.dueBenefits(paused, now: tomorrow).isEmpty)
    rejects { try Engine.claim(&paused, benefitID: linked.id, date: tomorrow, now: tomorrow) }
    paused.benefits.removeAll()
    rejects { try Engine.claim(&paused, benefitID: linked.id, date: now, now: now) }
    assert(paused.claims.isEmpty && paused.rewards.isEmpty)

    // Migration retains old claim/reward identities and is safe to call repeatedly.
    var legacy = fixture()
    subscription.plans[0].benefit = .daily
    legacy.subscriptions = [subscription]
    let oldKey = "\(subscription.id)|daily|2026-10-08"
    legacy.claims = [Claim(id: oldKey, subscriptionID: subscription.id, date: now)]
    legacy.tombstones.insert("claim|" + oldKey)
    Engine.migrateBenefits(&legacy)
    Engine.migrateBenefits(&legacy)
    assert(legacy.benefits.count == 1 && legacy.benefits[0].id == subscription.id)
    assert(Engine.dueBenefits(legacy, now: now).isEmpty)
    try Engine.claim(&legacy, benefitID: subscription.id, date: now, now: now)
    assert(legacy.claims.count == 1 && legacy.rewards.isEmpty)
    try Engine.validate(legacy)
    let roundTrip = try JSONDecoder().decode(State.self, from: JSONEncoder().encode(legacy))
    assert(roundTrip.claims[0].id == oldKey && roundTrip.tombstones == legacy.tombstones)

    try databaseRegression(now: now, daily: daily)
    try existingStoreRegression()
    print("PASS Benefits: timezone/DST/week rollover; daily/weekly due states; idempotent claims/rewards; undo/backfill; archived/expired/deleted actions; legacy migration; concurrent fresh-state transactions; corrupt-data preservation; existing-only missing/empty/schema-invalid stores reject without writes")
  }

  static func databaseRegression(now: Date, daily: BenefitItem) throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("GaoYueGong-benefit-test-" + UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let initial = try Database(directory: directory, createIfMissing: true)
    try initial.transaction {
      $0 = fixture()
      $0.benefits = [daily]
    }
    let staleSnapshot = try initial.read()
    let other = try Database(directory: directory)
    try other.transaction { $0.preferences.privacy = true }
    assert(!staleSnapshot.preferences.privacy)
    try initial.transaction { try Engine.claim(&$0, benefitID: daily.id, date: now, now: now) }
    let preserved = try initial.read()
    assert(preserved.preferences.privacy)

    // Separate connections model simultaneous app and extension writes. Each edit survives.
    let results = Failures()
    DispatchQueue.concurrentPerform(iterations: 12) { index in
      do {
        let connection = try Database(directory: directory)
        try connection.transaction {
          try Engine.claim(&$0, benefitID: daily.id, date: now, now: now)
          $0.benefits[0].note += "writer-\(index);"
        }
      } catch { results.append(error.localizedDescription) }
    }
    assert(results.values.isEmpty, results.values.joined(separator: "; "))
    let saved = try initial.read()
    assert(saved.claims.count == 1 && saved.rewards.count == 1 && saved.pet.fish == 51)
    assert(Set(saved.benefits[0].note.split(separator: ";")).count == 12)
    assert(saved.preferences.privacy)

    // A failed operation must roll back all tentative changes.
    rejects {
      try initial.transaction {
        $0.benefits[0].name = "Must not survive"
        throw AppError("Intent failed")
      }
    }
    let afterFailure = try initial.read()
    assert(afterFailure.benefits[0].name == daily.name)

    // An unreadable save must never become a fresh empty state during an intent.
    var raw: OpaquePointer?
    assert(sqlite3_open(directory.appendingPathComponent("monthly.sqlite").path, &raw) == SQLITE_OK)
    defer { sqlite3_close(raw) }
    assert(sqlite3_exec(raw, "UPDATE state SET json = '{corrupt fixture';", nil, nil, nil) == SQLITE_OK)
    rejects { try initial.transaction { try Engine.claim(&$0, benefitID: daily.id, date: now, now: now) } }
    var statement: OpaquePointer?
    assert(sqlite3_prepare_v2(raw, "SELECT json FROM state WHERE id=1", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    assert(sqlite3_step(statement) == SQLITE_ROW)
    assert(String(cString: sqlite3_column_text(statement, 0)) == "{corrupt fixture")
  }

  static func existingStoreRegression() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoYueGong-existing-test-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let absentDirectory = root.appendingPathComponent("absent")
    rejects { _ = try Database(directory: absentDirectory, createIfMissing: false) }
    assert(!fm.fileExists(atPath: root.path))

    let missingFile = root.appendingPathComponent("missing-file")
    try fm.createDirectory(at: missingFile, withIntermediateDirectories: true)
    rejects { _ = try Database(directory: missingFile, createIfMissing: false) }
    let untouchedMissing = try fm.contentsOfDirectory(atPath: missingFile.path)
    assert(untouchedMissing.isEmpty)

    // Strict opens cannot seed a blank State when the database lacks its state table or row.
    for (name, schema) in [
      ("zero-byte", ""),
      ("missing-table", "CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('keep');"),
      ("empty-state", "CREATE TABLE state (id INTEGER PRIMARY KEY CHECK(id=1), json BLOB NOT NULL);")
    ] {
      let directory = root.appendingPathComponent(name)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("monthly.sqlite")
      if schema.isEmpty {
        try Data().write(to: file)
      } else {
        var raw: OpaquePointer?
        assert(sqlite3_open(file.path, &raw) == SQLITE_OK)
        assert(sqlite3_exec(raw, schema, nil, nil, nil) == SQLITE_OK)
        assert(sqlite3_close(raw) == SQLITE_OK)
      }
      let original = try Data(contentsOf: file)
      let originalFiles = try fm.contentsOfDirectory(atPath: directory.path).sorted()
      rejects { _ = try Database(directory: directory, createIfMissing: false) }
      let after = try Data(contentsOf: file)
      let afterFiles = try fm.contentsOfDirectory(atPath: directory.path).sorted()
      assert(after == original && afterFiles == originalFiles)
    }

    // An existing valid store remains writable for the AppIntent's fresh-state transaction.
    let validDirectory = root.appendingPathComponent("valid")
    let owner = try Database(directory: validDirectory, createIfMissing: true)
    try owner.transaction { $0.preferences.timezone = "Asia/Shanghai" }
    let widget = try Database(directory: validDirectory, createIfMissing: false)
    try widget.transaction { $0.preferences.privacy = true }
    let updated = try owner.read()
    assert(updated.preferences.privacy && updated.preferences.timezone == "Asia/Shanghai")
  }

  final class Failures {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
  }
}
