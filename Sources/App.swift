import AppKit
import SwiftUI

// 独立 App 入口（MonthlyApp 与 AppDelegate）已随整合版移除；
// 模块视图由 Monthly/Module.swift 的 MonthlyModuleView 承载。
struct RootView: View {
  @EnvironmentObject var store: Store
  @Environment(\.colorScheme) var scheme
  @Environment(\.scenePhase) var phase
  /// 侧栏隐藏/显示（场景级记忆；键全 app 唯一）。只有 隐藏↔显示 两态，无「收起成图标栏」。
  @SceneStorage("gqns.sidebarHidden.monthly") private var sidebarHidden = false
  /// 自绘侧栏导航行的 hover 跟踪（浅灰反馈，与词元一致）。
  @State private var hoveredTab: Int?
  var body: some View {
    // 侧栏重设计（对齐词元 2.2/2.3 标杆）：弃用系统 NavigationSplitView 列表侧栏，
    // 改 HStack 自绘——品牌头部 + 浮动卡片选中态导航行 + hover 反馈 + 状态底卡。
    // 统一工具栏契约：.navigation 恰好一个 28×28 侧栏切换按钮（⌃⌘S）；
    // 原有 trailing「添加订阅」按钮保留，包在固定宽 360 的右对齐容器里。
    HStack(spacing: 0) {
      if !sidebarHidden {
        sidebar
        // 自绘发丝线替代系统 Divider：避免 Tahoe 统一标题栏下系统 separator 冷启动首帧误渲染成灰带
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
      }
      VStack(spacing: 0) {
        if let fatal = store.fatal {
          EmptyState(
            symbol: "externaldrive.badge.exclamationmark",
            title: store.t("数据暂不可用", "Data unavailable"), subtitle: fatal)
          Button(store.t("重试", "Retry")) { store.reload() }
          Button(store.t("从备份恢复", "Restore backup")) { store.restore() }
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
              switch store.tab {
              case 0: TodayView()
              case 1: BenefitsView()
              case 2: SubscriptionsView()
              case 3: StatisticsView()
              case 4: PetView()
              default: SettingsView()
              }
            }.padding(28).frame(maxWidth: 1280).frame(maxWidth: .infinity)
          }.id(store.tab)
        }
        if let message = store.notice {
          HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
            Text(message).font(.caption)
            Spacer()
            Button {
              store.notice = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain)
          }.padding(12).background(Theme.teal.opacity(0.08))
        }
      }.background(Theme.background(scheme == .dark, store.state.preferences.backgroundHex))
    }
    .frame(minWidth: 1040, minHeight: 720)
    .animation(.easeInOut(duration: 0.22), value: sidebarHidden)
    .toolbar {
      toolbarItemNoChrome(.navigation) {
        Button {
          withAnimation(.easeInOut(duration: 0.22)) { sidebarHidden.toggle() }
        } label: {
          SidebarToggleIcon()
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(store.t(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏", sidebarHidden ? "Show Sidebar" : "Hide Sidebar"))
      }
      toolbarItemNoChrome(.primaryAction) {
        HStack(spacing: 12) {
          Button {
            store.editor = Subscription()
          } label: {
            Label(store.t("添加订阅", "Add subscription"), systemImage: "plus")
          }
        }
        .frame(width: 360, alignment: .trailing)
      }
    }
    .sheet(item: $store.editor) { SubscriptionEditor(subscription: $0).environmentObject(store) }
    .sheet(item: $store.paymentBill) { PaymentEditor(bill: $0).environmentObject(store) }
    .sheet(
      isPresented: Binding(
        get: { !store.state.preferences.onboarded && store.fatal == nil }, set: { _ in })
    ) { WelcomeView().environmentObject(store) }
    .alert(
      store.t("操作未完成", "Action failed"),
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button(store.t("好", "OK")) { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
    .onChange(of: phase) { _, phase in if phase == .active { store.reload() } }
  }

  // MARK: 自绘侧边栏（词元标杆）：品牌头部 + 浮动卡片选中态导航行 + 状态底卡

  private var sidebar: some View {
    VStack(spacing: 0) {
      brandHeader
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          sidebarSection(store.t("月供管理", "Subscriptions")) {
            sidebarRow(0, title: store.t("今日概览", "Today"), symbol: "sun.max")
            sidebarRow(1, title: store.t("权益打卡", "Benefits"), symbol: "gift")
            sidebarRow(2, title: store.t("我的订阅", "My subscriptions"), symbol: "rectangle.stack")
            sidebarRow(3, title: store.t("统计与审视", "Statistics"), symbol: "chart.bar.xaxis")
          }
          if store.state.preferences.game {
            sidebarSection(store.t("陪伴", "Companion")) {
              sidebarRow(4, title: store.t("猫舍冒险", "Cat home"), symbol: "pawprint")
            }
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      statusFooter
    }
    .frame(width: 236)
    .frame(maxHeight: .infinity)
    .background(.regularMaterial)
  }
  private var brandHeader: some View {
    HStack(spacing: 10) {
      if let image = NSImage(
        contentsOf: MonthlyBundle.bundle.url(forResource: "GaoYueGongIcon", withExtension: "png")
          ?? URL(fileURLWithPath: ""))
      {
        Image(nsImage: image).resizable()
          .interpolation(.high)
          .frame(width: 38, height: 38)
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(store.t("搞月供", "Gao Monthly")).font(.headline)
        Text(store.t("把月供看明白，把日子过轻松", "Every subscription, clearly in sight"))
          .font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity)
  }
  @ViewBuilder private func sidebarSection<Rows: View>(
    _ title: String, @ViewBuilder rows: () -> Rows
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
      rows()
    }
  }
  /// 浮动卡片选中态导航行：accent 底白字 + 柔和投影（深色下投影 opacity 调高），hover 浅灰反馈。
  private func sidebarRow(_ tab: Int, title: String, symbol: String) -> some View {
    let selected = store.tab == tab
    let hovered = hoveredTab == tab
    return Button { store.tab = tab } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.callout)
          .frame(width: 20)
        Text(title)
          .font(.callout.weight(selected ? .semibold : .regular))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 32)
      .foregroundStyle(selected ? Color.white : Color.primary)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Theme.teal)
            .shadow(color: Theme.teal.opacity(scheme == .dark ? 0.45 : 0.32), radius: 5, y: 2)
        } else if hovered {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.06))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering in hoveredTab = hovering ? tab : nil }
  }
  /// 状态底卡（词元 statusFooter 风格）：订阅计数 + 宠物状态（陪伴模式）/存储说明。
  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Circle().fill(Theme.teal).frame(width: 7, height: 7)
        Text(store.t("\(store.state.subscriptions.count) 个订阅", "\(store.state.subscriptions.count) subscriptions"))
          .font(.caption)
        Spacer(minLength: 0)
      }
      if store.state.preferences.game {
        Text("\(Image(systemName: "fish.fill")) \(store.state.pet.fish) · Lv.\(store.state.pet.level)")
          .font(.system(size: 10)).foregroundStyle(.tertiary)
      } else {
        Text(store.t("本机保存 · 无需登录", "On this Mac · No account"))
          .font(.system(size: 10)).foregroundStyle(.tertiary)
      }
    }
    .padding(12)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }
}
struct WelcomeView: View {
  @EnvironmentObject var store: Store
  @State var game = true
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Tile(symbol: "calendar.badge.clock")
      Text("把月供看明白，\n把日子过轻松。").font(.system(size: 32, weight: .semibold))
      Text("记住每个订阅的扣款日，领回已经买下的权益。\n数据只保存在这台 Mac，不需要注册。").foregroundStyle(.secondary)
      Toggle("养一只猫，陪我管订阅", isOn: $game)
      Text("也可使用纯记录模式，随时在设置中切换。").font(.caption).foregroundStyle(.secondary)
      Divider()
      Text("结算时区：\(store.state.preferences.timezone)").font(.callout)
      Text("本应用不能代替你取消平台续费。断供前请到平台确认。").font(.caption).foregroundStyle(.secondary)
      Button("开始使用") {
        store.update {
          $0.preferences.game = game
          $0.preferences.onboarded = true
        }
      }.buttonStyle(.borderedProminent).tint(Theme.teal).controlSize(.large)
    }.padding(36).frame(width: 470).interactiveDismissDisabled()
  }
}

// MARK: - 工具栏项 chrome 隐藏（macOS 26 起工具栏项带 sharedBackground 玻璃胶囊，
// 自绘的侧栏切换按钮与固定宽 360 trailing 容器会被罩上多余色块；只去底色，不改几何与交互）
@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content)
            .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

/// 侧栏切换按钮图标：chrome 隐藏后补轻量 hover 底色，保证图标清晰、反馈合理。
private struct SidebarToggleIcon: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "sidebar.left")
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(hovering ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
