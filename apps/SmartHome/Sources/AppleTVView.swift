import SwiftUI

struct AppleTVView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var paired = false
    @State private var pinShown = false
    @State private var pin = ""
    @State private var advanced = false
    @State private var apps: [AppItem] = []

    struct AppItem: Identifiable, Hashable { let id: String; let name: String }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DeviceHeader(device: device, subtitle: paired ? "Paired · \(device.ip)" : "Not paired yet · \(device.ip)").padding(.horizontal)

                if !paired { pairCard.padding(.horizontal) }

                HStack(spacing: 22) {
                    RemoteKey(icon: "power", label: "Sleep", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { press("sleep") }
                    RemoteKey(icon: "sun.max.fill", label: "Wake", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { press("wake") }
                    RemoteKey(icon: "chevron.backward", label: "Back") { press("menu") }
                    RemoteKey(icon: "tv", label: "TV / Home") { press("home") }
                }

                DPad { k in press(k) }

                HStack(spacing: 30) {
                    RemoteKey(icon: "backward.end.fill", label: "Previous") { media("previous") }
                    RemoteKey(icon: "playpause.fill", label: "Play", size: 64, tint: Theme.gold, fg: Theme.brown) { press("playpause") }
                    RemoteKey(icon: "forward.end.fill", label: "Next") { media("next") }
                }

                VolumeBar(down: { press("voldown") }, mute: { runner.show("Apple TV remotes have no mute button.", error: true) }, up: { press("volup") })

                Text("Volume works when the Apple TV controls your TV or receiver (HDMI-CEC or IR).")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)

                advancedSection
            }
            .padding(.vertical)
        }
        .notes(runner)
        .onAppear { paired = AppleTV.isPaired(device.ip) }
    }

    private var pairCard: some View {
        Card("Pair with this Apple TV") {
            if !pinShown {
                Text("Tap Start pairing. The Apple TV shows a 4-digit PIN.").font(.footnote).foregroundStyle(.secondary)
                Button {
                    Task {
                        if await runner.run("Check the TV for the PIN", { try await AppleTV.shared.startPairing(device.ip); return "" }) != nil {
                            withAnimation { pinShown = true }
                        }
                    }
                } label: { Label("Start pairing", systemImage: "tv").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Type the PIN that's on the TV now.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("PIN", text: $pin).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    Button("Pair") {
                        let p = pin.trimmed
                        Task {
                            if await runner.run("Paired", { try await AppleTV.shared.finishPairing(device.ip, pin: p); return "" }) != nil {
                                withAnimation { paired = true; pinShown = false }; pin = ""; Haptic.success()
                            } else {
                                pinShown = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder private var advancedSection: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.snappy) { advanced.toggle() }; Haptic.tap()
            } label: {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(advanced ? 180 : 0))
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .foregroundStyle(.primary)

            if advanced {
                Card("Apps") {
                    if apps.isEmpty {
                        Button("Load apps") {
                            Task {
                                do { apps = try await AppleTV.shared.apps(device.ip).map { AppItem(id: $0.id, name: $0.name) } }
                                catch { runner.show(error.localizedDescription, error: true) }
                            }
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                            ForEach(apps) { a in
                                Button(a.name) { runner.fire("Opening \(a.name)") { try await AppleTV.shared.launch(device.ip, a.id) } }
                                    .buttonStyle(.bordered).frame(maxWidth: .infinity).lineLimit(1)
                            }
                        }
                        .font(.footnote)
                    }
                }

                Card("Photos and videos") {
                    NavigationLink {
                        CastTargetView(target: CastTarget(ip: device.ip, name: device.name, air: true))
                    } label: {
                        HStack { Label("Show photos and videos on this TV", systemImage: "airplayvideo"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                    }
                    .foregroundStyle(.primary)
                }

                Card("More buttons") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach([["Play", "m:play"], ["Pause", "m:pause"], ["Screensaver", "screensaver"], ["Guide", "guide"],
                                 ["Channel +", "chup"], ["Channel -", "chdown"], ["Page up", "pageup"], ["Page down", "pagedown"], ["Siri", "siri"]], id: \.self) { b in
                            Button(b[0]) {
                                if b[1].hasPrefix("m:") { media(String(b[1].dropFirst(2))) } else { press(b[1]) }
                            }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    .font(.footnote)
                }

                Card("Device") {
                    if paired {
                        Button("Pair again", role: .destructive) {
                            Task { await AppleTV.shared.forget(device.ip) }
                            withAnimation { paired = false }
                        }
                    }
                    PingRow(ip: device.ip, runner: runner)
                }
            }
        }
        .padding(.horizontal)
    }

    private func press(_ b: String) {
        guard paired else { runner.show("Pair first: tap Start pairing.", error: true); Haptic.error(); return }
        Task { await runner.run(nil) { try await AppleTV.shared.press(device.ip, b); return "" } }
    }

    private func media(_ m: String) {
        guard paired else { runner.show("Pair first: tap Start pairing.", error: true); Haptic.error(); return }
        Task { await runner.run(nil) { try await AppleTV.shared.mediaCommand(device.ip, m); return "" } }
    }
}
