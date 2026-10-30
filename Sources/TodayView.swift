import SwiftUI

struct TodayView: View {
  @EnvironmentObject var store: Store
  @State var editingEvent: Event?
  @State var deletingEvent: Event?
  var visibleEvents: [Event] {
    // 未完成的活动按截止日升序；已完成的活动保留 14 天供回顾，逾期未完成的置顶。
    let c = Engine.calendar(store.state)
    let cutoff = c.date(byAdding: .day, value: -14, to: Date())!
    return store.state.events.filter {
      $0.doneAt == nil || $0.doneAt! >= cutoff
    }.sorted { lhs, rhs in
      if (lhs.doneAt == nil) != (rhs.doneAt == nil) { return lhs.doneAt == nil }
      return lhs.deadline < rhs.deadline
    }
  }
  var upcoming: [Bill] {
    Engine.upcoming(store.state, days: 7).filter {
      $0.date > Engine.calendar(store.state).startOfDay(for: Date())
    }
  }
  var pending: [Bill] { Engine.pending(store.state) }
  var benefits: [BenefitItem] { Engine.dueBenefits(store.state) }
  func totals(_ actual: Bool) -> String {
    var values: [String: Decimal] = [:]
    if actual {
      for p in store.state.payments
      where !p.skipped && Engine.month(p.paidAt, store.state) == Engine.month(Date(), store.state) {
        values[p.currency, default: 0] += p.amount
      }
    } else {
      for sub in store.state.subscriptions
      where sub.renewing && !sub.archived && (sub.trialEnd == nil || sub.trialResolved) {
        values[sub.current.currency, default: 0] += Engine.monthly(sub.current)
      }
    }
    return values.isEmpty
      ? "0.00" : values.keys.sorted().map { money(values[$0]!, $0) }.joined(separator: " · ")
  }
  var body: some View {
    HStack {
      Heading(
        title: store.t("今天，也要供得明白。", "Make every subscription count."),
        subtitle: Date().formatted(Date.FormatStyle(
          locale: Locale(identifier: store.en ? "en_US" : "zh_CN"),
          calendar: Engine.calendar(store.state), timeZone: Engine.calendar(store.state).timeZone
        ).year().month().day().weekday()))
      Spacer()
      if store.state.preferences.game {
        Label(store.state.pet.name, systemImage: "pawprint.fill").font(.callout).foregroundStyle(
          Theme.teal)
      }
    }
    HStack(spacing: 16) {
      Metric(
        label: store.t("本月已供", "Paid this month"), value: totals(true),
        footnote: store.t("按实际支付日统计", "By actual payment date"), symbol: "creditcard")
      Metric(
        label: store.t("当前月折算", "Monthly equivalent"), value: totals(false),
        footnote: store.t("用于比较，不等于本月账单", "Comparison, not this month’s bill"),
        symbol: "arrow.triangle.2.circlepath", color: Theme.blue)
      Metric(
        label: store.t("待核实扣款", "To confirm"), value: "\(pending.count)",
        footnote: store.t("确认后才计入真实支出", "Only confirmed payments count"),
        symbol: "checkmark.shield", color: Theme.orange)
    }
    if store.state.subscriptions.isEmpty {
      VStack {
        EmptyState(
          symbol: "rectangle.stack.badge.plus",
          title: store.t("从第一份订阅开始", "Start with your first subscription"),
          subtitle: store.t(
            "视频会员、AI 工具、云存储、游戏月卡……\n把散落的月供，放在一起看清楚。",
            "Video, AI tools, cloud storage, game passes…\nSee all your subscriptions in one place."
          ))
        Button(store.t("添加第一条订阅", "Add your first subscription")) { store.editor = Subscription() }
          .buttonStyle(.borderedProminent).tint(Theme.teal).padding(.bottom, 20)
      }.card()
    }
    let urgent = store.state.subscriptions.filter {
      !$0.archived && $0.renewing && ($0.cancelIntent || ($0.trialEnd != nil && !$0.trialResolved))
    }
    if !urgent.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        Label(store.t("需要你做个决定", "Needs your decision"), systemImage: "exclamationmark.circle")
          .font(.headline).foregroundStyle(Theme.orange)
        ForEach(urgent) { sub in
          HStack {
            Text(sub.name).bold()
            Text(
              sub.cancelIntent
                ? store.t("取消待完成", "Cancellation pending")
                : store.t("试用中 / 到期待核实", "Trial / awaiting confirmation")
            ).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(store.t("查看订阅", "View")) { store.tab = 2 }
          }
        }
        Text(
          store.t(
            "这里的断供只记录状态，请先到平台取消。",
            "Cancellation here only records the status. Cancel on the platform first.")
        ).font(.caption).foregroundStyle(.secondary)
      }.card()
    }
    DisclosureGroup(store.t("限时活动 · \(visibleEvents.count)", "Events · \(visibleEvents.count)")) {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(store.t("限时活动", "Limited-time events"), systemImage: "flag").font(.headline)
        Spacer()
        Button(store.t("添加活动", "Add event")) { editingEvent = Event() }
      }
      if visibleEvents.isEmpty {
        Text(
          store.t(
            "游戏活动、平台任务、会员日……记下截止日，完成了来打个勾。截止前完成有 5 小鱼干。",
            "Game events, platform tasks, member days… note the deadline and check them off. On-time completion earns 5 fish.")
        ).foregroundStyle(.secondary).padding(.vertical, 12)
      } else {
        ForEach(visibleEvents) { event in
          EventRow(
            event: event,
            onEdit: { editingEvent = event },
            onDelete: { deletingEvent = event }
          )
        }
      }
    }.card()
    .sheet(item: $editingEvent) { EventEditor(event: $0).environmentObject(store) }
    .alert(
      store.t("删除这个活动？", "Delete this event?"),
      isPresented: Binding(
        get: { deletingEvent != nil },
        set: { if !$0 { deletingEvent = nil } })
    ) {
      Button(store.t("取消", "Cancel"), role: .cancel) {}
      Button(store.t("删除", "Delete"), role: .destructive) {
        if let event = deletingEvent { store.removeEvent(event) }
      }
    } message: {
      Text(store.t("只删除这条活动记录，不影响订阅。", "Only this event is removed."))
    }
    }
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(
          store.t("到期与逾期待核实", "Due & awaiting confirmation"),
          systemImage: "calendar.badge.exclamationmark"
        ).font(.headline)
        Spacer()
        Text("\(pending.count)").foregroundStyle(.secondary)
      }
      if pending.isEmpty {
        Text(store.t("没有待核实的账单，心里有数。", "No payments awaiting confirmation.")).foregroundStyle(
          .secondary
        ).padding(.vertical, 12)
      } else {
        ForEach(Array(pending.prefix(8))) { b in BillRow(bill: b, canConfirm: true) }
        if pending.count > 8 {
          Text(store.t("更多历史账期待办可在订阅详情中查看。", "More periods are available in subscription details."))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }.card()
    HStack(alignment: .top, spacing: 18) {
      VStack(alignment: .leading, spacing: 16) {
        Label(store.t("未来 7 天", "Next 7 days"), systemImage: "calendar").font(.headline)
        if upcoming.isEmpty {
          Text(store.t("近期没有新的扣款计划。", "No upcoming bills this week.")).foregroundStyle(.secondary)
            .padding(.vertical, 16)
        } else {
          ForEach(Array(upcoming.prefix(6))) { BillRow(bill: $0, canConfirm: false) }
        }
      }.card()
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label(store.t("今日待领权益", "Benefits to claim"), systemImage: "gift").font(.headline)
          Spacer()
          Button(store.t("管理权益", "Manage")) { store.tab = 1 }
            .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.teal)
        }
        if benefits.isEmpty {
          Text(store.t("今天的权益已经记下，或尚未配置权益。", "All recorded, or no benefits configured."))
            .foregroundStyle(.secondary).padding(.vertical, 16)
        } else {
          ForEach(benefits) { benefit in
            HStack {
              Tile(
                symbol: benefit.kind == .weekly ? "calendar.badge.clock" : "gift",
                color: Theme.teal)
              VStack(alignment: .leading) {
                Text(benefit.name).font(.callout.bold())
                Text(benefit.kind.title(store.en)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(store.t("标记已领取", "Mark claimed")) { store.claim(benefit) }.buttonStyle(.bordered)
                .tint(Theme.teal)
            }
          }
        }
        Text(store.t("记录领取，不代替平台实际领取。", "Recording does not claim on the platform.")).font(
          .caption2
        ).foregroundStyle(.secondary)
      }.card()
    }
    if store.state.preferences.game {
      HStack(spacing: 16) {
        Tile(symbol: "pawprint.fill", color: Theme.orange)
        VStack(alignment: .leading, spacing: 4) {
          Text(store.t("月供有人记，猫舍也在成长。", "Manage subscriptions and grow your cat’s home.")).font(.headline)
          Text(
            store.t(
              "本月任务、设施升级和免费喂食都在猫舍里；不用为养猫增加订阅。", "Monthly quests, facility upgrades and free feeding are in your cat’s home. No new subscription needed.")
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(store.t("去猫舍", "Visit your cat")) { store.tab = 4 }
      }.card()
    }
  }
}
struct BillRow: View {
  @EnvironmentObject var store: Store
  var bill: Bill
  var canConfirm: Bool
  var body: some View {
    HStack(spacing: 12) {
      let sub = store.state.subscriptions.first { $0.id == bill.subscriptionID }
      Tile(symbol: sub?.symbol ?? "creditcard", color: Theme.color(sub?.color ?? "blue"))
      VStack(alignment: .leading, spacing: 4) {
        Text(sub?.name ?? "—").font(.callout.bold())
        let rel = relativeDay(bill.date, store.state, store.en)
        Text(Engine.day(bill.date, store.state) + " · " + rel.text)
          .font(.caption).foregroundStyle(rel.overdue ? Theme.orange : .secondary)
      }
      Spacer()
      Text(money(bill.price, bill.currency)).font(.callout.bold())
      if canConfirm {
        Button(store.t("核实", "Confirm")) { store.paymentBill = bill }.buttonStyle(.bordered)
      }
    }
  }
}

