import SwiftUI
import Foundation

public final class MonthlyBundleMarker: NSObject {}
enum MonthlyBundle {
    static let bundle = Bundle(for: MonthlyBundleMarker.self)
    static let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" ? "com.gaoseries.GaoYueGong.test.Monthly" : "com.gaoseries.GaoYueGong.Monthly") ?? .standard
}

@MainActor private enum MonthlyRuntime {
    static let store = Store()
}

public struct MonthlyModuleView: View {
    @ObservedObject private var store = MonthlyRuntime.store
    private let route: URL?
    private let routeRevision: Int
    @State private var handledRevision = 0
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route
        self.routeRevision = routeRevision
    }
    public var body: some View {
        RootView()
            .environmentObject(store)
            .environment(\.locale, Locale(identifier: store.en ? "en_US" : "zh_CN"))
            .onAppear(perform: handleRoute)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.monthly.game"))) { _ in store.tab = 4 }
            .onChange(of: routeRevision) { _, _ in handleRoute() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.monthly.new"))) { _ in store.editor = Subscription() }
            // 备份导出/恢复收拢到 app 级「数据」页：模块内入口已移除，能力经通知触发。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.monthly.export"))) { _ in store.backup() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.monthly.import"))) { _ in store.restore() }
    }
    private func handleRoute() {
        guard routeRevision > handledRevision, route?.scheme == "gaoyuegong" else { return }
        handledRevision = routeRevision
        store.tab = 0
    }
}

/// 搞月供设置页（app 级设置中心嵌入用）：内容与模块原「设置」侧栏页一致，
/// store 由 framework 内 singleton 注入，外部嵌入无需提供环境对象。
public struct MonthlySettingsView: View {
    @ObservedObject private var store = MonthlyRuntime.store
    public init() {}
    public var body: some View {
        SettingsView()
            .environmentObject(store)
            .environment(\.locale, Locale(identifier: store.en ? "en_US" : "zh_CN"))
    }
}

