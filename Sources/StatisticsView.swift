import Charts
import SwiftUI

struct StatisticsView: View {
  @EnvironmentObject var store: Store
  @State var currency = "CNY"
  var current: [Subscription] {
    store.state.subscriptions.filter {
      $0.renewing && !$0.archived && $0.current.currency == currency
        && ($0.trialEnd == nil || $0.trialResolved)
    }
  }
  var monthly: Decimal { current.reduce(0) { $0 + Engine.monthly($1.current) } }
  var trend: [(String, Double)] {
    let c = Engine.calendar(store.state)
    let first = c.dateInterval(of: .month, for: Date())!.start
    return (0..<12).reversed().map { i in
      let d = c.date(byAdding: .month, value: -i, to: first)!
      let key = Engine.month(d, store.state)
      let total = store.state.payments.filter {
        !$0.skipped && $0.currency == currency && Engine.month($0.paidAt, store.state) == key
      }.reduce(Decimal(0)) { $0 + $1.amount }
      return (key, (total as NSDecimalNumber).doubleValue)
    }
  }
  var categories: [(String, Decimal)] {
    Dictionary(grouping: current, by: { $0.category }).map {
      ($0.key, $0.value.reduce(Decimal(0)) { $0 + Engine.monthly($1.current) })
    }.sorted { $0.1 > $1.1 }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Heading(
          title: store.t("钱花在哪，一眼看清。", "See where your money goes."),
          subtitle: store.t(
            "真实支出、长期折算和使用记录，分开看才准确。",
            "Actual payments, equivalents and usage are separate measures."))
        Spacer()
        Picker(store.t("币种", "Currency"), selection: $currency) {
          ForEach(["CNY", "USD", "EUR", "HKD", "JPY", "GBP"], id: \.self) { Text($0).tag($0) }
        }.frame(width: 130)
      }
      HStack(spacing: 16) {
        Metric(
          label: store.t("月供折算", "Monthly equivalent"), value: money(monthly, currency),
          footnote: store.t("当前有效付费订阅", "Current paid subscriptions"), symbol: "calendar")
        Metric(
          label: store.t("年供折算", "Annual equivalent"), value: money(monthly * 12, currency),
          footnote: store.t("按当前价格估算", "Estimated at current prices"),
          symbol: "calendar.badge.clock", color: Theme.blue)
        Metric(
          label: store.t("管理中的订阅", "Active subscriptions"), value: "\(current.count)",
          footnote: currency, symbol: "rectangle.stack", color: Theme.purple)
      }
      VStack(alignment: .leading, spacing: 20) {
        Text(store.t("近 12 个月 · 实际已供", "Actual payments · Last 12 months")).font(.headline)
        Chart(Array(trend.enumerated()), id: \.offset) { i, row in
          BarMark(x: .value("Month", String(row.0.suffix(5))), y: .value("Paid", row.1))
            .foregroundStyle(Theme.teal).cornerRadius(4)
        }.frame(height: 210).accessibilityLabel(store.t("月度实际支出图", "Monthly actual payments"))
        DisclosureGroup(store.t("查看月度明细", "Monthly details")) {
          ForEach(Array(trend.enumerated()), id: \.offset) { _, row in
            HStack {
              Text(row.0)
              Spacer()
              Text(money(Decimal(row.1), currency))
            }.font(.caption)
          }
        }
        Text(
          store.t(
            "按实际支付日归属；未确认、本期未扣与预计金额不计入。",
            "Grouped by payment date. Unconfirmed and skipped periods are excluded.")
        ).font(.caption).foregroundStyle(.secondary)
      }.card()
      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 18) {
          Text(store.t("分类月折算", "Monthly equivalent by category")).font(.headline)
          if categories.isEmpty {
            Text(store.t("添加订阅后显示分类占比。", "Add subscriptions to see categories.")).foregroundStyle(
              .secondary)
          }
          ForEach(categories, id: \.0) { name, value in
            VStack(spacing: 7) {
              HStack {
                Text(name)
                Spacer()
                Text(money(value, currency))
              }.font(.callout)
              ProgressView(
                value: (value as NSDecimalNumber).doubleValue,
                total: max(1, (monthly as NSDecimalNumber).doubleValue)
              ).tint(Theme.teal)
            }
          }
        }.card()
        VStack(alignment: .leading, spacing: 18) {
          Text(store.t("续费前，问问自己", "Before renewing")).font(.headline)
          let dusty = store.state.subscriptions.filter {
            $0.renewing && Engine.dusty($0, store.state)
          }
          if dusty.isEmpty {
            Text(
              store.t(
                "暂时没有连续两个完整月吃灰的订阅。新订阅需要积累记录，不会立即被判为吃灰。",
                "No subscriptions were unused for two complete months. New entries need time to gather evidence."
              )
            ).foregroundStyle(.secondary)
          }
          ForEach(dusty) { sub in
            VStack(alignment: .leading, spacing: 5) {
              Text(sub.name).bold()
              Text(
                store.t("预计未来一年减少 ", "Potential annual reduction: ")
                  + money(Engine.monthly(sub.current) * 12, sub.current.currency)
              ).font(.caption).foregroundStyle(.secondary)
            }
          }
          Text(store.t("领取记录只是参考，不等于真实使用价值。", "Claims are a signal, not a measure of real value."))
            .font(.caption).foregroundStyle(.secondary)
        }.card()
      }
      VStack(alignment: .leading, spacing: 14) {
        Text(store.t("断供纪念册", "Cancellation archive")).font(.headline)
        let cancelled = store.state.subscriptions.filter { !$0.renewing }
        if cancelled.isEmpty {
          Text(store.t("每一次清醒的决定，都值得记下来。", "Every considered decision is worth recording."))
            .foregroundStyle(.secondary)
        }
        ForEach(cancelled) { sub in
          HStack {
            Tile(symbol: sub.symbol, color: Theme.color(sub.color))
            Text(sub.name)
            Spacer()
            Text(Engine.day(sub.cancelledAt!, store.state)).foregroundStyle(.secondary)
          }
        }
      }.card()
    }.onAppear {
      if store.state.preferences.game { store.update { $0.pet.titles.insert("annual") } }
      // 币种默认跟随已有订阅，而不是永远落在 CNY。
      let currencies = Set(
        store.state.subscriptions.filter { !$0.archived }.map { $0.current.currency })
      if !currencies.contains(currency), let first = currencies.sorted().first {
        currency = first
      }
    }
  }
}