struct EventEditor: View {
  @EnvironmentObject var store: Store
  @Environment(\.dismiss) var dismiss
  @State var event: Event
  @State var validation = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Heading(
        title: store.t("限时活动", "Limited-time event"),
        subtitle: store.t(
          "记下活动与截止日；在截止前完成可得 5 小鱼干。",
          "Track the event and its deadline. On-time completion earns 5 fish."))
      Form {
        TextField(store.t("活动名称", "Event name"), text: $event.name)
        DatePicker(
          store.t("截止日", "Deadline"), selection: $event.deadline, displayedComponents: .date)
        Picker(
          store.t("关联订阅（可选）", "Linked subscription (optional)"),
          selection: $event.subscriptionID
        ) {
          Text(store.t("不关联", "None")).tag(nil as UUID?)
          ForEach(store.state.subscriptions.filter { !$0.archived }) { sub in
            Text(sub.name).tag(sub.id as UUID?)
          }
        }
        TextField(store.t("备注", "Note"), text: $event.note)
      }
      if !validation.isEmpty { Text(validation).foregroundStyle(.red).font(.caption) }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(store.t("保存活动", "Save event")) {
          guard !event.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validation = store.t("请填写活动名称。", "Enter an event name.")
            return
          }
          store.error = nil
          store.saveEvent(event)
          if store.error == nil { dismiss() }
        }.buttonStyle(.borderedProminent).tint(Theme.teal).keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 480)
  }
}

