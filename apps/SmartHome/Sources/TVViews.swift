import SwiftUI

// MARK: - Roku

struct RokuView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var advanced = false
    @State private var nowOpen = ""
    @State private var apps: [RokuApp] = []
    @State private var text = ""
    @State private var info = ""

    struct RokuApp: Identifiable, Hashable { let id: String; let name: String }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DeviceHeader(device: device, subtitle: nowOpen.isEmpty ? device.ip : nowOpen)
                    .padding(.horizontal)

                HStack(spacing: 22) {
                    RemoteKey(icon: "power", label: "Power", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { key("PowerOff") }
                    RemoteKey(icon: "arrow.uturn.backward", label: "Back") { key("Back") }
                    RemoteKey(icon: "house.fill", label: "Home") { key("Home") }
                    RemoteKey(icon: "asterisk", label: "Options") { key("Info") }
                }

                DPad { k in
                    key(["up": "Up", "down": "Down", "left": "Left", "right": "Right", "ok": "Select"][k] ?? "Select")
                }

                HStack(spacing: 22) {
                    RemoteKey(icon: "backward.fill", label: "Rewind", repeats: true) { key("Rev") }
                    RemoteKey(icon: "playpause.fill", label: "Play") { key("Play") }
                    RemoteKey(icon: "forward.fill", label: "Forward", repeats: true) { key("Fwd") }
                    RemoteKey(icon: "gobackward", label: "Replay") { key("InstantReplay") }
                }

                VolumeBar(down: { key("VolumeDown") }, mute: { key("VolumeMute") }, up: { key("VolumeUp") })

                advancedSection
            }
            .padding(.vertical)
        }
        .notes(runner)
        .task { await refreshActive() }
        .refreshable { await refreshActive() }
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
                        Button("Load apps") { Task { await loadApps() } }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                            ForEach(apps) { a in
                                Button {
                                    runner.fire("Opening \(a.name)") { _ = try await Roku.run(device.ip, "app", a.id) }
                                } label: {
                                    VStack(spacing: 4) {
                                        AsyncImage(url: URL(string: "http://\(device.ip):8060/query/icon/\(a.id)")) { img in
                                            img.resizable().scaledToFit()
                                        } placeholder: { Color(.tertiarySystemFill) }
                                        .frame(height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        Text(a.name).font(.caption2).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Card("Type on the TV") {
                    HStack {
                        TextField("Search text", text: $text).textFieldStyle(.roundedBorder)
                        Button("Send") { let t = text; runner.fire("Typed") { _ = try await Roku.run(device.ip, "text", t) } }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack {
                        Button("Backspace") { key("Backspace") }
                        Button("Enter") { key("Enter") }
                        Button("Search") { key("Search") }
                    }
                    .buttonStyle(.bordered)
                }

                Card("Channels and inputs (Roku TVs)") {
                    HStack {
                        Button { key("ChannelDown") } label: { Label("Ch", systemImage: "chevron.down") }
                        Button { key("ChannelUp") } label: { Label("Ch", systemImage: "chevron.up") }
                        Button("Antenna") { key("InputTuner") }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        ForEach(1...4, id: \.self) { n in Button("HDMI \(n)") { key("InputHDMI\(n)") } }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                    HStack {
                        Button("AV") { key("InputAV1") }
                        Button("Wake (try)") { key("PowerOn") }
                        Button("Find remote") { key("FindRemote") }
                    }
                    .buttonStyle(.bordered)
                }

                Card("Device") {
                    Button("Show device info") {
                        Task { if let r = await runner.run(nil, { try await Roku.run(device.ip, "info", "") }) { info = r; runner.note = nil } }
                    }
                    if !info.isEmpty { InfoText(text: info) }
                    PingRow(ip: device.ip, runner: runner)
                }
            }
        }
        .padding(.horizontal)
    }

    private func key(_ k: String) {
        Task { await runner.run(nil) { try await Roku.run(device.ip, k, "") } }
    }

    private func refreshActive() async {
        if let r = try? await Roku.run(device.ip, "active", "") { nowOpen = r }
    }

    private func loadApps() async {
        guard let json = await runner.run(nil, { try await Roku.run(device.ip, "apps", "") }) else { return }
        runner.note = nil
        if let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] {
            apps = arr.compactMap { a in
                guard let id = a["id"], !id.isEmpty else { return nil }
                return RokuApp(id: id, name: a["name"] ?? id)
            }
        }
    }
}

// MARK: - Samsung

struct SamsungView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var advanced = false
    @State private var apps: [SamApp] = []
    @State private var text = ""
    @State private var mac = ""
    @State private var info = ""
    @State private var showNumbers = false

    struct SamApp: Identifiable, Hashable { let id: String; let name: String }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DeviceHeader(device: device, subtitle: device.detail.isEmpty ? device.ip : device.detail).padding(.horizontal)

                HStack(spacing: 22) {
                    RemoteKey(icon: "power", label: "Power", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { key("KEY_POWER") }
                    RemoteKey(icon: "arrow.uturn.backward", label: "Back") { key("KEY_RETURN") }
                    RemoteKey(icon: "house.fill", label: "Home") { key("KEY_HOME") }
                    RemoteKey(icon: "rectangle.on.rectangle", label: "Source") { key("KEY_SOURCE") }
                }

                DPad { k in
                    key(["up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT", "ok": "KEY_ENTER"][k] ?? "KEY_ENTER")
                }

                HStack(spacing: 22) {
                    RemoteKey(icon: "backward.fill", label: "Rewind", repeats: true) { key("KEY_REWIND") }
                    RemoteKey(icon: "play.fill", label: "Play") { key("KEY_PLAY") }
                    RemoteKey(icon: "pause.fill", label: "Pause") { key("KEY_PAUSE") }
                    RemoteKey(icon: "forward.fill", label: "Forward", repeats: true) { key("KEY_FF") }
                }

                HStack(spacing: 12) {
                    VolumeBar(down: { key("KEY_VOLDOWN") }, mute: { key("KEY_MUTE") }, up: { key("KEY_VOLUP") })
                    VStack(spacing: 8) {
                        RemoteKey(icon: "chevron.up", size: 44, repeats: true) { key("KEY_CHUP") }
                        Text("CH").font(.caption2).foregroundStyle(.secondary)
                        RemoteKey(icon: "chevron.down", size: 44, repeats: true) { key("KEY_CHDOWN") }
                    }
                    .padding(.trailing)
                }

                Text("The first time, the TV asks you to allow this app. Choose Allow on the TV screen.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)

                advancedSection
            }
            .padding(.vertical)
        }
        .notes(runner)
        .onAppear { mac = Store.get("samsungMacs", device.ip) }
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
                Card("Number pad") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                        ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "0", "OK"], id: \.self) { n in
                            RemoteKey(icon: n == "OK" ? "checkmark" : n == "-" ? "minus" : n, size: 52) {
                                key(n == "OK" ? "KEY_ENTER" : n == "-" ? "KEY_PLUS100" : "KEY_\(n)")
                            }
                        }
                    }
                }

                Card("More keys") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach([("Menu", "KEY_MENU"), ("Guide", "KEY_GUIDE"), ("Info", "KEY_INFO"), ("Stop", "KEY_STOP"),
                                 ("Record", "KEY_REC"), ("Prev ch", "KEY_PRECH"), ("Subtitles", "KEY_CAPTION"), ("Exit", "KEY_EXIT"), ("Tools", "KEY_TOOLS")].map { [$0.0, $0.1] }, id: \.self) { k in
                            Button(k[0]) { key(k[1]) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    .font(.footnote)
                }

                Card("Apps") {
                    if apps.isEmpty {
                        Button("Load apps") { Task { await loadApps() } }
                    } else {
                        ForEach(apps) { a in
                            Button {
                                runner.fire("Opening \(a.name)") { _ = try await Samsung.shared.run(device.ip, "app", a.id) }
                            } label: {
                                HStack { Text(a.name); Spacer(); Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary) }
                            }
                            .foregroundStyle(.primary)
                            Divider()
                        }
                    }
                }

                Card("Type on the TV") {
                    HStack {
                        TextField("Text", text: $text).textFieldStyle(.roundedBorder)
                        Button("Send") { let t = text; runner.fire("Typed") { _ = try await Samsung.shared.run(device.ip, "text", t) } }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Card("Wake the TV") {
                    HStack {
                        TextField("MAC, like AA:BB:CC:DD:EE:FF", text: $mac).textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Save") { let m = mac; Task { await runner.run { try await Samsung.shared.run(device.ip, "mac", m) } } }
                            .buttonStyle(.bordered)
                    }
                    Button("Send wake signal") { Task { await runner.run { try await Samsung.shared.run(device.ip, "wake", "") } } }
                        .buttonStyle(.borderedProminent)
                }

                Card("Device") {
                    Button("Show device info") {
                        Task { if let r = await runner.run(nil, { try await Samsung.shared.run(device.ip, "info", "") }) { info = r; runner.note = nil; mac = Store.get("samsungMacs", device.ip) } }
                    }
                    Button("Pair again") { Task { await runner.run { try await Samsung.shared.run(device.ip, "repair", "") } } }
                    if !info.isEmpty { InfoText(text: info) }
                    PingRow(ip: device.ip, runner: runner)
                }
            }
        }
        .padding(.horizontal)
    }

    private func key(_ k: String) {
        Task { await runner.run(nil) { try await Samsung.shared.run(device.ip, k, "") } }
    }

    private func loadApps() async {
        guard let r = await runner.run(nil, { try await Samsung.shared.run(device.ip, "apps", "") }) else { return }
        runner.note = nil
        apps = r.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", maxSplits: 1)
            return p.count == 2 ? SamApp(id: String(p[0]), name: String(p[1])) : nil
        }
        if apps.isEmpty { runner.show("The TV sent an empty app list.", error: true) }
    }
}

// MARK: - Shared TV pieces

struct VolumeBar: View {
    let down: () -> Void
    let mute: () -> Void
    let up: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            RemoteKey(icon: "speaker.minus.fill", size: 50, tint: .clear, repeats: true, action: down)
            Spacer()
            RemoteKey(icon: "speaker.slash.fill", size: 50, tint: .clear, action: mute)
            Spacer()
            RemoteKey(icon: "speaker.plus.fill", size: 50, tint: .clear, repeats: true, action: up)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .padding(.horizontal)
    }
}

struct Card<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PingRow: View {
    let ip: String
    @ObservedObject var runner: Runner
    @State private var out = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Ping") { go("ping") }
                Button("Open ports") { go("common") }
            }
            .buttonStyle(.bordered)
            if !out.isEmpty { InfoText(text: out) }
        }
    }
    private func go(_ v: String) {
        Task { if let r = await runner.run(nil, { try await NetTools.run(v, ip, "") }) { out = r; runner.note = nil } }
    }
}
