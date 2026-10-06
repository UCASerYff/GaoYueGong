import SwiftUI

/// 权益模块（V0.5）：与订阅平级的独立打卡对象。
/// 权益可关联订阅（如月卡每日领取），也可独立存在（如游戏每日登录奖励）。
struct BenefitsView: View {
  @EnvironmentObject var store: Store
  @State var editing: BenefitItem?
  @State var deleting: BenefitItem?
  var due: [BenefitItem] { Engine.dueBenefits(store.state) }
  var items: [BenefitItem] {
    store.state.benefits.sorted { lhs, rhs in
      if lhs.archived != rhs.archived { return !lhs.archived }
      return lhs.createdAt < rhs.createdAt
    }
  }
  var body: some View {
    Heading(
      title: store.t("权益打卡", "Benefits"),
      subtitle: store.t(
        "每日的、每周的，领回来的才算数。",
        "Daily or weekly — only what you claim counts."))
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label(store.t("今日待领", "Due today"), systemImage: "gift").font(.headline)
        Spacer()
        Text("\(due.count)").foregroundStyle(.secondary)
      }
      if due.isEmpty {
        Text(store.t("今天的权益都记下了，或还没有到期的权益。", "All recorded, or nothing due today."))
          .foregroundStyle(.secondary).padding(.vertical, 12)
      } else {
        ForEach(due) { benefit in
          HStack(spacing: 12) {
            Tile(
              symbol: benefit.kind == .weekly ? "calendar.badge.clock" : "gift",
              color: Theme.teal)
            VStack(alignment: .leading, spacing: 4) {
              Text(benefit.name).font(.callout.bold())
              Text(
                benefit.kind.title(store.en)
                  + (linkedName(benefit).map { " · " + $0 } ?? "")
              ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.t("标记已领取", "Mark claimed")) { store.claim(benefit) }
              .buttonStyle(.bordered).tint(Theme.teal)
          }
        }
      }
      Text(store.t("记录领取，不代替平台实际领取。", "Recording does not claim on the platform."))
        .font(.caption2).foregroundStyle(.secondary)
    }.card()
    .sheet(item: $editing) { BenefitEditor(benefit: $0).environmentObject(store) }
    .alert(
      store.t("删除这条权益？", "Delete this benefit?"),
      isPresented: Binding(
        get: { deleting != nil },
        set: { if !$0 { deleting = nil } })
    ) {
      Button(store.t("取消", "Cancel"), role: .cancel) {}
      Button(store.t("删除", "Delete"), role: .destructive) {
        if let benefit = deleting { store.removeBenefit(benefit) }
      }
    } message: {
      Text(
        store.t(
          "权益与它的打卡记录一并移除，不影响关联的订阅。",
          "The benefit and its claim records are removed. Linked subscriptions are not affected."))
    }
    HStack {
      Label(store.t("全部权益", "All benefits"), systemImage: "list.bullet").font(.headline)
      Spacer()
      Button(store.t("添加权益", "Add benefit")) { editing = BenefitItem() }
    }
    if items.isEmpty {
      VStack {
        EmptyState(
          symbol: "gift",
          title: store.t("从第一条权益开始", "Start with your first benefit"),
          subtitle: store.t(
            "月卡每日领取、游戏登录奖励、会员每日签到……\n可以关联订阅，也可以独立记录。",
            "Monthly pass dailies, game login rewards, member check-ins…\nLink a subscription, or track it standalone."))
        Button(store.t("添加第一条权益", "Add your first benefit")) { editing = BenefitItem() }
          .buttonStyle(.borderedProminent).tint(Theme.teal).padding(.bottom, 20)
      }.card()
    } else {
      ForEach(items) { benefit in
        BenefitCard(benefit: benefit, onEdit: { editing = benefit }, onDelete: { deleting = benefit })
      }
    }
  }
  func linkedName(_ benefit: BenefitItem) -> String? {
    benefit.subscriptionID.flatMap { id in
      store.state.subscriptions.first { $0.id == id }?.name
    }
  }
}

