import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var store: Store
  @State var reset = false
  @State var erase = false
  func binding<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
    Binding(
      get: { store.state.preferences[keyPath: key] },
      set: { v in
        store.update { s in
          if key == \Preferences.game { s.pet.settledAt = Date() }
          s.preferences[keyPath: key] = v
        }
        if !store.state.preferences.game && store.tab == 3 { store.tab = 0 }
      })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Heading(
        title: store.t("设置", "Settings"),
        subtitle: store.t("轻一点的工具，清楚一点的生活。", "A lighter tool. A clearer picture."))
      VStack(alignment: .leading, spacing: 18) {
        Label(store.t("外观与体验", "Appearance & experience"), systemImage: "paintpalette").font(
          .headline)
        TextField(
          store.t("背景混色（如 #E6F2EB，留空默认）", "Background tint (#E6F2EB, empty for default)"),
          text: binding(\.backgroundHex)
        ).textFieldStyle(.roundedBorder)
        Toggle(store.t("启用宠物陪伴", "Enable pet companion"), isOn: binding(\.game))
        Text(
          store.t(
            "关闭后保留账目，冻结宠物状态，不补发期间奖励。", "Off freezes your pet while keeping all financial features.")
        ).font(.caption).foregroundStyle(.secondary)
      }.card()
      VStack(alignment: .leading, spacing: 18) {
        Label(store.t("提醒与隐私", "Reminders & privacy"), systemImage: "bell").font(.headline)
        HStack {
          Text(store.notificationStatus)
          Spacer()
          Button(store.t("申请通知权限", "Enable notifications")) { store.enableNotifications() }
        }
        Toggle(store.t("安排续费提醒", "Schedule renewal reminders"), isOn: binding(\.notifications))
        Stepper(
          store.t("默认提前天数：", "Default days before: ") + "\(store.state.preferences.reminderDays)",
          value: binding(\.reminderDays), in: 0...30)
        Stepper(
          store.t("提醒时间：", "Reminder hour: ") + "\(store.state.preferences.reminderHour):00",
          value: binding(\.reminderHour), in: 0...23)
        Toggle(
          store.t("通知与组件隐藏名称及金额", "Hide names and amounts in notifications & widgets"),
          isOn: binding(\.privacy))
        Text(store.coverage).font(.caption).foregroundStyle(.secondary)
        Text(store.t("结算时区：", "Settlement timezone: ") + store.state.preferences.timezone).font(
          .caption
        ).foregroundStyle(.secondary)
      }.card()
      VStack(alignment: .leading, spacing: 18) {
        Label(store.t("数据由你保管", "Your data, in your hands"), systemImage: "externaldrive").font(
          .headline)
        HStack {
          Button(store.t("完整备份", "Full backup")) { store.backup() }
          Button(store.t("恢复备份", "Restore backup")) { store.restore() }
          Menu(store.t("导出 CSV", "Export CSV")) {
            Button(store.t("订阅清单", "Subscriptions")) { store.export(0) }
            Button(store.t("扣款流水", "Payments")) { store.export(1) }
            Button(store.t("权益领取", "Claims")) { store.export(2) }
          }
          Spacer()
          Button(store.t("打开数据文件夹", "Open data folder")) {
            if let url = try? Database.location() { NSWorkspace.shared.open(url) }
          }
        }
        Text(
          store.t(
            "自动快照保留最近 7 个日期。导出文件未额外加密，请自行保管。",
            "Daily snapshots retain 7 dates. Exported files are not additionally encrypted.")
        ).font(.caption).foregroundStyle(.secondary)
        Divider()
        HStack {
          Button(store.t("重置宠物", "Reset pet"), role: .destructive) { reset = true }
          Spacer()
          Button(store.t("删除全部数据", "Erase all data"), role: .destructive) { erase = true }
        }
      }.card()
      VStack(alignment: .leading, spacing: 10) {
        Text("搞月供 V\(AppInfo.version)").font(.headline)
        Text(store.t("订阅管理与一只陪你管账的猫。", "Subscriptions and a cat to keep you company."))
          .foregroundStyle(.secondary)
        Text(
          store.t(
            "原生 macOS · 本机存储 · 无广告 · 无账号", "Native macOS · Local storage · No ads · No account")
        ).font(.caption).foregroundStyle(.secondary)
        Text(
          store.t(
            "按原币种统计，不提供实时价格、汇率、退款冲销或代取消服务。",
            "Original currencies only. No live prices, exchange rates, refund offsets or cancellation service."
          )
        ).font(.caption).foregroundStyle(.secondary)
      }.card()
    }.alert(store.t("重置宠物？", "Reset your pet?"), isPresented: $reset) {
      Button(store.t("取消", "Cancel"), role: .cancel) {}
      Button(store.t("重置", "Reset"), role: .destructive) { store.update { $0.pet = Pet() } }
    } message: {
      Text(
        store.t(
          "宠物成长、物品和余额将清空；真实账目保留，不补发历史奖励。",
          "Resets pet assets and growth. Financial records and reward deduplication remain."))
    }
    .alert(store.t("删除全部数据？", "Erase all data?"), isPresented: $erase) {
      Button(store.t("取消", "Cancel"), role: .cancel) {}
      Button(store.t("永久删除", "Erase permanently"), role: .destructive) { store.erase() }
    } message: {
      Text(
        store.t(
          "将删除所有订阅、流水、宠物和自动快照，并撤销提醒。自行导出的文件保留。此操作不可撤销。",
          "Deletes subscriptions, payments, pet and automatic snapshots, and cancels reminders. External exports remain. Cannot be undone."
        ))
    }
  }
}
