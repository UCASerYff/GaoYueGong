import AppKit
import SwiftUI

struct SubscriptionsView: View {
  @EnvironmentObject var store: Store
  @State var search = ""
  @State var filter = 0
  @State var selected: UUID?
  var items: [Subscription] {
    store.state.subscriptions.filter {
      (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        || $0.category.contains(search))
        && (filter == 2 ? $0.archived : !$0.archived && (filter == 0 || !$0.renewing))
    }.sorted { lhs, rhs in
      // 按下次扣款日排序：越快扣款越靠前；已断供/无未来账单的沉底，再按建档先后。
      let l = Engine.next(lhs, store.state)?.date
      let r = Engine.next(rhs, store.state)?.date
      if let l, let r { return l != r ? l < r : lhs.current.anchor < rhs.current.anchor }
      if (l == nil) != (r == nil) { return l != nil }
      return lhs.current.anchor < rhs.current.anchor
    }
  }
  var body: some View {
    Heading(
      title: store.t("我的订阅", "My subscriptions"),
      subtitle: store.t("每份月供有来处，每次续费有选择。", "Know what you pay for. Choose what to keep."))
    HStack {
      TextField(store.t("搜索名称或分类", "Search name or category"), text: $search).textFieldStyle(
        .roundedBorder)
      Picker("", selection: $filter) {
        Text(store.t("全部", "All")).tag(0)
        Text(store.t("已断供", "Cancelled")).tag(1)
        Text(store.t("已归档", "Archived")).tag(2)
      }.pickerStyle(.segmented).frame(width: 290)
    }
    if items.isEmpty {
      EmptyState(
        symbol: "rectangle.stack", title: store.t("这里还没有订阅", "No subscriptions here"),
        subtitle: store.t("点击右上角添加，或换一个筛选条件。", "Add a subscription or change your filter.")
      ).card()
    } else {
      ForEach(items) { sub in
        VStack(alignment: .leading, spacing: 0) {
          Button {
            selected = selected == sub.id ? nil : sub.id
          } label: {
            HStack(spacing: 14) {
              Tile(symbol: sub.symbol, color: Theme.color(sub.color))
              VStack(alignment: .leading, spacing: 5) {
                Text(sub.name).font(.headline)
                Text(sub.category + " · " + sub.current.cycle.title(store.en) + " · " + status(sub))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 5) {
                Text(money(sub.current.price, sub.current.currency)).font(.title3.bold())
                let rel = Engine.next(sub, store.state).map {
                  relativeDay($0.date, store.state, store.en)
                }
                Text(
                  Engine.rating(sub, store.state).label
                    + (rel.map { " · " + $0.text } ?? "")
                ).font(.caption).foregroundStyle(rel?.overdue == true ? Theme.orange : .secondary)
              }
              Image(systemName: selected == sub.id ? "chevron.up" : "chevron.down").foregroundStyle(
                .tertiary)
            }
          }.buttonStyle(.plain)
          if selected == sub.id {
            Divider().padding(.vertical, 18)
            SubscriptionDetail(sub: sub)
          }
        }.card()
      }
    }
  }
  func status(_ sub: Subscription) -> String {
    let base =
      if !sub.renewing { store.t("已关闭续费", "Renewal off") }
      else if sub.cancelIntent { store.t("取消待处理", "Cancellation pending") }
      else if sub.trialEnd != nil && !sub.trialResolved { store.t("试用待核实", "Trial") }
      else { sub.autoRenew ? store.t("自动续费", "Auto-renew") : store.t("手动续费", "Manual renewal") }
    if sub.isStacking, let days = Engine.remainingDays(sub, store.state) {
      return base + " · "
        + (days >= 0
          ? store.t("剩余 ", "") + "\(days)" + store.t(" 天", " days left")
          : store.t("已到期", "Expired"))
    }
    return base
  }
}
struct SubscriptionDetail: View {
  @EnvironmentObject var store: Store
  var sub: Subscription
  @State var showCancel = false
  @State var delete = false
  @State var endKnown = true
  @State var serviceEnd = Date()
  @State var reviewDate = Date()
  @State var historyStart = Date()
  @State var renewPeriods = 1
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          if let b = Engine.next(sub, store.state) {
            Text(store.t("下次计划：", "Next bill: ") + Engine.day(b.date, store.state))
          }
          if let end = sub.serviceEnd {
            Text(store.t("权益有效至：", "Service until: ") + Engine.day(end, store.state))
          }
          if let trial = sub.trialEnd, !sub.trialResolved {
            Text(store.t("试用截止：", "Trial ends: ") + Engine.day(trial, store.state)).foregroundStyle(
              Theme.orange)
          }
          if !sub.note.isEmpty { Text(sub.note).foregroundStyle(.secondary) }
        }.font(.callout)
        Spacer()
        Button(store.t("编辑", "Edit")) { store.editor = sub }
        if let url = URL(string: sub.link), ["https", "http"].contains(url.scheme ?? "") {
          Button(store.t("前往平台", "Open platform")) { NSWorkspace.shared.open(url) }
        }
      }
      HStack {
        if sub.renewing {
          Button(store.t("继续供 / 已审视", "Keep / reviewed")) {
            store.update { try Engine.review(&$0, subID: sub.id, cancel: false) }
          }
          Button(store.t("打算取消", "Plan to cancel")) {
            store.update { try Engine.review(&$0, subID: sub.id, cancel: true) }
          }
          Button(store.t("已在平台关闭续费", "I cancelled on the platform")) { showCancel = true }
        } else {
          Button(store.t("复供", "Resume")) {
            var draft = sub
            draft.cancelledAt = nil
            draft.cancelIntent = false
            draft.serviceEnd = nil
            draft.plans[draft.plans.count - 1].billingStop = nil
            draft.plans[draft.plans.count - 1].start = Date()
            draft.plans[draft.plans.count - 1].anchor = Date()
            store.editor = draft
          }
        }
        if sub.trialEnd != nil && !sub.trialResolved {
          Button(store.t("确认转正式", "Confirm paid plan")) {
            store.update { s in
              if let i = s.subscriptions.firstIndex(where: { $0.id == sub.id }) {
                if sub.trialEnd! >= Date() { Engine.trialReward(&s, subID: sub.id, now: Date()) }
                s.subscriptions[i].trialResolved = true
              }
            }
          }
        }
      }.controlSize(.small)
      Text(
        store.t(
          "断供只记录状态，请先到平台取消自动续费。", "This app records cancellation; it does not cancel for you.")
      ).font(.caption).foregroundStyle(.secondary)
      if sub.isStacking {
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Label(store.t("月卡模式", "Monthly pass"), systemImage: "hourglass").font(.callout.bold())
            Spacer()
            if let days = Engine.remainingDays(sub, store.state) {
              if days < 0 {
                Text(store.t("已到期 ", "Expired ") + "\(-days)" + store.t(" 天", " days ago"))
                  .font(.callout.bold()).foregroundStyle(.red)
              } else {
                Text(store.t("剩余 ", "") + "\(days)" + store.t(" 天", " days left"))
                  .font(.callout.bold())
                  .foregroundStyle(days <= 3 ? Theme.orange : Theme.teal)
              }
            } else {
              Text(store.t("已断供", "Cancelled")).font(.callout).foregroundStyle(.secondary)
            }
          }
          if sub.renewing {
            HStack {
              Stepper(
                store.t("提前续费 ", "Renew ") + "\(renewPeriods)"
                  + store.t(" 期", renewPeriods > 1 ? " periods" : " period"),
                value: $renewPeriods, in: 1...12)
              Spacer()
              Text(money(sub.current.price * Decimal(renewPeriods), sub.current.currency))
                .font(.callout.bold())
              Button(store.t("确认续费", "Renew")) {
                store.renew(
                  sub, periods: renewPeriods,
                  amount: sub.current.price * Decimal(renewPeriods))
              }.buttonStyle(.borderedProminent).tint(Theme.teal)
            }
            Text(
              store.t(
                "剩余天数直接累加，金额按单价乘期数预填，可在账期流水中修改。",
                "Days stack on top of the remainder. Amount prefilled as price × periods; editable in payment history.")
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Divider()
      let linkedBenefits = store.state.benefits.filter { $0.subscriptionID == sub.id }
      if !linkedBenefits.isEmpty {
        HStack(spacing: 10) {
          ForEach(linkedBenefits) { benefit in
            Label(
              benefit.name + " · " + benefit.kind.title(store.en)
                + (benefit.archived ? store.t("（已归档）", " (archived)") : ""),
              systemImage: "gift"
            ).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button(store.t("权益打卡已移到「权益」模块", "Check-ins moved to Benefits")) {
            store.tab = 1
          }.font(.caption)
        }
      } else {
        HStack {
          DatePicker(
            store.t("自评月份", "Review month"), selection: $reviewDate, in: ...Date(),
            displayedComponents: .date)
          Picker(
            store.t("使用频率", "Usage"),
            selection: Binding(
              get: {
                store.state.reviews.first {
                  $0.subscriptionID == sub.id && $0.month == Engine.month(reviewDate, store.state)
                }?.rating ?? -1
              },
              set: { value in
                store.update { s in
                  let key = "\(sub.id)|\(Engine.month(reviewDate,s))"
                  s.reviews.removeAll { $0.id == key }
                  if value >= 0 {
                    s.reviews.append(
                      Review(
                        id: key, subscriptionID: sub.id, month: Engine.month(reviewDate, s),
                        rating: value))
                  }
                }
              })
          ) {
            Text(store.t("未评估", "Not reviewed")).tag(-1)
            Text(store.t("经常用", "Often")).tag(2)
            Text(store.t("偶尔用", "Sometimes")).tag(1)
            Text(store.t("没用", "Unused")).tag(0)
          }
        }
      }
      Divider()
      Text(store.t("账期与流水", "Periods & payments")).font(.headline)
      HStack {
        DatePicker(
          store.t("历史起点", "History from"), selection: $historyStart, in: ...Date(),
          displayedComponents: .date)
        Spacer()
      }
      let bills = Engine.bills(sub, state: store.state, from: historyStart, through: Date())
      if bills.isEmpty {
        Text(store.t("此区间没有到期账单。", "No due bills in this range.")).foregroundStyle(.secondary)
      }
      ForEach(Array(bills.reversed().prefix(120))) { b in
        HStack {
          Text(Engine.day(b.date, store.state))
          Spacer()
          if let p = store.state.payments.first(where: { $0.id == b.id }) {
            Text(
              (p.skipped ? store.t("本期未扣", "Not charged") : money(p.amount, p.currency))
                + (p.coveredPeriods > 1
                  ? " · " + store.t("覆盖 ", "covers ") + "\(p.coveredPeriods)"
                    + store.t(" 期", " periods") : ""))
            Button(store.t("编辑", "Edit")) { store.paymentBill = b }
            Button(store.t("撤销确认", "Undo")) {
              store.update { $0.payments.removeAll { $0.id == b.id } }
            }
          } else if sub.isStacking && Engine.covered(b, store.state) {
            Text(store.t("已覆盖 · 提前续费", "Covered · renewed early")).foregroundStyle(Theme.teal)
          } else {
            Text(money(b.price, b.currency)).foregroundStyle(.secondary)
            Button(store.t("核实本期", "Confirm")) { store.paymentBill = b }
          }
        }.font(.callout)
      }
      HStack {
        Button(sub.archived ? store.t("取消归档", "Unarchive") : store.t("归档", "Archive")) {
          store.update { s in
            if let i = s.subscriptions.firstIndex(where: { $0.id == sub.id }) {
              s.subscriptions[i].archived.toggle()
            }
          }
        }
        Spacer()
        Button(store.t("永久删除", "Delete permanently"), role: .destructive) { delete = true }
      }
    }.onAppear {
      historyStart = Engine.calendar(store.state).date(byAdding: .month, value: -12, to: Date())!
    }
    .alert(store.t("永久删除这条订阅？", "Delete this subscription?"), isPresented: $delete) {
      Button(store.t("取消", "Cancel"), role: .cancel) {}
      Button(store.t("删除", "Delete"), role: .destructive) { store.remove(sub) }
    } message: {
      Text(
        store.t(
          "相关流水与自评一并移除，统计会随之改变。关联权益转为独立权益，保留其打卡记录。",
          "Payments and reviews will be removed, affecting statistics. Linked benefits become standalone and keep their claim history."))
    }
    .sheet(isPresented: $showCancel) {
      VStack(alignment: .leading, spacing: 20) {
        Heading(
          title: store.t("记录平台取消结果", "Record platform cancellation"),
          subtitle: store.t("请确认已在平台完成关闭续费。", "Confirm you turned off renewal on the platform."))
        Toggle(store.t("已知剩余权益到期日", "I know the service end date"), isOn: $endKnown)
        if endKnown {
          DatePicker(
            store.t("权益到期日", "Service ends"), selection: $serviceEnd, displayedComponents: .date)
        }
        HStack {
          Button(store.t("返回", "Back")) { showCancel = false }
          Spacer()
          Button(store.t("确认已取消", "Confirm cancelled")) {
            store.update { Engine.cancel(&$0, subID: sub.id, end: endKnown ? serviceEnd : nil) }
            showCancel = false
          }.buttonStyle(.borderedProminent)
        }
      }.padding(28).frame(width: 480)
    }
  }
}