struct BenefitCard: View {
  @EnvironmentObject var store: Store
  var benefit: BenefitItem
  var onEdit: () -> Void
  var onDelete: () -> Void
  @State var claimDate = Date()
  var linked: Subscription? {
    benefit.subscriptionID.flatMap { id in
      store.state.subscriptions.first { $0.id == id }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        Tile(
          symbol: benefit.kind == .weekly ? "calendar.badge.clock" : "gift",
          color: benefit.archived ? .gray : Theme.teal)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(benefit.name).font(.headline)
            if benefit.archived {
              Text(store.t("已归档", "Archived")).font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
            }
          }
          Text(
            benefit.kind.title(store.en)
              + (linked.map { " · " + store.t("关联：", "Linked: ") + $0.name }
                ?? " · " + store.t("独立权益", "Standalone"))
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { onEdit() } label: { Image(systemName: "pencil") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
        Button { onDelete() } label: { Image(systemName: "trash") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
      }
      if !benefit.note.isEmpty {
        Text(benefit.note).font(.caption).foregroundStyle(.secondary)
      }
      if !benefit.archived {
        HStack {
          DatePicker(
            store.t("补记权益", "Backfill benefit"), selection: $claimDate, in: ...Date(),
            displayedComponents: .date)
          Button(store.t("记为已领取", "Record claimed")) {
            store.claim(benefit, date: claimDate)
          }
        }
        let claims = store.state.claims.filter { $0.id.hasPrefix("\(benefit.id)|") }.sorted {
          $0.date > $1.date
        }
        if !claims.isEmpty {
          Text(
            store.t("累计记录 ", "Recorded ") + "\(claims.count)" + store.t(" 次", " times")
          ).font(.caption).foregroundStyle(.secondary)
        }
        ClaimCalendar(benefit: benefit)
        ForEach(Array(claims.prefix(6))) { claim in
          HStack {
            Text(Engine.day(claim.date, store.state))
            Text(claim.backfill ? store.t("补记", "Backfilled") : store.t("已领取", "Claimed"))
              .foregroundStyle(.secondary)
            Spacer()
            Button(store.t("撤销领取", "Undo claim")) {
              store.update { $0.claims.removeAll { $0.id == claim.id } }
            }
          }.font(.caption)
        }
      }
    }.card()
  }
}

struct BenefitEditor: View {
  @EnvironmentObject var store: Store
  @Environment(\.dismiss) var dismiss
  @State var benefit: BenefitItem
  @State var validation = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Heading(
        title: store.t("权益打卡", "Benefit"),
        subtitle: store.t(
          "记下要定期领取的权益；当天打卡即喂饭，还有小鱼干。",
          "Track a recurring benefit. Same-day check-in feeds your pet and earns fish."))
      Form {
        TextField(store.t("权益名称", "Benefit name"), text: $benefit.name)
        Picker(store.t("领取频率", "Frequency"), selection: $benefit.kind) {
          Text(Benefit.daily.title(store.en)).tag(Benefit.daily)
          Text(Benefit.weekly.title(store.en)).tag(Benefit.weekly)
        }
        Picker(
          store.t("关联订阅（可选）", "Linked subscription (optional)"),
          selection: $benefit.subscriptionID
        ) {
          Text(store.t("不关联（独立权益）", "None (standalone)")).tag(nil as UUID?)
          ForEach(store.state.subscriptions.filter { !$0.archived }) { sub in
            Text(sub.name).tag(sub.id as UUID?)
          }
        }
        TextField(store.t("备注", "Note"), text: $benefit.note)
        Toggle(store.t("归档（暂停打卡）", "Archive (pause check-ins)"), isOn: $benefit.archived)
      }
      if !validation.isEmpty { Text(validation).foregroundStyle(.red).font(.caption) }
      HStack {
        Button(store.t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(store.t("保存权益", "Save benefit")) {
          guard !benefit.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validation = store.t("请填写权益名称。", "Enter a benefit name.")
            return
          }
          store.error = nil
          store.saveBenefit(benefit)
          if store.error == nil { dismiss() }
        }.buttonStyle(.borderedProminent).tint(Theme.teal).keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 480)
  }
}

/// 权益领取月度热力图：已领（青）、错过（灰框）、未来（淡灰）、今天（描边）。
struct ClaimCalendar: View {
  @EnvironmentObject var store: Store
  var benefit: BenefitItem
  @State var offset = 0
  var body: some View {
    let c = Engine.calendar(store.state)
    let monthStart = c.dateInterval(
      of: .month, for: c.date(byAdding: .month, value: offset, to: Date())!)!.start
    let daysInMonth = c.range(of: .day, in: .month, for: monthStart)!.count
    let lead = (c.component(.weekday, from: monthStart) - c.firstWeekday + 7) % 7
    let today = c.startOfDay(for: Date())
    let days = (1...daysInMonth).map { c.date(byAdding: .day, value: $0 - 1, to: monthStart)! }
    let opportunities = days.filter { Engine.claimKey(benefit, store.state, on: $0) != nil }
    let claimed = opportunities.filter { d in
      Engine.claimKey(benefit, store.state, on: d).map { k in
        store.state.claims.contains { $0.id == k }
      } ?? false
    }
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button { offset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
        Text(Engine.month(monthStart, store.state)).font(.callout.bold())
        Button { offset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
          .disabled(offset >= 0)
        Spacer()
        Text(
          store.t("已领 ", "Claimed ") + "\(claimed.count)/\(opportunities.count)"
        ).font(.caption).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
        ForEach(
          store.en
            ? ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] : ["一", "二", "三", "四", "五", "六", "日"],
          id: \.self
        ) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 24) }
        ForEach(days, id: \.self) { date in
          let key = Engine.claimKey(benefit, store.state, on: date)
          let did = key.map { k in store.state.claims.contains { $0.id == k } } ?? false
          let future = c.startOfDay(for: date) > today
          let isToday = c.startOfDay(for: date) == today
          let missed = !did && !future && key != nil
          let textColor: Color = did ? .white : future ? .secondary.opacity(0.4) : .secondary
          let fillColor: Color =
            did ? Theme.teal : future ? .secondary.opacity(0.06) : .clear
          let strokeColor: Color =
            isToday ? Theme.teal : missed ? .secondary.opacity(0.35) : .clear
          Text("\(c.component(.day, from: date))").font(.caption2)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .foregroundStyle(textColor)
            .background(RoundedRectangle(cornerRadius: 6).fill(fillColor))
            .overlay(
              RoundedRectangle(cornerRadius: 6).stroke(strokeColor, lineWidth: isToday ? 1.5 : 1)
            )
            .accessibilityLabel(
              Engine.day(date, store.state)
                + (did ? store.t(" 已领取", " claimed") : store.t(" 未领取", " not claimed")))
        }
      }
    }
  }
}
