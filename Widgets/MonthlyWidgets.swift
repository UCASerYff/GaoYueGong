import AppIntents
import SwiftUI
import WidgetKit

struct ClaimBenefitIntent: AppIntent {
  static var title: LocalizedStringResource = "领取权益 / Claim benefit"
  static var openAppWhenRun = false
  @Parameter(title: "权益 ID") var benefitID: String
  init() {}
  init(_ id: UUID) { benefitID = id.uuidString }
  func perform() async throws -> some IntentResult {
    guard let id = UUID(uuidString: benefitID) else { throw AppError("Invalid benefit") }
    let db = try Database()
    try db.transaction { try Engine.claim(&$0, benefitID: id, date: Date()) }
    try db.snapshot()
    WidgetCenter.shared.reloadAllTimelines()
    return .result()
  }
}
struct MonthlyEntry: TimelineEntry {
  var date: Date
  var state: State?
}
struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> MonthlyEntry { MonthlyEntry(date: Date(), state: nil) }
  func getSnapshot(in context: Context, completion: @escaping (MonthlyEntry) -> Void) {
    completion(MonthlyEntry(date: Date(), state: try? Database().read()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<MonthlyEntry>) -> Void) {
    completion(
      Timeline(
        entries: [MonthlyEntry(date: Date(), state: try? Database().read())],
        policy: .after(Date().addingTimeInterval(900))))
  }
}
struct MonthlyWidgetView: View {
  var entry: MonthlyEntry
  @Environment(\.widgetFamily) var family
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("搞月供", systemImage: "calendar.badge.clock").font(.headline)
        Spacer()
        if let s = entry.state {
          let overdueCount = Engine.pending(s).filter {
            $0.date < Engine.calendar(s).startOfDay(for: Date())
          }.count
          if overdueCount > 0 {
            Label("\(overdueCount)", systemImage: "exclamationmark.circle.fill")
              .font(.caption.bold()).foregroundStyle(.orange)
          } else {
            Image(systemName: "pawprint.fill").foregroundStyle(.teal)
          }
        } else {
          Image(systemName: "pawprint.fill").foregroundStyle(.teal)
        }
      }
      if let s = entry.state {
        let bills = Engine.upcoming(s, days: 7)
        let overdue = Engine.pending(s).filter {
          $0.date < Engine.calendar(s).startOfDay(for: Date())
        }
        let due = Engine.dueBenefits(s)
        let maxBills = family == .systemSmall ? 1 : (due.isEmpty ? 3 : 2)
        if bills.isEmpty {
          Text(overdue.isEmpty ? "近期没有扣款" : "\(overdue.count) 笔待核实").font(.title3.bold())
          Text(s.subscriptions.isEmpty ? "打开 App 添加订阅" : "供得明白，心里有数").font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(bills.prefix(maxBills))) { b in
            HStack {
              Text(
                s.preferences.privacy
                  ? "订阅" : s.subscriptions.first { $0.id == b.subscriptionID }?.name ?? "订阅"
              ).lineLimit(1)
              Spacer()
              Text(s.preferences.privacy ? "•••" : money(b.price, b.currency)).bold()
              Text(b.date, format: .dateTime.month().day()).foregroundStyle(.secondary)
            }.font(.caption)
          }
        }
        if family == .systemMedium {
          ForEach(Array(due.prefix(2)), id: \.id) { benefit in
            Button(intent: ClaimBenefitIntent(benefit.id)) {
              Label(
                s.preferences.privacy ? "领取今日权益" : "领取 · \(benefit.name)",
                systemImage: "checkmark.circle"
              ).font(.caption.bold()).frame(maxWidth: .infinity)
            }.tint(.teal)
          }
        }
        if family == .systemSmall {
          let paid = s.payments.filter {
            !$0.skipped && Engine.month($0.paidAt, s) == Engine.month(Date(), s)
          }
          let currencies = Set(paid.map(\.currency)).sorted()
          Text(
            currencies.isEmpty
              ? "本月暂无已确认支出"
              : s.preferences.privacy
                ? "本月已供 •••"
                : currencies.prefix(2).map { code in
                  money(
                    paid.filter { $0.currency == code }.reduce(Decimal(0)) { $0 + $1.amount }, code)
                }.joined(separator: " / ")
          ).font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        Text("打开 App 完成初始化").font(.callout)
        Text("数据暂不可读时，不执行打卡").font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Text("更新 \(entry.date.formatted(date:.omitted,time:.shortened))").font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }.containerBackground(.background, for: .widget).widgetURL(URL(string: "gaoyuegong://today"))
  }
}
@main struct MonthlyWidgets: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "GaoYueGong", provider: Provider()) { MonthlyWidgetView(entry: $0) }
      .configurationDisplayName("搞月供 · 扣款与权益").description("看清下一笔扣款，顺手领回今日权益。").supportedFamilies([
        .systemSmall, .systemMedium,
      ])
  }
}
