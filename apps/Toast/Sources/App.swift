import Combine
import SwiftUI
import UIKit

@main
struct ToastApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(Tan.brown)
        }
        .onChange(of: phase) { _, new in
            if new == .background { Background.schedule() }
        }
        .backgroundTask(.appRefresh(Background.taskId)) {
            await Background.run()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.paired {
                MainTabs()
            } else {
                PairView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toastSignedOut).receive(on: RunLoop.main)) { _ in
            model.signOut()
        }
        .task(id: model.paired) {
            await model.runLoop()
        }
        .onChange(of: phase) { _, new in
            if new == .active && model.paired {
                Task { await model.refreshAll() }
            }
        }
    }
}

extension AppModel {
    /// First load, then look for new alerts every 20 seconds while the app is open.
    func runLoop() async {
        if !paired { return }
        await refreshAll()
        while !Task.isCancelled && paired {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if UIApplication.shared.applicationState == .active {
                await pollNotes()
            }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.tab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                NavigationStack { HomeView() }
            }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: 1) {
                NavigationStack { ChatView() }
            }
            .badge(model.unread)
            Tab("Grades", systemImage: "chart.bar.fill", value: 2) {
                NavigationStack { GradesView() }
            }
            Tab("Plan", systemImage: "checklist", value: 3) {
                NavigationStack { PlanView() }
            }
            Tab("More", systemImage: "ellipsis.circle.fill", value: 4) {
                NavigationStack { MoreView() }
            }
        }
        .onChange(of: model.tab) { _, t in
            if t == 1 { model.unread = 0 }
        }
    }
}

/// First screen: type the 6-digit code Toast texts you on Telegram.
struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var server = API.server
    @State private var busy = false
    @State private var problem: String?
    @State private var showServer = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("🍞")
                    .font(.system(size: 64))
                    .frame(width: 120, height: 120)
                    .background(Tan.dark, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(.top, 40)
                Text("Toast").font(.largeTitle.bold()).foregroundStyle(Tan.text)
                Text("Your school assistant").font(.subheadline).foregroundStyle(Tan.muted)

                Card(title: "Sign in", icon: "key.fill") {
                    step("1", "Turn on Tailscale on this phone.")
                    step("2", "In Telegram, text /app to Toast.")
                    step("3", "Type the 6-digit code it sends you.")
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(Tan.text)
                        .padding(.vertical, 10)
                        .background(Tan.bar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .focused($codeFocused)
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter { $0.isNumber }.prefix(6))
                            if digits != new { code = digits }
                        }
                    if let problem = problem {
                        Note(text: problem, bad: true)
                    }
                    BrownButton(title: "Connect", icon: "link", busy: busy) { connect() }
                        .opacity(code.count == 6 ? 1 : 0.5)
                        .disabled(code.count != 6)
                }

                Card {
                    Button {
                        showServer.toggle()
                    } label: {
                        HStack {
                            Text("Server address").font(.subheadline).foregroundStyle(Tan.muted)
                            Spacer()
                            Image(systemName: showServer ? "chevron.up" : "chevron.down").foregroundStyle(Tan.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    if showServer {
                        TextField(API.defaultServer, text: $server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                            .foregroundStyle(Tan.text)
                        Note(text: "The mini PC's Tailscale address. Only change it if Toast moved.")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .background(Tan.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Tan.brown, in: Circle())
            Text(text).font(.subheadline).foregroundStyle(Tan.text)
            Spacer()
        }
    }

    private func connect() {
        if busy { return }
        busy = true
        problem = nil
        codeFocused = false
        let c = code
        let s = server
        Task {
            do {
                try await model.pair(code: c, server: s)
                Haptic.done()
            } catch {
                problem = error.localizedDescription
                Haptic.fail()
            }
            busy = false
        }
    }
}
