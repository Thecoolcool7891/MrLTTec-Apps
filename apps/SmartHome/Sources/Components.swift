import SwiftUI

// MARK: - Running commands with a status note

/// Runs device commands one at a time and shows what happened in a small note at the bottom of the screen.
@MainActor
final class Runner: ObservableObject {
    @Published var note: String?
    @Published var isError = false
    @Published var busy = false
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, error: Bool = false) {
        note = text; isError = error
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 6_000_000_000 : 3_000_000_000)
            if !Task.isCancelled { self?.note = nil }
        }
    }

    /// `done`: message on success (nil = stay quiet unless the device sent text back).
    @discardableResult
    func run(_ done: String? = nil, haptic: Bool = true, _ op: @escaping () async throws -> String) async -> String? {
        if haptic { Haptic.tap() }
        busy = true
        defer { busy = false }
        do {
            let r = try await op()
            if !r.isEmpty && r != "ok" { show(r) } else if let done { show(done) }
            return r
        } catch {
            Haptic.error()
            show(error.localizedDescription, error: true)
            return nil
        }
    }

    func fire(_ done: String? = nil, _ op: @escaping () async throws -> Void) {
        Task { await run(done) { try await op(); return "" } }
    }
}

struct NoteOverlay: ViewModifier {
    @ObservedObject var runner: Runner
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let n = runner.note {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: runner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(runner.isError ? .orange : .green)
                    Text(n).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { runner.note = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: runner.note)
    }
}

extension View {
    func notes(_ r: Runner) -> some View { modifier(NoteOverlay(runner: r)) }
}

// MARK: - Remote buttons

/// A round remote key. Holding it repeats (for arrows, volume, channels).
struct RemoteKey: View {
    let icon: String
    var label: String? = nil
    var size: CGFloat = 56
    var tint: Color = Color(.secondarySystemBackground)
    var fg: Color = .primary
    var repeats = false
    let action: () -> Void

    @State private var pressed = false
    @State private var timer: Timer?
    @State private var delay: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(tint)
                if icon.count <= 2 && !icon.contains(".") {
                    Text(icon).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: icon).font(.system(size: size * 0.36, weight: .semibold))
                }
            }
            .foregroundStyle(fg)
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        if repeats {
                            let w = DispatchWorkItem {
                                timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in action() }
                            }
                            delay = w
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
                        }
                    }
                    .onEnded { _ in stop() }
            )
            .onDisappear { stop() }
            if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityLabel(label ?? icon)
        .accessibilityAddTraits(.isButton)
    }

    private func stop() {
        pressed = false
        delay?.cancel(); delay = nil
        timer?.invalidate(); timer = nil
    }
}

/// Circular D-pad with an OK button in the middle.
struct DPad: View {
    let send: (String) -> Void   // "up", "down", "left", "right", "ok"
    var body: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemBackground)).frame(width: 220, height: 220)
            VStack(spacing: 0) {
                arrow("chevron.up", "up")
                HStack(spacing: 0) {
                    arrow("chevron.left", "left")
                    RemoteKey(icon: "OK", size: 86, tint: Color(.tertiarySystemBackground)) { send("ok") }
                    arrow("chevron.right", "right")
                }
                arrow("chevron.down", "down")
            }
        }
    }
    private func arrow(_ icon: String, _ key: String) -> some View {
        RemoteKey(icon: icon, size: 66, tint: .clear, repeats: true) { send(key) }
    }
}

// MARK: - Small building blocks

struct InfoText: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeviceIcon: View {
    let device: Device
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: device.icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(device.tint)
            .frame(width: size, height: size)
            .background(device.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Header shown at the top of each device screen.
struct DeviceHeader: View {
    let device: Device
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            DeviceIcon(device: device, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.kindName).font(.subheadline.weight(.semibold))
                Text(subtitle ?? device.ip).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// "Network" section every device screen has in Advanced: ping and open ports for that address.
struct NetworkChecks: View {
    let ip: String
    @ObservedObject var runner: Runner
    @State private var result = ""

    var body: some View {
        Section("Network") {
            LabeledContent("IP address", value: ip)
            Button { Task { if let r = await runner.run(nil, haptic: true, { try await NetTools.run("ping", ip, "") }) { result = r; runner.note = nil } } } label: {
                Label("Ping", systemImage: "dot.radiowaves.left.and.right")
            }
            Button { Task { if let r = await runner.run(nil, haptic: true, { try await NetTools.run("common", ip, "") }) { result = r; runner.note = nil } } } label: {
                Label("Check open ports", systemImage: "network")
            }
            if !result.isEmpty { InfoText(text: result) }
        }
    }
}

/// Collapsible "Advanced" header used on every device screen.
struct AdvancedToggle: View {
    @Binding var on: Bool
    var body: some View {
        Section {
            Button {
                withAnimation(.snappy) { on.toggle() }
                Haptic.tap()
            } label: {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(on ? 180 : 0)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
    }
}
