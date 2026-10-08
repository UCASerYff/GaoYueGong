import AppIntents
import SwiftUI
import WidgetKit

/// Widgets only open an existing store. A missing shared database is unavailable,
/// never a reason for an extension to initialize an empty replacement.
private func widgetDatabase() throws -> Database {
  let directory = try Database.location()
  let path = directory.appendingPathComponent("monthly.sqlite").path
  guard FileManager.default.fileExists(atPath: path), FileManager.default.isReadableFile(atPath: path)
  else { throw AppError("数据暂不可读，请打开搞月供 / Open Gao Yue Gong to load your data") }
  return try Database(directory: directory, createIfMissing: false)
}

struct ClaimBenefitIntent: AppIntent {
  static var title: LocalizedStringResource = "领取权益 / Claim benefit"
  static var openAppWhenRun = false
  @Parameter(title: "权益 ID") var benefitID: String
  init() {}
  init(_ id: UUID) { benefitID = id.uuidString }
  func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: benefitID) else { throw AppError("Invalid benefit") }
    let db = try widgetDatabase()
    let now = Date()
    // Re-read inside the transaction; an entry is only a display snapshot.
    try db.transaction { try Engine.claim(&$0, benefitID: id, date: now, now: now) }
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("GaoSeries.monthly.changed"), object: "GaoYueGongWidgets",
      userInfo: nil, deliverImmediately: true)
    WidgetCenter.shared.reloadAllTimelines()
    // A failed automatic snapshot must not turn a committed claim into a failed action.
    try? db.snapshot()
    return .result()
  }
}

