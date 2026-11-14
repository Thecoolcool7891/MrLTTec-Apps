import SwiftUI

struct AdbView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var advanced = false
    @State private var apps: [String] = []
    @State private var text = ""
    @State private var yt = ""
    @State private var pkg = ""
    @State private var info = ""

    static let quickApps = [("YouTube", "com.amazon.firetv.youtube|com.google.android.youtube.tv"), ("Netflix", "com.netflix.ninja"),
                            ("Prime Video", "com.amazon.avod|com.amazon.amazonvideo.livingroom"), ("Disney+", "com.disney.disneyplus"),
                            ("Hulu", "com.hulu.plus"), ("Plex", "com.plexapp.android")]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DeviceHeader(device: device, subtitle: device.detail.isEmpty ? device.ip : device.detail).padding(.horizontal)

                HStack(spacing: 22) {
                    RemoteKey(icon: "moon.fill", label: "Sleep", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { key("sleep") }
                    RemoteKey(icon: "sun.max.fill", label: "Wake", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { key("wake") }
                    RemoteKey(icon: "arrow.uturn.backward", label: "Back") { key("back") }
                    RemoteKey(icon: "house.fill", label: "Home") { key("home") }
                }

                DPad { k in key(k) }

                HStack(spacing: 22) {
                    RemoteKey(icon: "backward.fill", label: "Rewind", repeats: true) { key("rewind") }
                    RemoteKey(icon: "playpause.fill", label: "Play") { key("playpause") }
                    RemoteKey(icon: "forward.fill", label: "Forward", repeats: true) { key("ffwd") }
                    RemoteKey(icon: "line.3.horizontal", label: "Menu") { key("menu") }
                }

                VolumeBar(down: { key("voldown") }, mute: { key("mute") }, up: { key("volup") })

                Text("The first time, the TV asks \"Allow USB debugging?\". Tick Always allow and press OK.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)

                advancedSection
            }
            .padding(.vertical)
        }
        .notes(runner)
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(Self.quickApps.map { [$0.0, $0.1] }, id: \.self) { a in
                            Button(a[0]) { runner.fire("Opening \(a[0])") { try await Adb.shared.launch(device.ip, a[1]) } }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    .font(.footnote)
                    if apps.isEmpty {
                        Button("Show all installed apps") {
                            Task { if let r = try? await Adb.shared.apps(device.ip) { apps = r } else { runner.show("The TV didn't send its app list.", error: true) } }
                        }
                    } else {
                        ForEach(apps, id: \.self) { p in
                            Button {
                                runner.fire("Opening \(Adb.appNames[p] ?? p)") { try await Adb.shared.launch(device.ip, p) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(Adb.appNames[p] ?? p.split(separator: ".").last.map(String.init)?.capitalized ?? p)
                                        Text(p).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    HStack {
                        TextField("Package, like com.hulu.plus", text: $pkg)
                            .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Open") { let p = pkg.trimmed; runner.fire("Opening \(p)") { try await Adb.shared.launch(device.ip, p) } }
                            .buttonStyle(.bordered)
                    }
                }

                Card("Screen mirroring") {
                    Button {
                        Task { await runner.run(nil) { try await Adb.shared.startMirroring(device.ip) } }
                    } label: { Label("Turn on Display Mirroring (Android, Windows)", systemImage: "rectangle.on.rectangle") }
                    Button {
                        Task { await runner.run(nil) { try await Adb.shared.mirrorIPhone(device.ip) } }
                    } label: { Label("Mirror this iPhone (AirScreen)", systemImage: "iphone.and.arrow.forward") }
                    Text("Fire TV mirroring uses Miracast, which iPhones don't support. AirScreen is a free app that lets the TV accept iPhone Screen Mirroring.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card("YouTube link") {
                    HStack {
                        TextField("Paste a YouTube link", text: $yt).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Play") { let l = yt; runner.fire("Opening on the TV") { try await Adb.shared.youtube(device.ip, l) } }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Card("Type on the TV") {
                    HStack {
                        TextField("Text", text: $text).textFieldStyle(.roundedBorder)
                        Button("Send") { let t = text; runner.fire("Typed") { try await Adb.shared.text(device.ip, t) } }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack {
                        Button("Delete") { key("del") }
                        Button("Enter") { key("enter") }
                        Button("Search") { key("search") }
                    }
                    .buttonStyle(.bordered)
                }

                Card("Number pad") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                        ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "CH-", "0", "CH+"], id: \.self) { n in
                            RemoteKey(icon: n == "CH-" ? "chevron.down" : n == "CH+" ? "chevron.up" : n, size: 52, repeats: n.hasPrefix("CH")) {
                                key(n == "CH-" ? "chdown" : n == "CH+" ? "chup" : "n\(n)")
                            }
                        }
                    }
                }

                Card("More keys") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach([["Settings", "settings"], ["Recent apps", "recents"], ["Guide", "guide"], ["Previous", "prev"], ["Next", "next"], ["Stop", "stop"]], id: \.self) { k in
                            Button(k[0]) { key(k[1]) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    .font(.footnote)
                }

                Card("Device") {
                    Button("Show device info") {
                        Task { if let r = await runner.run(nil, { try await Adb.shared.info(device.ip) }) { info = r; runner.note = nil } }
                    }
                    if !info.isEmpty { InfoText(text: info) }
                    PingRow(ip: device.ip, runner: runner)
                }
            }
        }
        .padding(.horizontal)
    }

    private func key(_ k: String) {
        Task { await runner.run(nil) { try await Adb.shared.key(device.ip, k); return "" } }
    }
}
