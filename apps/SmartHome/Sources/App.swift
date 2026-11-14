import SwiftUI

@main
struct SmartHomeApp: App {
    @StateObject private var store = DeviceStore.shared
    @AppStorage("appearance") private var appearance = "dark"

    init() { LowNet.raiseFileLimit() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Theme.gold)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "system" ? nil : .dark)
        }
    }
}

enum AppTab: Hashable { case devices, discover, tools, settings }

struct RootView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var tab: AppTab = .devices
    @StateObject private var updater = Updater(bundleId: "com.mrlttec.smarthome")
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            Tab("Devices", systemImage: "house.fill", value: AppTab.devices) {
                DevicesView(tab: $tab)
            }
            Tab("Discover", systemImage: "dot.radiowaves.left.and.right", value: AppTab.discover) {
                DiscoverView()
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver.fill", value: AppTab.tools) {
                ToolsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environmentObject(updater)
        .task { await updater.check() }
        .onChange(of: tab) { _, _ in Haptic.tap() }
        .onChange(of: phase) { _, p in if p == .active { store.refreshNetwork(); Task { await updater.check() } } }
    }
}