struct MonthlyEntry: TimelineEntry {
  var date: Date
  var state: State?
  var isEnglish: Bool { state?.preferences.language == "en" }
  var timeZone: TimeZone {
    state.map { Engine.calendar($0).timeZone } ?? .current
  }
  func text(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> MonthlyEntry { MonthlyEntry(date: Date(), state: nil) }
  func getSnapshot(in context: Context, completion: @escaping (MonthlyEntry) -> Void) {
    completion(MonthlyEntry(date: Date(), state: try? widgetDatabase().read()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<MonthlyEntry>) -> Void) {
    let now = Date()
    let state = try? widgetDatabase().read()
    let calendar = state.map { Engine.calendar($0) } ?? Calendar.current
    let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    completion(Timeline(
      entries: [MonthlyEntry(date: now, state: state)],
      policy: .after(min(midnight, now.addingTimeInterval(900)))))
  }
}

private struct WidgetUpdatedLabel: View {
  let entry: MonthlyEntry
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .medium))
      Text(entry.text("更新", "Updated"))
      Text(entry.date, format: Date.FormatStyle(date: .omitted, time: .shortened, timeZone: entry.timeZone))
    }
    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct BenefitClaimButton: View {
  let benefit: BenefitItem
  let entry: MonthlyEntry
  var body: some View {
    Button(intent: ClaimBenefitIntent(benefit.id)) {
      HStack(spacing: 5) {
        Image(systemName: "checkmark.circle")
        Text(entry.state?.preferences.privacy == true
          ? entry.text("标记已领", "Mark claimed") : benefit.name)
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .font(.system(size: 11, weight: .semibold))
      .frame(maxWidth: .infinity, minHeight: 19)
    }
    .buttonStyle(.bordered).tint(.teal)
    .accessibilityLabel(entry.state?.preferences.privacy == true
      ? entry.text("标记权益已领取", "Mark benefit claimed")
      : entry.text("标记已领取：", "Mark claimed: ") + benefit.name)
    .accessibilityHint(entry.text("记录打卡，请记得在平台实际领取", "Records your check-in; claim on the provider's platform"))
  }
}

private struct WidgetUnavailableView: View {
  let entry: MonthlyEntry
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(entry.text("打开 App 读取数据", "Open app to load data")).font(.callout.weight(.semibold))
      Text(entry.text("数据暂不可读时，不执行打卡", "Check-ins are unavailable until data loads"))
        .font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MonthlyWidgetView: View {
  var entry: MonthlyEntry
  @Environment(\.widgetFamily) var family
  private var isSmall: Bool { family == .systemSmall }

  var body: some View {
    // Keep the header, content and timestamp together, centered in the available
    // area. A trailing Spacer previously pinned the title and timestamp to opposite edges.
    VStack(alignment: .leading, spacing: 9) {
      header
      if let state = entry.state {
        content(state)
      } else {
        WidgetUnavailableView(entry: entry)
      }
      WidgetUpdatedLabel(entry: entry)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .containerBackground(.background, for: .widget)
    .environment(\.timeZone, entry.timeZone)
    .environment(\.locale, Locale(identifier: entry.isEnglish ? "en_US" : "zh_CN"))
    .widgetURL(URL(string: "gaoyuegong://today"))
  }

  private var header: some View {
    HStack(spacing: 6) {
      Label(entry.text("搞月供", "Gao Yue Gong"), systemImage: "calendar.badge.clock")
        .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
      Spacer(minLength: 2)
      if let state = entry.state {
        let overdueCount = overdue(state).count
        if overdueCount > 0 {
          Label("\(overdueCount)", systemImage: "exclamationmark.circle.fill")
            .font(.caption2.bold()).foregroundStyle(.orange)
        } else {
          Image(systemName: "pawprint.fill").font(.caption).foregroundStyle(.teal)
        }
      }
    }
  }

  private func overdue(_ state: State) -> [Bill] {
    Engine.pending(state, now: entry.date).filter {
      $0.date < Engine.calendar(state).startOfDay(for: entry.date)
    }
  }

  @ViewBuilder private func content(_ state: State) -> some View {
    let bills = Engine.upcoming(state, now: entry.date, days: 7)
    let due = Engine.dueBenefits(state, now: entry.date)
    if isSmall {
      VStack(alignment: .leading, spacing: 6) {
        if let bill = bills.first {
          Text(subscriptionName(bill, state)).font(.caption).lineLimit(1)
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(state.preferences.privacy ? "•••" : money(bill.price, bill.currency))
              .font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(bill.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.secondary)
          }
        } else {
          noBills(state)
        }
        Text(monthlyPaid(state)).font(.system(size: 10)).foregroundStyle(.secondary)
          .lineLimit(1).minimumScaleFactor(0.85)
      }
    } else {
      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 7) {
          if bills.isEmpty {
            noBills(state)
          } else {
            ForEach(Array(bills.prefix(due.isEmpty ? 3 : 2))) { bill in
              HStack(spacing: 6) {
                Text(subscriptionName(bill, state)).lineLimit(1)
                Spacer(minLength: 2)
                Text(state.preferences.privacy ? "•••" : money(bill.price, bill.currency))
                  .bold().lineLimit(1)
                Text(bill.date, format: .dateTime.month().day()).foregroundStyle(.secondary)
              }.font(.system(size: 11))
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if !due.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.text("权益待领 \(due.count)", "\(due.count) to claim"))
              .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(Array(due.prefix(2))) { benefit in
              BenefitClaimButton(benefit: benefit, entry: entry)
            }
          }
          .frame(width: 116)
        }
      }
    }
  }

  @ViewBuilder private func noBills(_ state: State) -> some View {
    let count = overdue(state).count
    Text(count == 0 ? entry.text("近期没有扣款", "No upcoming bills")
      : entry.text("\(count) 笔待核实", "\(count) to verify"))
      .font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
    Text(state.subscriptions.isEmpty ? entry.text("打开 App 添加订阅", "Add a subscription in app")
      : entry.text("供得明白，心里有数", "Stay on top of your subscriptions"))
      .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
  }

  private func subscriptionName(_ bill: Bill, _ state: State) -> String {
    state.preferences.privacy ? entry.text("订阅", "Subscription")
      : state.subscriptions.first { $0.id == bill.subscriptionID }?.name ?? entry.text("订阅", "Subscription")
  }

  private func monthlyPaid(_ state: State) -> String {
    let paid = state.payments.filter {
      !$0.skipped && Engine.month($0.paidAt, state) == Engine.month(entry.date, state)
    }
    let currencies = Set(paid.map(\.currency)).sorted()
    if currencies.isEmpty { return entry.text("本月暂无已确认支出", "No confirmed spend this month") }
    if state.preferences.privacy { return entry.text("本月已供 •••", "Paid this month •••") }
    return currencies.prefix(2).map { code in
      money(paid.filter { $0.currency == code }.reduce(Decimal(0)) { $0 + $1.amount }, code)
    }.joined(separator: " / ")
  }
}

