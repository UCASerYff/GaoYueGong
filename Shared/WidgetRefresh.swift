import CryptoKit
import Darwin
import Foundation

/// The three clocks are deliberately separate: saved business data, cache publication, and database read.
struct MonthlyWidgetLoad {
  var state: State?
  var sourceRevision: String?
  var snapshotGeneratedAt: Date?
  var lastSuccessfulReadAt: Date?
  var attemptedAt: Date
  var failure: WidgetReadFailure?
  var fromCache = false
}

enum WidgetReadFailure: String, Codable, Error {
  case missing, busy, unsupported, unreadable, publication
  func message(_ english: Bool) -> String {
    switch self {
    case .missing: return english ? "Database missing · retry pending" : "资料库缺失 · 等待重试"
    case .busy: return english ? "Database busy · retry pending" : "资料库忙碌 · 等待重试"
    case .unsupported: return english ? "Unsupported save version" : "资料版本不兼容"
    case .unreadable: return english ? "Cannot read data · retry pending" : "资料无法读取 · 等待重试"
    case .publication: return english ? "Cache update failed · retry pending" : "缓存更新失败 · 等待重试"
    }
  }
}

enum MonthlyWidgetData {
  static let kinds = ["GaoYueGong", "GaoYueGongBenefits"]
  private static let cacheName = "last-valid-v1.json"
  private struct Cache: Codable {
    var formatVersion = 1
    var generatedAt: Date
    var verifiedAt: Date
    var payload: Data
    var sha256: String
  }
  struct Pending: Codable {
    var requestedAt: Date
    var reason: String
    var revision: String?
    var timelineReadAt: Date?
    var needsRetry: Bool
    var pendingKinds = MonthlyWidgetData.kinds
    var acknowledgedConsumers: [String: Date] = [:]
    // This receipt only proves the provider read the requested revision, never a desktop render.
  }
  private struct RetryMarker: Codable {
    var attemptedAt: Date
    var failure: WidgetReadFailure
  }
  struct Receipt: Codable {
    var consumer: String
    var attemptedAt: Date
    var sourceUpdatedAt: Date?
    var sourceRevision: String?
    var snapshotGeneratedAt: Date?
    var lastSuccessfulReadAt: Date?
    var returnedAt: Date
    var fromCache: Bool
    var failure: WidgetReadFailure?
    var processID: Int32
    var bundleVersion: String
    var build: String
    var database = "Monthly/monthly.sqlite"
  }

