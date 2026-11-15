import SwiftUI

@main
struct HomeControlApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Tan.brown)
                .preferredColorScheme(.light)
        }
    }
}

enum MainTab: Hashable { case home, tv, music, settings }

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater(bundleId: "com.mrlttec.homecontrol")
    @State private var tab: MainTab = .home
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack(alignment: .top) {
            Tan.bg.ignoresSafeArea()
            if model.connected == true {
                VStack(spacing: 0) {
                    Group {
                        switch tab {
                        case .home: HomeView()
                        case .tv: RemoteView()
                        case .music: MusicView(inSheet: false)
                        case .settings: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    TanTabBar(tab: $tab)
                }
                .transition(.opacity)
            } else {
                ConnectView().transition(.opacity)
            }
            ToastView()
        }
        .environmentObject(model)
        .environmentObject(updater)
        .sheet(isPresented: $model.showMusic) {
            MusicView(inSheet: true)
                .environmentObject(model)
                .presentationDragIndicator(.visible)
                .presentationBackground(Tan.bg)
        }
        .task { await model.run() }
        .task { await updater.check() }
        .onChange(of: phase) { _, p in
            if p == .active {
                Task { await model.connect() }
                Task { await updater.check() }
            }
        }
    }
}

/// The tab bar from the mockup: Home, TV, Music, Settings.
struct TanTabBar: View {
    @Binding var tab: MainTab
    private let items: [(MainTab, String, String)] = [
        (.home, "house", "Home"), (.tv, "tv", "TV"), (.music, "music.note", "Music"), (.settings, "gearshape", "Settings"),
    ]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { i in
                let it = items[i]
                Button {
                    if tab != it.0 { Haptic.tap() }
                    tab = it.0
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: it.1).font(.system(size: 22))
                        Text(it.2).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tab == it.0 ? Tan.brown : Tan.faint)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Tan.bar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Tan.line).frame(height: 0.5) }
    }
}

/// Shown until the app can reach the MrLTTec server, which only happens through Tailscale.
struct ConnectView: View {
    @EnvironmentObject var m: AppModel
    @AppStorage("serverHost") private var serverHost = ""
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Tan.dark)
                RainbowFan().frame(width: 62, height: 62)
            }
            .frame(width: 96, height: 96)
            Text("Connect to Tailscale")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Tan.text)
            Text(m.connected == nil
                 ? "Connecting to the MrLTTec server..."
                 : "Turn on Tailscale on this iPhone. MrLTTec Control only works through Tailscale, and it connects by itself as soon as Tailscale is on.")
                .font(.system(size: 15))
                .foregroundStyle(Tan.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if m.connected == nil {
                ProgressView().tint(Tan.brown)
            } else {
                Button {
                    Haptic.tap()
                    m.connected = nil
                    Task { await m.connect() }
                } label: {
                    Text("Try again")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tan.card)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 13)
                        .background(Tan.brown, in: Capsule())
                }
                .buttonStyle(.plain)
                if let u = URL(string: "https://tailscale.com/download/ios") {
                    Link("Get Tailscale", destination: u)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Tan.brown)
                }
            }
            Spacer()
            if m.connected == false && !m.lastError.isEmpty {
                Text(m.lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(Tan.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Button("Server settings") {
                draft = serverHost
                editing = true
            }
            .font(.system(size: 13))
            .foregroundStyle(Tan.faint)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .alert("MrLTTec server", isPresented: $editing) {
            TextField(API.defaultHost, text: $draft)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save") {
                serverHost = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                m.connected = nil
                Task { await m.connect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The mini PC's Tailscale address. Leave it empty for the normal one.")
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let t = m.toast {
            Text(t.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tan.card)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(t.bad ? Tan.bad : Tan.dark, in: Capsule())
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { m.toast = nil }
                .id(t.id)
        }
    }
}