struct BenefitsWidgetView: View {
  var entry: MonthlyEntry
  @Environment(\.widgetFamily) var family
  private var isSmall: Bool { family == .systemSmall }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Label(entry.text("权益打卡", "Benefit check-in"), systemImage: "gift.fill")
          .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        Spacer(minLength: 0)
        if !isSmall {
          Text(entry.text("搞月供", "Gao Yue Gong")).font(.caption2).foregroundStyle(.secondary)
        }
      }
      if let state = entry.state {
        content(state)
      } else {
        WidgetUnavailableView(entry: entry)
      }
      WidgetUpdatedLabel(entry: entry)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .containerBackground(.background, for: .widget)
    .environment(\.timeZone, entry.timeZone)
    .environment(\.locale, Locale(identifier: entry.isEnglish ? "en_US" : "zh_CN"))
    .widgetURL(URL(string: "gaoyuegong://benefits"))
  }

  @ViewBuilder private func content(_ state: State) -> some View {
    let active = state.benefits.filter { Engine.claimKey($0, state, on: entry.date) != nil }
    let due = Engine.dueBenefits(state, now: entry.date)
    let completed = active.count - due.count
    if active.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(entry.text("今天暂无待领权益", "No active benefits"))
          .font(.system(size: 15, weight: .semibold)).lineLimit(2)
        Text(state.benefits.isEmpty ? entry.text("打开 App 添加每日或每周权益", "Add daily or weekly benefits in app")
          : entry.text("查看权益与关联订阅状态", "Review benefits and linked subscriptions"))
          .font(.caption2).foregroundStyle(.secondary)
      }
    } else if isSmall {
      VStack(alignment: .leading, spacing: 6) {
        progress(completed: completed, total: active.count, pending: due.count)
        if let benefit = due.first {
          BenefitClaimButton(benefit: benefit, entry: entry)
        } else {
          Label(entry.text("本期已全部领取", "All claimed this period"), systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.teal)
        }
      }
    } else {
      HStack(alignment: .center, spacing: 18) {
        progress(completed: completed, total: active.count, pending: due.count)
          .frame(width: 110)
        VStack(alignment: .leading, spacing: 4) {
          if due.isEmpty {
            Label(entry.text("本期已全部领取", "All claimed this period"), systemImage: "checkmark.circle.fill")
              .font(.system(size: 12, weight: .semibold)).foregroundStyle(.teal)
            Text(entry.text("每日 / 每周权益各按本期统计", "Daily and weekly benefits follow their own periods"))
              .font(.system(size: 10)).foregroundStyle(.secondary)
          } else {
            ForEach(Array(due.prefix(2))) { benefit in
              BenefitClaimButton(benefit: benefit, entry: entry)
            }
            Text(due.count > 2 ? entry.text("另有 \(due.count - 2) 项，打开查看", "\(due.count - 2) more in app")
              : entry.text("打卡后记得在平台实际领取", "Remember to claim on the platform"))
              .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func progress(completed: Int, total: Int, pending: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("\(pending)").font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
        Text(entry.text("待领", "left")).font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 1)
        if isSmall {
          Text(entry.text("已领 \(completed)/\(total)", "\(completed)/\(total) done"))
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.teal.opacity(0.14))
          Capsule().fill(.teal)
            .frame(width: geometry.size.width * Double(completed) / Double(max(1, total)))
        }
      }
      .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.text("本期领取进度", "Current period progress"))
        .accessibilityValue(entry.text("已领 \(completed) 项，共 \(total) 项", "\(completed) of \(total) claimed"))
      if !isSmall {
        Text(entry.text("本期已领 \(completed)/\(total)", "Claimed \(completed)/\(total)"))
          .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }
}

struct MonthlyOverviewWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "GaoYueGong", provider: Provider()) { MonthlyWidgetView(entry: $0) }
      .configurationDisplayName("搞月供 · 扣款与权益")
      .description("看清下一笔扣款，顺手领回今日权益。")
      .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct MonthlyBenefitsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "GaoYueGongBenefits", provider: Provider()) { BenefitsWidgetView(entry: $0) }
      .configurationDisplayName("搞月供 · 权益打卡")
      .description("查看每日与每周权益的本期待领数量、领取进度，直接记录打卡。")
      .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main struct MonthlyWidgets: WidgetBundle {
  var body: some Widget {
    MonthlyOverviewWidget()
    MonthlyBenefitsWidget()
  }
}