  /// Uses the original SQLite payload as a revision, so Set encoding order cannot fabricate a change.
  static func revision(_ payload: Data) -> String {
    SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
  }
  private static func atomic<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }
  private static func cache(at folder: URL) throws -> (Cache, State) {
    let bytes = try Data(contentsOf: folder.appendingPathComponent(cacheName))
    guard bytes.count < 70_000_000 else { throw WidgetReadFailure.unreadable }
    let saved = try JSONDecoder().decode(Cache.self, from: bytes)
    guard saved.formatVersion == 1, saved.sha256 == revision(saved.payload) else {
      throw WidgetReadFailure.unreadable
    }
    let state = try JSONDecoder().decode(State.self, from: saved.payload)
    try Engine.validate(state)
    return (saved, state)
  }
  /// Serializes DB-read + publication across app, widget kinds, and multiple instances.
  /// Bounded nonblocking locking avoids consuming the widget extension's execution budget.
  private static func withLock<T>(directory: URL, _ body: (URL) throws -> T) throws -> T {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw WidgetReadFailure.missing
    }
    let folder = directory.appendingPathComponent("WidgetSync", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("monthly.sqlite").path)
      || FileManager.default.fileExists(atPath: folder.path) else { throw WidgetReadFailure.missing }
    // mkdir accepts an already-created directory without recursively creating a missing store.
    if mkdir(folder.path, mode_t(0o700)) != 0 && errno != EEXIST { throw WidgetReadFailure.publication }
    var syncIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &syncIsDirectory),
      syncIsDirectory.boolValue else { throw WidgetReadFailure.publication }
    let lock = open(folder.appendingPathComponent("publication.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lock >= 0 else { throw WidgetReadFailure.publication }
    defer { close(lock) }
    var locked = false
    for attempt in 0..<6 {
      if flock(lock, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
      if attempt < 5 { Thread.sleep(forTimeInterval: 0.025) }
    }
    guard locked else { throw WidgetReadFailure.busy }
    defer { flock(lock, LOCK_UN) }
    return try body(folder)
  }
  private static func classify(_ error: Error, directory: URL) -> WidgetReadFailure {
    if let failure = error as? WidgetReadFailure { return failure }
    if let error = error as? AppError, error.busy { return .busy }
    if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("monthly.sqlite").path) { return .missing }
    let detail = error.localizedDescription.lowercased()
    if detail.contains("version") || detail.contains("版本") { return .unsupported }
    return .unreadable
  }

  static func load(directory: URL? = nil, now: Date = Date(), consumer: String,
                   acknowledgesReload: Bool = false) -> MonthlyWidgetLoad {
    var result = MonthlyWidgetLoad(attemptedAt: now)
    do {
      let directory = try directory ?? Database.location()
      do {
        result = try withLock(directory: directory) { folder in
          var loaded = MonthlyWidgetLoad(attemptedAt: now)
          do {
            let db = try Database(directory: directory, readOnly: true)
            let record = try db.readRecord()
            let hash = revision(record.payload)
            let prior = try? cache(at: folder)
            let generated = prior?.0.sha256 == hash ? prior!.0.generatedAt : now
            loaded = MonthlyWidgetLoad(state: record.state, sourceRevision: hash,
              snapshotGeneratedAt: prior?.0.sha256 == hash ? prior?.0.generatedAt : nil,
              lastSuccessfulReadAt: now, attemptedAt: now)
            do {
              try atomic(Cache(generatedAt: generated, verifiedAt: now, payload: record.payload, sha256: hash),
                         to: folder.appendingPathComponent(cacheName))
              loaded.snapshotGeneratedAt = generated
            } catch { loaded.failure = .publication }
          } catch {
            loaded.failure = classify(error, directory: directory)
            if let (saved, state) = try? cache(at: folder) {
              loaded.state = state
              // A stale privacy setting must never expose details the user may just have hidden.
              loaded.state?.preferences.privacy = true
              loaded.sourceRevision = saved.sha256
              loaded.snapshotGeneratedAt = saved.generatedAt
              loaded.lastSuccessfulReadAt = saved.verifiedAt
              loaded.fromCache = true
            }
          }
          let pendingURL = folder.appendingPathComponent("pending-refresh.json")
          if loaded.failure != nil {
            var pending = (try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL)))
              ?? Pending(requestedAt: now, reason: "read-retry", revision: nil, needsRetry: true)
            pending.needsRetry = true
            try? atomic(pending, to: pendingURL)
          } else if acknowledgesReload,
                    var pending = try? JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL)),
                    pending.revision == nil || pending.revision == loaded.sourceRevision {
            pending.timelineReadAt = now
            pending.acknowledgedConsumers[consumer] = now
            let kind = String(consumer.split(separator: "/").first ?? "")
            pending.pendingKinds.removeAll { $0 == kind }
            pending.needsRetry = !pending.pendingKinds.isEmpty
            try? atomic(pending, to: pendingURL)
          }
          if acknowledgesReload && loaded.failure == nil {
            // Only retire retries that predate this successful provider read.
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
              where url.lastPathComponent.hasPrefix("retry-") {
              if let marker = try? JSONDecoder().decode(RetryMarker.self, from: Data(contentsOf: url)),
                 marker.attemptedAt <= now { try? FileManager.default.removeItem(at: url) }
            }
          }
          let receipt = Receipt(consumer: consumer, attemptedAt: now, sourceUpdatedAt: loaded.state?.updatedAt,
            sourceRevision: loaded.sourceRevision, snapshotGeneratedAt: loaded.snapshotGeneratedAt,
            lastSuccessfulReadAt: loaded.lastSuccessfulReadAt, returnedAt: Date(), fromCache: loaded.fromCache,
            failure: loaded.failure, processID: getpid(), bundleVersion: AppInfo.version,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test")
          let historyURL = folder.appendingPathComponent("read-receipts.json")
          var history = (try? JSONDecoder().decode([Receipt].self, from: Data(contentsOf: historyURL))) ?? []
          history.append(receipt)
          try? atomic(Array(history.suffix(80)), to: historyURL)
          return loaded
        }
      } catch {
        result.failure = classify(error, directory: directory)
        // A contended publication lock cannot safely overwrite the shared pending record.
        // Independent markers preserve retry evidence without clobbering another process.
        let retry = directory.appendingPathComponent("WidgetSync/retry-\(UUID().uuidString).json")
        try? atomic(RetryMarker(attemptedAt: now, failure: result.failure!), to: retry)
        // Atomic replacement means an unlocked fallback sees a whole, hash-validated cache.
        if let (saved, state) = try? cache(at: directory.appendingPathComponent("WidgetSync")) {
          result.state = state; result.state?.preferences.privacy = true
          result.sourceRevision = saved.sha256; result.snapshotGeneratedAt = saved.generatedAt
          result.lastSuccessfulReadAt = saved.verifiedAt; result.fromCache = true
        }
      }
    } catch { result.failure = .missing }
    return result
  }

  static func recordReloadRequest(reason: String, directory: URL? = nil, now: Date = Date()) throws {
    let directory = try directory ?? Database.location()
    do {
      try withLock(directory: directory) { folder in
        let record = try? Database(directory: directory, readOnly: true).readRecord()
        try atomic(Pending(requestedAt: now, reason: reason,
          revision: record.map { revision($0.payload) }, needsRetry: true),
          to: folder.appendingPathComponent("pending-refresh.json"))
      }
    } catch {
      let retry = directory.appendingPathComponent("WidgetSync/retry-\(UUID().uuidString).json")
      try? atomic(RetryMarker(attemptedAt: now, failure: classify(error, directory: directory)), to: retry)
      throw error
    }
  }

  static func timelineDates(state: State?, now: Date, days: Int = 7) -> [Date] {
    guard let state else { return [now] }
    let calendar = Engine.calendar(state)
    return [now] + (1...max(1, min(days, 7))).compactMap {
      calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))
    }
  }
  static func nextRefresh(state: State?, now: Date, failed: Bool) -> Date {
    let calendar = state.map { Engine.calendar($0) } ?? Calendar.current
    let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    // A request policy, not a promise of a fixed WidgetKit refresh interval.
    return min(nextDay, now.addingTimeInterval(failed ? 15 * 60 : 30 * 60))
  }
}
