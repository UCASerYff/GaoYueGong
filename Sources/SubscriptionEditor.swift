import SwiftUI

struct SubscriptionEditor: View {
  @EnvironmentObject var store: Store
  @Environment(\.dismiss) var dismiss
  @State var subscription: Subscription
  @State private var price = ""
  @State private var trial = false
  @State private var validation = ""
  @State private var effectiveDate = Date()
  private var isExisting: Bool { store.state.subscriptions.contains { $0.id == subscription.id } }
  private var plan: Binding<Plan> {
    Binding(
      get: { subscription.plans.last! },
      set: { subscription.plans[subscription.plans.count - 1] = $0 })
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Heading(
          title: store.t(
            isExisting ? "编辑订阅" : "添加一份月供", isExisting ? "Edit subscription" : "Add a subscription"),
          subtitle: store.t(
            "只记你确认过的价格。模板不是实时售价。", "Enter your actual price. Templates are not live quotes."))
        Spacer()
      }.padding(24)
      ScrollView {
        Form {
          if !isExisting {
            Section(store.t("快速开始", "Quick start")) {
              Picker(
                store.t("常用模板", "Template"),
                selection: Binding(
                  get: { "" },
                  set: { name in
                    if !name.isEmpty {
                      subscription.name = name
                      subscription.category =
                        ["Netflix", "哔哩哔哩", "腾讯视频"].contains(name)
                        ? "影音" : name == "游戏月卡" ? "游戏" : "工具"
                      subscription.symbol =
                        subscription.category == "游戏"
                        ? "gamecontroller"
                        : subscription.category == "工具" ? "sparkles" : "play.rectangle"
                    }
                  })
              ) {
                Text(store.t("选择后填写实际金额", "Choose then enter your price")).tag("")
                ForEach(
                  [
                    "ChatGPT", "Kimi", "Claude", "Netflix", "哔哩哔哩", "腾讯视频", "Apple Music",
                    "iCloud+", "游戏月卡",
                  ], id: \.self
                ) { Text($0).tag($0) }
              }
            }
          }
          Section(store.t("基本信息", "Basics")) {
            TextField(store.t("名称", "Name"), text: $subscription.name)
            Picker(store.t("分类", "Category"), selection: $subscription.category) {
              ForEach(["影音", "音乐", "工具", "云存储", "游戏", "生活", "其他"], id: \.self) { Text($0).tag($0) }
            }
            HStack {
              TextField(store.t("每期金额", "Price per cycle"), text: $price)
              Picker(store.t("币种", "Currency"), selection: plan.currency) {
                ForEach(["CNY", "USD", "EUR", "HKD", "JPY", "GBP"], id: \.self) { Text($0).tag($0) }
              }.frame(width: 160)
            }
            Picker(store.t("扣款周期", "Billing cycle"), selection: plan.cycle) {
              ForEach(Cycle.allCases) { Text($0.title(store.en)).tag($0) }
            }
            if subscription.current.cycle == .days {
              Stepper(
                store.t("间隔天数：", "Days: ") + "\(subscription.current.interval)",
                value: plan.interval, in: 1...3650)
            }
            DatePicker(
              store.t("计划首个扣款日", "First scheduled bill"), selection: plan.anchor,
              displayedComponents: .date)
            if isExisting {
              DatePicker(
                store.t("新计划生效日", "Plan effective date"), selection: $effectiveDate,
                displayedComponents: .date)
              Text(
                store.t(
                  "改价或改周期会保留旧计划。生效日前的流水不变。",
                  "Changes retain previous plans and historical payments.")
              ).font(.caption).foregroundStyle(.secondary)
            }
            if [.monthly, .quarterly, .yearly].contains(subscription.current.cycle) {
              Toggle(store.t("始终按月末扣款", "Always use month end"), isOn: plan.monthEnd)
            }
            Toggle(
              store.t("平台开启了自动续费", "Auto-renew is enabled on the platform"),
              isOn: $subscription.autoRenew)
            Toggle(
              store.t("月卡模式（剩余天数叠加）", "Monthly pass mode (days stack)"),
              isOn: Binding(
                get: { subscription.stacking ?? false },
                set: { subscription.stacking = $0 }))
            if subscription.isStacking {
              Text(
                store.t(
                  "提前续费直接在剩余天数上累加：每月按 30 天、每周 7 天、每季 90 天、每年 365 天计。",
                  "Early renewals stack on remaining days: month = 30 days, week = 7, quarter = 90, year = 365.")
              ).font(.caption).foregroundStyle(.secondary)
            }
          }
          Section(store.t("试用", "Trial")) {
            Toggle(store.t("目前处于免费试用", "Currently on a free trial"), isOn: $trial)
            if trial {
              DatePicker(
                store.t("试用截止", "Trial ends"),
                selection: Binding(
                  get: { subscription.trialEnd ?? subscription.current.anchor },
                  set: { subscription.trialEnd = $0 }), displayedComponents: .date)
              DatePicker(
                store.t("最晚取消时间", "Cancel before"),
                selection: Binding(
                  get: { subscription.cancelDeadline ?? subscription.current.anchor },
                  set: { subscription.cancelDeadline = $0 }))
              Text(
                store.t(
                  "上方金额为试用结束后每期价格，首扣日期请与平台核对。",
                  "Price above applies after the trial. Verify the first bill date.")
              ).font(.caption).foregroundStyle(.secondary)
            }
            Text(
              store.t(
                "权益打卡在「权益」模块中管理，可关联此订阅。",
                "Benefit check-ins live in the Benefits tab and can link to this subscription.")
            ).font(.caption).foregroundStyle(.secondary)
          }
          Section(store.t("更多选项", "More")) {
            TextField(store.t("平台管理链接（可选）", "Management URL (optional)"), text: $subscription.link)
            TextField(
              store.t("备注 / 账号提示", "Note / account hint"), text: $subscription.note, axis: .vertical
            ).lineLimit(2...4)
            Picker(store.t("图标", "Icon"), selection: $subscription.symbol) {
              ForEach(
                [
                  "play.rectangle", "music.note", "sparkles", "cloud", "gamecontroller", "bag",
                  "book", "globe", "creditcard",
                ], id: \.self
              ) { Label($0, systemImage: $0).tag($0) }
            }
            Picker(store.t("颜色", "Color"), selection: $subscription.color) {
              ForEach(["blue", "teal", "orange", "purple", "green"], id: \.self) {
                Text($0).tag($0)
              }
            }
            Stepper(
              store.t("提前提醒天数：", "Remind days before: ")
                + "\(subscription.reminderDays ?? store.state.preferences.reminderDays)",
              value: Binding(
                get: { subscription.reminderDays ?? store.state.preferences.reminderDays },
                set: { subscription.reminderDays = $0 }), in: 0...30)
          }
        }.formStyle(.grouped)
      }
      if !validation.isEmpty {
        Text(validation).foregroundStyle(.red).font(.caption).padding(.horizontal, 24)
      }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(store.t("保存订阅", "Save subscription")) { save() }.buttonStyle(.borderedProminent)
          .tint(Theme.teal).keyboardShortcut(.defaultAction)
      }.padding(24)
    }.frame(width: 610, height: 750).onAppear {
      price = isExisting ? "\(subscription.current.price)" : ""
      trial = subscription.trialEnd != nil
      effectiveDate = Engine.next(subscription, store.state)?.date ?? Date()
      if !isExisting {
        subscription.plans[0].start = Engine.calendar(store.state).startOfDay(for: Date())
      }
    }
  }
  func save() {
    guard !subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      price.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
      let amount = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")), amount > 0,
      amount <= 999_999_999
    else {
      validation = store.t("请填写名称与大于 0 的有效金额。", "Enter a name and a valid positive price.")
      return
    }
    var rounded = Decimal()
    var input = amount
    NSDecimalRound(&rounded, &input, subscription.current.currency == "JPY" ? 0 : 2, .plain)
    guard rounded == amount else {
      validation = store.t("金额的小数位超过币种精度。", "Too many decimal places for this currency.")
      return
    }
    if !subscription.link.isEmpty {
      guard let u = URL(string: subscription.link), ["http", "https"].contains(u.scheme ?? ""),
        u.host != nil
      else {
        validation = store.t("管理链接应以 https:// 或 http:// 开头。", "Enter a valid http(s) URL.")
        return
      }
    }
    subscription.plans[subscription.plans.count - 1].price = amount
    if let original = store.state.subscriptions.first(where: { $0.id == subscription.id }),
      original.current != subscription.current
    {
      subscription.plans[subscription.plans.count - 1].start = effectiveDate
    }
    if !isExisting {
      subscription.plans[0].start = min(subscription.plans[0].start, subscription.current.anchor)
    }
    if trial {
      subscription.trialEnd = subscription.trialEnd ?? subscription.current.anchor
      subscription.cancelDeadline = subscription.cancelDeadline ?? subscription.trialEnd
    } else {
      subscription.trialEnd = nil
      subscription.cancelDeadline = nil
    }
    store.error = nil
    store.save(subscription)
  }
}
struct PaymentEditor: View {
  @EnvironmentObject var store: Store
  @Environment(\.dismiss) var dismiss
  var bill: Bill
  @State var amount = ""
  @State var paidAt = Date()
  @State var skipped = false
  @State var note = ""
  @State var periods = 1
  @State var validation = ""
  var existing: Payment? { store.state.payments.first { $0.id == bill.id } }
  var stacking: Bool {
    store.state.subscriptions.first { $0.id == bill.subscriptionID }?.isStacking == true
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Heading(
        title: store.t(
          existing == nil ? "核实本期扣款" : "编辑扣款流水",
          existing == nil ? "Confirm payment" : "Edit payment"),
        subtitle: (store.state.subscriptions.first { $0.id == bill.subscriptionID }?.name ?? "")
          + " · " + Engine.day(bill.date, store.state))
      Form {
        Toggle(store.t("本期未扣款", "Not charged this cycle"), isOn: $skipped)
        if !skipped {
          if stacking {
            Stepper(
              store.t("覆盖期数：", "Periods covered: ") + "\(periods)",
              value: $periods, in: 1...12
            ).onChange(of: periods) { _, n in
              amount = "\(bill.price * Decimal(n))"
            }
          }
          TextField(store.t("实际金额", "Actual amount") + " (\(bill.currency))", text: $amount)
          DatePicker(
            store.t("实际支付日", "Payment date"), selection: $paidAt, in: ...Date(),
            displayedComponents: .date)
        }
        TextField(store.t("备注", "Note"), text: $note)
      }
      Text(
        store.t(
          "仅记录实际发生的扣款，不会进行支付，也不会更改平台订阅。",
          "Records an actual payment. This does not pay or change the platform subscription.")
      ).font(.caption).foregroundStyle(.secondary)
      if !validation.isEmpty { Text(validation).foregroundStyle(.red) }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }
        Spacer()
        Button(store.t("保存", "Save")) { save() }.buttonStyle(.borderedProminent).tint(Theme.teal)
      }
    }.padding(28).frame(width: 480).onAppear {
      if let e = existing {
        amount = "\(e.amount)"
        paidAt = e.paidAt
        skipped = e.skipped
        note = e.note
        periods = e.coveredPeriods
      } else {
        amount = "\(bill.price)"
        paidAt = min(Date(), bill.date)
      }
    }
  }
  func save() {
    guard let value = Decimal(string: amount), value >= 0 else {
      validation = store.t("请填写有效金额", "Invalid amount")
      return
    }
    var rounded = Decimal()
    var raw = value
    NSDecimalRound(&rounded, &raw, bill.currency == "JPY" ? 0 : 2, .plain)
    guard rounded == value, value <= 999_999_999 else {
      validation = store.t("金额超出范围或币种精度", "Invalid currency precision or amount")
      return
    }
    store.error = nil
    store.update { s in
      if let i = s.payments.firstIndex(where: { $0.id == bill.id }) {
        s.payments[i].amount = value
        s.payments[i].paidAt = paidAt
        s.payments[i].skipped = skipped
        s.payments[i].note = note
        s.payments[i].periods = skipped ? nil : periods
      } else {
        try Engine.confirm(&s, bill: bill, amount: value, paidAt: paidAt, skipped: skipped)
        if let i = s.payments.firstIndex(where: { $0.id == bill.id }) {
          s.payments[i].note = note
          s.payments[i].periods = skipped ? nil : periods
        }
      }
    }
    if store.error == nil { dismiss() }
  }
}