struct EventRow: View {
  @EnvironmentObject var store: Store
  var event: Event
  var onEdit: () -> Void
  var onDelete: () -> Void
  var linkedName: String {
    event.subscriptionID.flatMap { id in
      store.state.subscriptions.first { $0.id == id }?.name
    } ?? ""
  }
  var body: some View {
    let done = event.doneAt != nil
    let rel = relativeDay(event.deadline, store.state, store.en)
    let overdue = rel.overdue && !done
    let subtitle =
      Engine.day(event.deadline, store.state) + " · " + rel.text
      + (linkedName.isEmpty ? "" : " · " + linkedName)
    HStack(spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "flag")
        .foregroundStyle(done ? Theme.teal : (overdue ? Theme.orange : Theme.blue))
      VStack(alignment: .leading, spacing: 4) {
        Text(event.name).font(.callout.bold()).strikethrough(done)
          .foregroundStyle(done ? .secondary : .primary)
        Text(subtitle).font(.caption)
          .foregroundStyle(overdue ? Theme.orange : .secondary)
      }
      Spacer()
      Button(done ? store.t("撤销完成", "Undo") : store.t("完成", "Done")) {
        store.toggleEvent(event)
      }.buttonStyle(.bordered).tint(done ? .secondary : Theme.teal)
      Button(action: onEdit) { Image(systemName: "pencil") }
        .buttonStyle(.plain).foregroundStyle(.secondary)
      Button(action: onDelete) { Image(systemName: "trash") }
        .buttonStyle(.plain).foregroundStyle(.secondary)
    }
  }
}
