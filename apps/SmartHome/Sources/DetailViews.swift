import SwiftUI

/// Opens the right screen for each kind of device.
struct DeviceDetailView: View {
    let device: Device
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        Group {
            switch device.type {
            case "sonos": SonosView(device: device)
            case "roku": RokuView(device: device)
            case "samsung": SamsungView(device: device)
            case "wiz": WizLightView(device: device)
            case "wled": WledView(device: device)
            case "wemo", "wizplug": PlugView(device: device)
            case "xbox": XboxView(device: device)
            case "firetv": FireTVView(device: device)
            default: UnsupportedView(device: device)
            }
        }
        .navigationTitle(store.all.first(where: { $0.id == device.id })?.name ?? device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.isSaved(device.type, device.ip) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { store.add(type: device.type, ip: device.ip, name: device.name, detail: device.detail); Haptic.success() }
                }
            }
        }
    }
}

/// Big round power button used by plugs and lights.
struct PowerButton: View {
    let on: Bool?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(on == true ? Theme.brown : .secondary)
                    .frame(width: 120, height: 120)
                    .background(on == true ? Theme.gold : Color(.tertiarySystemFill), in: Circle())
                    .shadow(color: on == true ? Theme.gold.opacity(0.5) : .clear, radius: 18)
                Text(on == nil ? "Checking…" : on! ? "On" : "Off").font(.headline).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(.snappy, value: on)
    }
}

// MARK: - Plugs (Wemo, WiZ outlet)

struct PlugView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var on: Bool?
    @State private var advanced = false
    @State private var info = ""

    var body: some View {
        Form {
            Section { DeviceHeader(device: device) }
            Section {
                PowerButton(on: on) { toggle() }
            }
            .listRowBackground(Color.clear)
            AdvancedToggle(on: $advanced)
            if advanced {
                Section("Device") {
                    Button("Show device info") {
                        Task {
                            if let r = await runner.run(nil, {
                                if device.type == "wemo" { return try await Wemo.info(device.ip) }
                                return try await Wiz.run(device.ip, "info", "")
                            }) { info = r; runner.note = nil }
                        }
                    }
                    if !info.isEmpty { InfoText(text: info) }
                }
                NetworkChecks(ip: device.ip, runner: runner)
            }
        }
        .notes(runner)
        .task { on = await Power.get(device) ?? false }
        .refreshable { on = await Power.get(device) }
    }

    private func toggle() {
        let target = !(on ?? false)
        Haptic.tap(.medium)
        Task {
            if await runner.run(nil, haptic: false, { try await Power.set(device, target); return "" }) != nil { on = target }
        }
    }
}

// MARK: - WiZ light

