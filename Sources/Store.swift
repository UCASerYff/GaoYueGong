import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

@MainActor final class Store: ObservableObject {
  @Published var state = State()
  @Published var tab = 0
  @Published var editor: Subscription?
  @Published var paymentBill: Bill?
  @Published var error: String?
  @Published var fatal: String?
  @Published var notice: String?
  @Published var notificationStatus = ""
  @Published var coverage = ""
  private var db: Database?
  private var scheduleTask: Task<Void, Never>?
  /// app 级语言（gqns.language）变化时推动界面重渲染；en 直读解析器，不依赖本字段取值。
  @Published private var languageRevision = 0
  /// 语言统一读 app 级设置中心的 gqns.language；存档里的 preferences.language 保留为旧数据字段，不再驱动界面。
  var en: Bool { GQNSLanguage.isEnglish }
  func t(_ zh: String, _ en: String) -> String { self.en ? en : zh }
  init() {
    NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.languageRevision += 1 }
    }
    reload()
  }
  func reload() {
    do {
      if db == nil { db = try Database() }
      state = try db!.read()
      fatal = nil
      // V0.4 一次性经济补发：旧规则下该得而未得的小鱼干。
      if !state.tombstones.contains("migration|fish-backfill-v1") {
        update { Engine.backfillEconomy(&$0) }
      }
      // V0.5 一次性迁移：内嵌权益升级为独立权益模块。
      if !state.tombstones.contains("migration|benefits-v1") {
        update { Engine.migrateBenefits(&$0) }
      }
      if !state.tombstones.contains("migration|beta-v359") {
        update { Engine.migrateBeta(&$0) }
      }
      refreshNotifications()
      // 语言统一走 app 级 gqns.language：把解析结果回写存档字段，
      // 让 Widget 扩展（独立进程，只读存档）与主界面保持一致。
      if (state.preferences.language == "en") != GQNSLanguage.isEnglish {
        update { $0.preferences.language = GQNSLanguage.isEnglish ? "en" : "zh" }
      }
    } catch { fatal = error.localizedDescription }
  }
  func update(_ operation: (inout State) throws -> Void) {
    guard let db else {
      error = t("数据库尚未就绪", "Database unavailable")
      return
    }
    do {
      state = try db.transaction(operation)
      NotificationCenter.default.post(name:Notification.Name("GaoSeries.monthly.changed"),object:nil)
      DistributedNotificationCenter.default().postNotificationName(Notification.Name("GaoSeries.monthly.changed"),object:nil,userInfo:nil,deliverImmediately:true)
      fatal = nil
      WidgetCenter.shared.reloadAllTimelines()
      refreshNotifications()
      do { try db.snapshot() } catch {
        self.error =
          t("记录已保存，但自动快照失败：", "Saved, but snapshot failed: ") + error.localizedDescription
      }
    } catch { self.error = error.localizedDescription }
  }
  func save(_ input: Subscription) {
    update { s in
      var sub = input
      sub.name = sub.name.trimmingCharacters(in: .whitespacesAndNewlines)
      sub.updatedAt = Date()
      if let i = s.subscriptions.firstIndex(where: { $0.id == sub.id }) {
        let original = s.subscriptions[i]
        if original.current != sub.current {
          let revised = sub.current
          var plans = original.plans
          let effective = Engine.calendar(s).startOfDay(for: revised.start)
          let previousStart = Engine.calendar(s).startOfDay(for: plans.last!.start)
          guard effective >= previousStart else {
            throw AppError("新计划不能早于上一计划起点 / Plan starts too early")
          }
          plans[plans.count - 1].end = effective
          var new = revised
          new.id = UUID()
          new.start = effective
          new.end = nil
          plans.append(new)
          sub.plans = plans
        }
        s.subscriptions[i] = sub
      } else {
        s.subscriptions.append(sub)
      }
    }
    if error == nil {
      editor = nil
      notice = t("订阅已保存", "Subscription saved")
    }
  }
  func claim(_ benefit: BenefitItem, date: Date = Date()) {
    update { try Engine.claim(&$0, benefitID: benefit.id, date: date) }
    if error == nil {
      notice = t("权益已记下，别忘了在平台实际领取", "Recorded. Remember to claim on the platform.")
    }
  }
  func saveBenefit(_ input: BenefitItem) {
    update { s in
      var benefit = input
      benefit.name = benefit.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !benefit.name.isEmpty else {
        throw AppError("请填写权益名称 / Benefit name required")
      }
      if let i = s.benefits.firstIndex(where: { $0.id == benefit.id }) {
        s.benefits[i] = benefit
      } else {
        s.benefits.append(benefit)
      }
    }
    if error == nil { notice = t("权益已保存", "Benefit saved") }
  }
  func removeBenefit(_ benefit: BenefitItem) {
    update { s in
      s.benefits.removeAll { $0.id == benefit.id }
      s.claims.removeAll { $0.id.hasPrefix("\(benefit.id)|") }
      s.tombstones.insert("deleted-benefit|\(benefit.id)")
    }
  }
  func renew(_ sub: Subscription, periods: Int, amount: Decimal) {
    update { try Engine.renew(&$0, subID: sub.id, periods: periods, amount: amount, paidAt: Date()) }
    if error == nil {
      notice = t("续费已记下，剩余天数已叠加", "Renewed. Remaining days stacked.")
    }
  }
  func remove(_ sub: Subscription) {
    update { s in
      s.subscriptions.removeAll { $0.id == sub.id }
      s.payments.removeAll { $0.subscriptionID == sub.id }
      // 删除订阅后，关联权益转为独立权益继续存在；属于这些权益的打卡记录保留，
      // 其余（无对应权益的历史打卡）随订阅移除。
      let surviving = s.benefits.filter { $0.subscriptionID == sub.id }.map { "\($0.id)|" }
      s.claims.removeAll { claim in
        claim.subscriptionID == sub.id && !surviving.contains { claim.id.hasPrefix($0) }
      }
      s.reviews.removeAll { $0.subscriptionID == sub.id }
      for i in s.events.indices where s.events[i].subscriptionID == sub.id {
        s.events[i].subscriptionID = nil
      }
      for i in s.benefits.indices where s.benefits[i].subscriptionID == sub.id {
        // 打卡归属同步改为权益自身 ID，保证存档引用完整。
        let benefitID = s.benefits[i].id
        for j in s.claims.indices where s.claims[j].id.hasPrefix("\(benefitID)|") {
          s.claims[j].subscriptionID = benefitID
        }
        s.benefits[i].subscriptionID = nil
      }
      s.tombstones.insert("deleted|\(sub.id)")
    }
  }
  func saveEvent(_ input: Event) {
    update { s in
      var event = input
      event.name = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !event.name.isEmpty else {
        throw AppError("请填写活动名称 / Event name required")
      }
      if let i = s.events.firstIndex(where: { $0.id == event.id }) {
        s.events[i] = event
      } else {
        s.events.append(event)
      }
    }
    if error == nil { notice = t("活动已保存", "Event saved") }
  }
  func toggleEvent(_ event: Event) {
    update { Engine.toggleEvent(&$0, id: event.id) }
    if error == nil, event.doneAt == nil {
      notice = t("活动已完成，干得漂亮", "Event completed. Nice.")
    }
  }
  func removeEvent(_ event: Event) {
    update { s in s.events.removeAll { $0.id == event.id } }
  }
  func backup() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "搞月供-\(Engine.day(Date(),state)).monthlybackup"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Database.backup(state).write(to: url, options: .atomic)
      notice = t("完整备份已导出", "Backup exported")
    } catch { self.error = error.localizedDescription }
  }
  func restore() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let (s, date) = try Database.decode(Data(contentsOf: url))
      let alert = NSAlert()
      alert.messageText = t("恢复完整备份？", "Restore full backup?")
      alert.informativeText =
        "\(date.formatted()) · \(s.subscriptions.count) "
        + t(
          "条订阅。将替换当前数据；恢复前会自动保留当前快照。",
          "subscriptions. Replaces current data after creating a safety snapshot.")
      alert.addButton(withTitle: t("恢复", "Restore"))
      alert.addButton(withTitle: t("取消", "Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      try db?.restore(s)
      reload()
      WidgetCenter.shared.reloadAllTimelines()
      notice = t("备份已恢复", "Backup restored")
    } catch { self.error = error.localizedDescription }
  }
  func export(_ kind: Int) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = ["订阅", "扣款流水", "权益领取"][kind] + ".csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var rows: [[String]] = []
    switch kind {
    case 0:
      rows =
        [
          [
            "id", "name", "category", "price", "currency", "cycle", "anchor", "auto_renew",
            "cancelled", "note",
          ]
        ]
        + state.subscriptions.map {
          [
            $0.id.uuidString, $0.name, $0.category, "\($0.current.price)", $0.current.currency,
            $0.current.cycle.rawValue, Engine.day($0.current.anchor, state), String($0.autoRenew),
            String($0.cancelledAt != nil), $0.note,
          ]
        }
    case 1:
      rows =
        [
          [
            "bill_id", "subscription_id", "due_date", "paid_date", "recorded_at", "amount",
            "currency", "skipped", "periods", "note",
          ]
        ]
        + state.payments.map {
          [
            $0.id, $0.subscriptionID.uuidString, Engine.day($0.due, state),
            Engine.day($0.paidAt, state), ISO8601DateFormatter().string(from: $0.recordedAt),
            "\($0.amount)", $0.currency, String($0.skipped), "\($0.coveredPeriods)", $0.note,
          ]
        }
    default:
      rows =
        [["id", "benefit", "subscription_id", "claim_date", "recorded_at", "backfill"]]
        + state.claims.map { claim in
          let benefit = state.benefits.first { claim.id.hasPrefix("\($0.id)|") }
          let name =
            benefit?.name
            ?? state.subscriptions.first { $0.id == claim.subscriptionID }?.name ?? ""
          return [
            claim.id, name, claim.subscriptionID.uuidString, Engine.day(claim.date, state),
            ISO8601DateFormatter().string(from: claim.recordedAt), String(claim.backfill),
          ]
        }
    }
    do {
      try Engine.csv(rows).write(to: url, atomically: true, encoding: .utf8)
      notice = t("CSV 已导出", "CSV exported")
    } catch { self.error = error.localizedDescription }
  }
  func enableNotifications() {
    Task {
      do {
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound,
        ])
        update { $0.preferences.notifications = allowed }
      } catch { self.error = error.localizedDescription }
    }
  }
  func refreshNotifications() {
    let previous = scheduleTask
    previous?.cancel()
    let snapshot = state
    scheduleTask = Task {
      if let previous { await previous.value }
      guard !Task.isCancelled else { return }
      await schedule(snapshot)
    }
  }
  private func schedule(_ s: State) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard !Task.isCancelled else { return }
    notificationStatus =
      settings.authorizationStatus == .authorized
      ? t("已允许", "Allowed")
      : settings.authorizationStatus == .denied
        ? t("系统已拒绝，请到系统设置开启", "Denied in System Settings") : t("尚未授权", "Not authorized")
    center.removeAllPendingNotificationRequests()
    guard s.preferences.notifications, settings.authorizationStatus == .authorized else {
      coverage = t("尚未排程", "Not scheduled")
      return
    }
    let c = Engine.calendar(s)
    let now = Date()
    var requests: [(Date, String, String)] = []
    for sub in s.subscriptions where sub.renewing && !sub.archived {
      var bills = Engine.bills(
        sub, state: s, from: now, through: c.date(byAdding: .day, value: 90, to: now)!)
      if bills.isEmpty, let next = Engine.next(sub, s) { bills = [next] }
      for b in bills where !Engine.covered(b, s) {
        for advance in Set(
          [sub.reminderDays ?? s.preferences.reminderDays] + (sub.autoRenew ? [0] : []))
        {
          let day = c.date(byAdding: .day, value: -advance, to: b.date)!
          let date = c.date(
            bySettingHour: s.preferences.reminderHour, minute: 0, second: 0, of: day)!
          if date > now {
            requests.append(
              (
                date, "bill|\(b.id)|\(advance)",
                s.preferences.privacy
                  ? t("有订阅即将续费，打开搞月供查看", "Subscription due. Open Gao Monthly.")
                  : "\(sub.name) · \(money(b.price,b.currency)) · \(Engine.day(b.date,s))"
              ))
          }
        }
      }
      if !sub.trialResolved, let deadline = sub.cancelDeadline ?? sub.trialEnd {
        let date = deadline.addingTimeInterval(-86400)
        if date > now {
          requests.append(
            (
              date, "trial|\(sub.id)",
              s.preferences.privacy
                ? t("试用即将到期", "Trial ending")
                : t("试用即将到期：", "Trial ending: ") + sub.name
                  + t("，请到平台核对取消截止时间", ". Check the cancellation deadline on the platform.")
            ))
        }
      }
    }
    let unique = Dictionary(requests.map { ($0.1, $0) }, uniquingKeysWith: { a, _ in a }).values
      .sorted { $0.0 < $1.0 }
    // Product queue budget, not a claim about a system-wide fixed limit.
    var added = 0
    var last: Date?
    var firstOmitted: Date?
    var failure: String?
    for (index, r) in unique.enumerated() {
      guard !Task.isCancelled else { return }
      if index >= 60 {
        if firstOmitted == nil { firstOmitted = r.0 }
        continue
      }
      let content = UNMutableNotificationContent()
            content.userInfo["module"] = "monthly"
      content.title = t("搞月供 · 续费提醒", "Gao Monthly · Reminder")
      content.body = r.2
      content.sound = .default
      var comps = c.dateComponents([.year, .month, .day, .hour, .minute], from: r.0)
      comps.timeZone = c.timeZone
      do {
        try await center.add(
          UNNotificationRequest(
            identifier: r.1, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        added += 1
        last = r.0
      } catch {
        failure = error.localizedDescription
        if firstOmitted == nil { firstOmitted = r.0 }
      }
    }
    guard !Task.isCancelled else { return }
    let pending = await center.pendingNotificationRequests()
    coverage =
      t("已排程 ", "Scheduled ") + "\(pending.count)" + t(" 条；最远至 ", "; latest ")
      + (last.map { Engine.day($0, s) } ?? "—") + "\n" + t("未排入 ", "Not scheduled: ")
      + "\(max(0,unique.count-added))"
      + (firstOmitted.map { t("；首个未覆盖：", "; first uncovered: ") + Engine.day($0, s) } ?? "")
      + (failure.map { "\n" + $0 } ?? "") + "\n"
      + t(
        "请定期打开 App 更新排程。通知受系统权限、专注与睡眠影响。",
        "Open regularly to replenish reminders. Delivery depends on system settings.")
  }
  func erase() {
    do {
      try db?.erase()
      UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
      reload()
      WidgetCenter.shared.reloadAllTimelines()
    } catch { self.error = error.localizedDescription }
  }
}