struct WizLightView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var on: Bool?
    @State private var bri = 80.0
    @State private var temp = 4000.0
    @State private var color = Color.orange
    @State private var advanced = false
    @State private var info = ""

    var body: some View {
        Form {
            Section { DeviceHeader(device: device) }
            Section { PowerButton(on: on) { setPower(!(on ?? false)) } }.listRowBackground(Color.clear)
            Section("Brightness") {
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $bri, in: 10...100, step: 1, onEditingChanged: { editing in
                        if !editing { send("bri\(Int(bri))") { on = true } }
                    })
                    Image(systemName: "sun.max.fill")
                }
                .foregroundStyle(.secondary)
            }
            AdvancedToggle(on: $advanced)
            if advanced {
                Section("Color") {
                    ColorPicker("Pick a color", selection: $color, supportsOpacity: false)
                        .onChange(of: color) { _, c in sendColor(c) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach([Color.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .white, .mint, .indigo, .teal], id: \.self) { c in
                            Circle().fill(c).frame(height: 34).onTapGesture { color = c }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("White") {
                    HStack {
                        Text("Warm").font(.caption).foregroundStyle(.orange)
                        Slider(value: $temp, in: 2200...6500, step: 100, onEditingChanged: { editing in
                            if !editing { send("temp\(Int(temp))") { on = true } }
                        })
                        Text("Cool").font(.caption).foregroundStyle(.cyan)
                    }
                    Text("\(Int(temp)) K").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Section("Scenes") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(WizScenes.all.map { WizScene(id: $0.0, name: $0.1) }) { s in
                                Button(s.name) { send("scene\(s.id)", done: "Scene: \(s.name)") { on = true } }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Device") {
                    Button("Show device info") {
                        Task { if let r = await runner.run(nil, { try await Wiz.info(device.ip) }) { info = r; runner.note = nil } }
                    }
                    if !info.isEmpty { InfoText(text: info) }
                }
                NetworkChecks(ip: device.ip, runner: runner)
            }
        }
        .notes(runner)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let p = try? await Wiz.pilot(device.ip) else { on = false; runner.show(Wiz.noAnswer, error: true); return }
        on = p["state"] as? Bool ?? false
        if let d = p["dimming"] as? Int { bri = Double(d) }
        if let t = p["temp"] as? Int, t > 0 { temp = Double(t) }
    }

    private func setPower(_ v: Bool) {
        Haptic.tap(.medium)
        Task { if await runner.run(nil, haptic: false, { try await Wiz.run(device.ip, v ? "on" : "off", "") }) != nil { on = v } }
    }

    private func send(_ cmd: String, done: String? = nil, then: @escaping () -> Void = {}) {
        Task { if await runner.run(done, { try await Wiz.run(device.ip, cmd, "") }) != nil { then() } }
    }

    private func sendColor(_ c: Color) {
        let u = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        let arg = "\(Int(max(0, min(1, r)) * 255)),\(Int(max(0, min(1, g)) * 255)),\(Int(max(0, min(1, b)) * 255))"
        Task { if await runner.run(nil, { try await Wiz.run(device.ip, "color", arg) }) != nil { on = true } }
    }
}

struct WizScene: Identifiable { let id: Int; let name: String }

// MARK: - WLED

struct WledView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var on: Bool?
    @State private var bri = 128.0
    @State private var color = Color.orange
    @State private var advanced = false
    @State private var effects: [String] = []
    @State private var info = ""

    var body: some View {
        Form {
            Section { DeviceHeader(device: device) }
            Section { PowerButton(on: on) { setPower(!(on ?? false)) } }.listRowBackground(Color.clear)
            Section("Brightness") {
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $bri, in: 1...255, step: 1, onEditingChanged: { editing in
                        if !editing { Task { if await runner.run(nil, { try await Wled.run(device.ip, "bri\(Int(bri))"); return "" }) != nil { on = true } } }
                    })
                    Image(systemName: "sun.max.fill")
                }
                .foregroundStyle(.secondary)
            }
            AdvancedToggle(on: $advanced)
            if advanced {
                Section("Color") {
                    ColorPicker("Pick a color", selection: $color, supportsOpacity: false)
                        .onChange(of: color) { _, c in
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
                            runner.fire { try await Wled.setColor(device.ip, r: Int(max(0, min(1, r)) * 255), g: Int(max(0, min(1, g)) * 255), b: Int(max(0, min(1, b)) * 255)) }
                        }
                }
                Section("Effects") {
                    if effects.isEmpty {
                        Button("Load effects") { Task { effects = (try? await Wled.effects(device.ip)) ?? [] } }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Array(effects.enumerated()), id: \.offset) { i, name in
                                    Button(name) { runner.fire("Effect: \(name)") { try await Wled.setEffect(device.ip, i) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section("Device") {
                    Button("Show device info") {
                        Task { if let r = await runner.run(nil, { try await Wled.info(device.ip) }) { info = r; runner.note = nil } }
                    }
                    if !info.isEmpty { InfoText(text: info) }
                }
                NetworkChecks(ip: device.ip, runner: runner)
            }
        }
        .notes(runner)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let s = await Wled.state(device.ip) { on = s.on; bri = Double(max(1, s.bri)) } else { on = false }
    }

    private func setPower(_ v: Bool) {
        Haptic.tap(.medium)
        Task { if await runner.run(nil, haptic: false, { try await Wled.run(device.ip, v ? "on" : "off"); return "" }) != nil { on = v } }
    }
}

// MARK: - Xbox (turn on only: everything else needs Microsoft's cloud)

struct XboxView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var advanced = false
    @State private var liveId = ""

    var body: some View {
        Form {
            Section { DeviceHeader(device: device) }
            Section {
                Button {
                    Haptic.tap(.medium)
                    Task { await runner.run(nil, haptic: false) { try await Xbox.run(device.ip, "on", "") } }
                } label: {
                    Label("Turn on", systemImage: "power").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await runner.run { try await Xbox.run(device.ip, "status", "") } }
                } label: {
                    Label("Is it on?", systemImage: "questionmark.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } footer: {
                Text("Works when the Xbox power mode is set to Sleep. Turning it off or using it as a remote needs a Microsoft sign-in, so this tool doesn't do that.")
            }
            .listRowBackground(Color.clear)
            AdvancedToggle(on: $advanced)
            if advanced {
                Section {
                    TextField("Live ID, like FD00112233445566", text: $liveId).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Save Live ID") { Task { await runner.run { try await Xbox.run(device.ip, "setid", liveId) } } }
                } header: {
                    Text("Live ID")
                } footer: {
                    Text("Saved automatically the first time the Xbox answers \"Is it on?\". Find it on the Xbox under Settings > System > Console info.")
                }
                NetworkChecks(ip: device.ip, runner: runner)
            }
        }
        .notes(runner)
        .onAppear { liveId = Store.get("xbox", device.ip) }
    }
}

// MARK: - Not ported yet

struct UnsupportedView: View {
    let device: Device
    @StateObject private var runner = Runner()
    var body: some View {
        Form {
            Section { DeviceHeader(device: device, subtitle: device.detail.isEmpty ? device.ip : device.detail) }
            Section {
                Label("Controls for \(device.kindName) are coming in a later update.", systemImage: "hammer")
            }
            NetworkChecks(ip: device.ip, runner: runner)
        }
        .notes(runner)
    }
}
