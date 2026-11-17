import SwiftUI

// DLNA Digital Media Renderer (UPnP), the same thing Home Assistant's "DLNA Digital Media Renderer" uses.
// RenderingControl is the TV's own master volume and mute, so it works on any input (HDMI included).
// AVTransport is playback: now playing, play/pause/stop, seek, next/previous, repeat and shuffle.

enum Renderer {
    struct Info: Equatable {
        var location = ""
        var avt = ""
        var rc = ""
        var cm = ""
        var name = ""
        var maker = ""
        var model = ""
    }

    struct State: Equatable {
        var volume: Int?
        var muted: Bool?
        var transport = ""      // PLAYING, PAUSED_PLAYBACK, STOPPED, NO_MEDIA_PRESENT, TRANSITIONING
        var title = ""
        var position = 0
        var duration = 0
        var playMode = ""
        var playing: Bool { transport == "PLAYING" || transport == "TRANSITIONING" }
    }

    static let avtType = "urn:schemas-upnp-org:service:AVTransport:1"
    static let rcType = "urn:schemas-upnp-org:service:RenderingControl:1"
    static let cmType = "urn:schemas-upnp-org:service:ConnectionManager:1"

    // MARK: Finding renderers

    /// SSDP search for MediaRenderers. Asks the multicast group and every address directly
    /// (works even when iOS blocks multicast). Returns ip -> description URL.
    static func search(_ ips: [String]) async -> [String: String] {
        let msg = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n".utf8)
        let answers = (try? await blocking { LowNet.udpSweep(["239.255.255.250"] + ips, port: 1900, payloads: [msg], waitMs: 2000, repeats: 2) }) ?? []
        var out: [String: String] = [:]
        for (_, d) in answers {
            let t = String(decoding: d, as: UTF8.self)
            guard t.range(of: "MediaRenderer", options: .caseInsensitive) != nil,
                  let m = t.firstMatch(of: #/(?im)^LOCATION:\s*(http://([\d.]+)[^\r\n]*)/#) else { continue }
            let ip = String(m.2)
            if isPrivateIp(ip) { out[ip] = String(m.1).trimmed }
        }
        return out
    }

    /// Reads the renderer's description and finds its control addresses.
    static func describe(_ loc: String) async throws -> Info {
        let x = try await Http.call(loc, timeout: 3).text
        var i = Info()
        i.location = loc
        i.name = cleanName(xmlTag(x, "friendlyName") ?? "")
        i.maker = xmlTag(x, "manufacturer") ?? ""
        i.model = xmlTag(x, "modelName") ?? ""
        var base = URL(string: loc)
        if let b = xmlTag(x, "URLBase"), let u = URL(string: b) { base = u }
        guard let base, let rx = try? NSRegularExpression(pattern: "<service>(.*?)</service>", options: [.dotMatchesLineSeparators]) else { return i }
        for m in rx.matches(in: x, range: NSRange(x.startIndex..., in: x)) {
            guard let r = Range(m.range(at: 1), in: x) else { continue }
            let svc = String(x[r])
            let type = xmlTag(svc, "serviceType") ?? ""
            guard let ctl = xmlTag(svc, "controlURL"), let u = URL(string: ctl, relativeTo: base)?.absoluteString else { continue }
            if type.contains("AVTransport") && i.avt.isEmpty { i.avt = u }
            else if type.contains("RenderingControl") && i.rc.isEmpty { i.rc = u }
            else if type.contains("ConnectionManager") && i.cm.isEmpty { i.cm = u }
        }
        return i
    }

    /// Finds the renderer at `ip` (saved address first, then a fresh search, since TVs can change port after a restart).
    static func find(_ ip: String) async throws -> Info {
        let saved = Store.get("dlnaLoc", ip)
        if !saved.isEmpty, let i = try? await describe(saved), !i.rc.isEmpty || !i.avt.isEmpty { return i }
        guard let loc = await search([ip])[ip] else {
            throw AppError("The TV's renderer didn't answer. Make sure the TV is on and on this Wi-Fi.")
        }
        Store.set("dlnaLoc", ip, loc)
        let i = try await describe(loc)
        if i.rc.isEmpty && i.avt.isEmpty { throw AppError("This device doesn't offer any renderer controls.") }
        return i
    }

    // MARK: SOAP

    @discardableResult
    static func soap(_ url: String, _ service: String, _ action: String, _ args: [(String, String)] = []) async throws -> String {
        guard !url.isEmpty else { throw AppError("This TV doesn't offer that control.") }
        var inner = "<InstanceID>0</InstanceID>"
        for (k, v) in args { inner += "<\(k)>\(xmlEscape(v))</\(k)>" }
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service)\">\(inner)</u:\(action)></s:Body></s:Envelope>"
        do {
            let r = try await Http.call(url, method: "POST", body: Data(body.utf8), contentType: "text/xml; charset=\"utf-8\"",
                                        headers: ["SOAPAction": "\"\(service)#\(action)\""], timeout: 5)
            return r.text
        } catch let e as HttpStatusError where e.status == 500 {
            throw AppError("The TV said no to that (\(e.message.replacingOccurrences(of: "The device returned ", with: "")))")
        }
    }

    // MARK: Reading

    static func state(_ i: Info) async -> State {
        var s = State()
        if !i.rc.isEmpty {
            if let x = try? await soap(i.rc, rcType, "GetVolume", [("Channel", "Master")]), let v = Int(xmlTag(x, "CurrentVolume") ?? "") { s.volume = v }
            if let x = try? await soap(i.rc, rcType, "GetMute", [("Channel", "Master")]), let m = xmlTag(x, "CurrentMute") {
                s.muted = m == "1" || m.lowercased() == "true"
            }
        }
        if !i.avt.isEmpty {
            if let x = try? await soap(i.avt, avtType, "GetTransportInfo") { s.transport = xmlTag(x, "CurrentTransportState") ?? "" }
            if let x = try? await soap(i.avt, avtType, "GetPositionInfo") {
                s.position = seconds(xmlTag(x, "RelTime") ?? "")
                s.duration = seconds(xmlTag(x, "TrackDuration") ?? "")
                if let meta = xmlTag(x, "TrackMetaData") { s.title = xmlTag(meta, "dc:title") ?? "" }
            }
            if let x = try? await soap(i.avt, avtType, "GetTransportSettings") { s.playMode = xmlTag(x, "PlayMode") ?? "" }
        }
        return s
    }

    /// Sound modes (UPnP presets). Home Assistant calls these "sound mode".
    static func presets(_ i: Info) async -> [String] {
        guard let x = try? await soap(i.rc, rcType, "ListPresets"), let list = xmlTag(x, "CurrentPresetNameList") else { return [] }
        return list.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    /// Brightness, Contrast or Sharpness (nil when the TV doesn't allow it).
    static func picture(_ i: Info, _ name: String) async -> Int? {
        guard let x = try? await soap(i.rc, rcType, "Get\(name)") else { return nil }
        return Int(xmlTag(x, "Current\(name)") ?? "")
    }

    /// The kinds of files the TV says it can play.
    static func formats(_ i: Info) async throws -> String {
        let x = try await soap(i.cm, cmType, "GetProtocolInfo", [])
        let sink = xmlTag(x, "Sink") ?? ""
        var seen: [String] = []
        for entry in sink.split(separator: ",") {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let mime = String(parts[2]).trimmed.lowercased()
            if !mime.isEmpty && mime != "*" && !seen.contains(mime) { seen.append(mime) }
        }
        if seen.isEmpty { return "The TV didn't list any formats." }
        let groups = ["video", "audio", "image"].map { g -> String in
            let items = seen.filter { $0.hasPrefix(g + "/") }.map { String($0.dropFirst(g.count + 1)) }
            return items.isEmpty ? "" : "\(g.capitalized): \(items.joined(separator: ", "))"
        }.filter { !$0.isEmpty }
        return groups.joined(separator: "\n\n")
    }

    // MARK: Changing

    static func setVolume(_ i: Info, _ v: Int) async throws {
        try await soap(i.rc, rcType, "SetVolume", [("Channel", "Master"), ("DesiredVolume", "\(max(0, min(100, v)))")])
    }
    static func setMute(_ i: Info, _ on: Bool) async throws {
        try await soap(i.rc, rcType, "SetMute", [("Channel", "Master"), ("DesiredMute", on ? "1" : "0")])
    }
    static func selectPreset(_ i: Info, _ name: String) async throws {
        try await soap(i.rc, rcType, "SelectPreset", [("PresetName", name)])
    }
    static func setPicture(_ i: Info, _ name: String, _ v: Int) async throws {
        try await soap(i.rc, rcType, "Set\(name)", [("Desired\(name)", "\(v)")])
    }
    static func transport(_ i: Info, _ cmd: String) async throws {
        switch cmd {
        case "play": try await soap(i.avt, avtType, "Play", [("Speed", "1")])
        case "pause": try await soap(i.avt, avtType, "Pause")
        case "stop": try await soap(i.avt, avtType, "Stop")
        case "next": try await soap(i.avt, avtType, "Next")
        case "previous": try await soap(i.avt, avtType, "Previous")
        default: throw AppError("Command not allowed.")
        }
    }
    static func seek(_ i: Info, _ sec: Int) async throws {
        try await soap(i.avt, avtType, "Seek", [("Unit", "REL_TIME"), ("Target", hms(sec))])
    }
    static func setPlayMode(_ i: Info, _ mode: String) async throws {
        try await soap(i.avt, avtType, "SetPlayMode", [("NewPlayMode", mode)])
    }

    // MARK: Time

    static func seconds(_ t: String) -> Int {
        let main = t.split(separator: ".").first.map(String.init) ?? ""
        let p = main.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return 0 }
        return p[0] * 3600 + p[1] * 60 + p[2]
    }
    static func hms(_ s: Int) -> String { String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    static func short(_ s: Int) -> String {
        s >= 3600 ? hms(s) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func niceName(_ p: String) -> String {
        if p == "FactoryDefaults" { return "Factory defaults" }
        return p.replacingOccurrences(of: "_", with: " ")
    }

    static let playModes: [[String]] = [
        ["NORMAL", "Off"], ["REPEAT_ONE", "Repeat one"], ["REPEAT_ALL", "Repeat all"],
        ["SHUFFLE", "Shuffle and repeat"], ["SHUFFLE_NOREPEAT", "Shuffle"]
    ]
}

// MARK: - Volume, now playing, sound mode (shared by the TV screen and the cast screen)

struct RendererPanel: View {
    let info: Renderer.Info
    @ObservedObject var runner: Runner
    @State private var st = Renderer.State()
    @State private var vol = 0.0
    @State private var draggingVol = false
    @State private var pos = 0.0
    @State private var draggingPos = false
    @State private var lastChange = Date.distantPast
    @State private var presets: [String] = []
    @State private var preset = ""

    private var muted: Bool { st.muted ?? false }

    var body: some View {
        Group {
            if !info.rc.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: muted ? "speaker.slash.fill" : volIcon)
                            .font(.title3).frame(width: 30)
                            .foregroundStyle(muted ? .red : Theme.gold)
                        Slider(value: $vol, in: 0...100, step: 1, onEditingChanged: { editing in
                            draggingVol = editing
                            if !editing { setVol(Int(vol)) }
                        })
                        Text(st.volume == nil ? "–" : "\(Int(vol))")
                            .font(.body.monospacedDigit().weight(.semibold)).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    HStack {
                        Spacer()
                        RemoteKey(icon: "speaker.minus.fill", label: "Down", size: 54, repeats: true) { step(-1) }
                        Spacer()
                        RemoteKey(icon: muted ? "speaker.wave.2.fill" : "speaker.slash.fill", label: muted ? "Unmute" : "Mute", size: 54,
                                  tint: muted ? Color.red.opacity(0.2) : Color(.secondarySystemBackground)) { toggleMute() }
                        Spacer()
                        RemoteKey(icon: "speaker.plus.fill", label: "Up", size: 54, repeats: true) { step(1) }
                        Spacer()
                    }
                    if presets.count > 1 {
                        Menu {
                            ForEach(presets, id: \.self) { p in
                                Button(Renderer.niceName(p)) { choosePreset(p) }
                            }
                        } label: {
                            HStack {
                                Label("Sound mode", systemImage: "waveform")
                                Spacer()
                                Text(preset.isEmpty ? "Choose" : Renderer.niceName(preset)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("TV volume")
                } footer: {
                    Text("This is the TV's own volume, so it works on any input, HDMI included.")
                }
            }

            if !info.avt.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(st.title.isEmpty ? (st.playing ? "Something is playing" : "Nothing sent to the TV") : st.title)
                            .font(.headline).lineLimit(2)
                        Text(stateText).font(.caption).foregroundStyle(.secondary)
                    }
                    if st.duration > 0 {
                        VStack(spacing: 2) {
                            Slider(value: $pos, in: 0...Double(max(st.duration, 1)), onEditingChanged: { editing in
                                draggingPos = editing
                                if !editing { seek(Int(pos)) }
                            })
                            HStack {
                                Text(Renderer.short(Int(pos)))
                                Spacer()
                                Text("-" + Renderer.short(max(0, st.duration - Int(pos))))
                            }
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        RemoteKey(icon: "backward.end.fill", size: 46) { transport("previous") }
                        Spacer()
                        RemoteKey(icon: "gobackward.10", size: 46) { jump(-10) }
                        Spacer()
                        RemoteKey(icon: st.playing ? "pause.fill" : "play.fill", size: 60, tint: Theme.gold.opacity(0.25), fg: Theme.gold) {
                            transport(st.playing ? "pause" : "play")
                        }
                        Spacer()
                        RemoteKey(icon: "goforward.10", size: 46) { jump(10) }
                        Spacer()
                        RemoteKey(icon: "forward.end.fill", size: 46) { transport("next") }
                        Spacer()
                    }
                    HStack {
                        Button(role: .destructive) { transport("stop") } label: { Label("Stop", systemImage: "stop.fill") }
                        Spacer()
                        if !st.playMode.isEmpty {
                            Picker("Repeat", selection: Binding(get: { st.playMode }, set: { m in setMode(m) })) {
                                ForEach(modes, id: \.self) { m in
                                    Text(Renderer.playModes.first(where: { $0[0] == m })?[1] ?? m.capitalized).tag(m)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Now playing")
                } footer: {
                    Text("Works for things sent to the TV by DLNA (this app, Home Assistant, other phones). Apps running on the TV itself usually don't show here.")
                }
            }
        }
        .task(id: info) {
            presets = await Renderer.presets(info)
            while !Task.isCancelled {
                let s = await Renderer.state(info)
                let quiet = Date().timeIntervalSince(lastChange) > 2.5
                if quiet || st.volume == nil {
                    if !draggingVol, let v = s.volume { vol = Double(v) }
                    st.volume = s.volume ?? st.volume
                    st.muted = s.muted ?? st.muted
                }
                st.transport = s.transport
                st.title = s.title
                st.duration = s.duration
                st.playMode = quiet ? s.playMode : st.playMode
                if !draggingPos && quiet { pos = Double(min(s.position, max(s.duration, 0))) }
                st.position = s.position
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var volIcon: String { vol < 1 ? "speaker.fill" : vol < 34 ? "speaker.wave.1.fill" : vol < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill" }

    private var modes: [String] {
        var m = Renderer.playModes.map { $0[0] }
        if !st.playMode.isEmpty && !m.contains(st.playMode) { m.append(st.playMode) }
        return m
    }

    private var stateText: String {
        switch st.transport {
        case "PLAYING": return "Playing"
        case "PAUSED_PLAYBACK", "PAUSED_RECORDING": return "Paused"
        case "STOPPED": return "Stopped"
        case "TRANSITIONING": return "Loading…"
        case "NO_MEDIA_PRESENT": return "Idle"
        case "": return "Checking…"
        default: return st.transport.capitalized
        }
    }

    private func setVol(_ v: Int) {
        lastChange = Date()
        st.volume = v
        let i = info
        runner.fire { try await Renderer.setVolume(i, v) }
    }

    private func step(_ d: Int) {
        let v = max(0, min(100, Int(vol) + d))
        vol = Double(v)
        setVol(v)
    }

    private func toggleMute() {
        lastChange = Date()
        let target = !muted
        st.muted = target
        let i = info
        runner.fire { try await Renderer.setMute(i, target) }
    }

    private func choosePreset(_ p: String) {
        preset = p
        let i = info
        runner.fire("Sound mode: \(Renderer.niceName(p))") { try await Renderer.selectPreset(i, p) }
    }

    private func transport(_ cmd: String) {
        lastChange = Date()
        if cmd == "play" { st.transport = "PLAYING" } else if cmd == "pause" { st.transport = "PAUSED_PLAYBACK" }
        let i = info
        runner.fire { try await Renderer.transport(i, cmd) }
    }

    private func seek(_ s: Int) {
        lastChange = Date()
        pos = Double(s)
        let i = info
        runner.fire { try await Renderer.seek(i, s) }
    }

    private func jump(_ d: Int) {
        guard st.duration > 0 else { runner.show("Nothing with a timeline is playing.", error: true); return }
        seek(max(0, min(st.duration, Int(pos) + d)))
    }

    private func setMode(_ m: String) {
        lastChange = Date()
        st.playMode = m
        let i = info
        runner.fire { try await Renderer.setPlayMode(i, m) }
    }
}

// MARK: - Advanced: picture settings and details

struct RendererPicture: View {
    let info: Renderer.Info
    @ObservedObject var runner: Runner
    @State private var values: [String: Double] = [:]
    @State private var loaded = false
    static let names = ["Brightness", "Contrast", "Sharpness"]

    var body: some View {
        Section {
            if !loaded {
                HStack { ProgressView(); Text("Asking the TV…").foregroundStyle(.secondary) }
            } else if values.isEmpty {
                Text("This TV doesn't let other devices change its picture.").foregroundStyle(.secondary)
            }
            ForEach(Self.names.filter { values[$0] != nil }, id: \.self) { n in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(n)
                        Spacer()
                        Text("\(Int(values[n] ?? 0))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { values[n] ?? 0 }, set: { values[n] = $0 }), in: 0...100, step: 1, onEditingChanged: { editing in
                        if !editing {
                            let v = Int(values[n] ?? 0), i = info
                            runner.fire { try await Renderer.setPicture(i, n, v) }
                        }
                    })
                }
            }
        } header: {
            Text("Picture")
        }
        .task(id: info) {
            guard !info.rc.isEmpty else { loaded = true; return }
            var v: [String: Double] = [:]
            for n in Self.names {
                if let x = await Renderer.picture(info, n) { v[n] = Double(x) }
            }
            values = v
            loaded = true
        }
    }
}

struct RendererAbout: View {
    let info: Renderer.Info
    @ObservedObject var runner: Runner
    @State private var formats = ""

    var body: some View {
        Section("Renderer") {
            if !info.maker.isEmpty { LabeledContent("Made by", value: info.maker) }
            if !info.model.isEmpty { LabeledContent("Model", value: info.model) }
            LabeledContent("Volume control", value: info.rc.isEmpty ? "No" : "Yes")
            LabeledContent("Playback control", value: info.avt.isEmpty ? "No" : "Yes")
            if !info.cm.isEmpty {
                Button { Task { if let r = await runner.run(nil, { try await Renderer.formats(info) }) { formats = r; runner.note = nil } } } label: {
                    Label("What it can play", systemImage: "film.stack")
                }
                if !formats.isEmpty { InfoText(text: formats) }
            }
        }
    }
}

// MARK: - The TV's own screen (Devices tab)

struct DlnaTVView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var info: Renderer.Info?
    @State private var failed = ""
    @State private var advanced = false

    var body: some View {
        Form {
            Section { DeviceHeader(device: device) }
            if let info {
                RendererPanel(info: info, runner: runner)
                if !info.avt.isEmpty {
                    Section {
                        NavigationLink {
                            CastTargetView(target: CastTarget(ip: device.ip, name: device.name, avt: info.avt, rc: info.rc), showRenderer: false)
                        } label: {
                            Label("Send photos, videos or my screen", systemImage: "airplayvideo")
                        }
                    }
                }
            } else if !failed.isEmpty {
                Section {
                    Label(failed, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again") { Task { await load() } }
                }
            } else {
                Section { HStack { ProgressView(); Text("Connecting to the TV…").foregroundStyle(.secondary) } }
            }
            AdvancedToggle(on: $advanced)
            if advanced {
                if let info {
                    RendererPicture(info: info, runner: runner)
                    RendererAbout(info: info, runner: runner)
                }
                NetworkChecks(ip: device.ip, runner: runner)
            }
        }
        .notes(runner)
        .task { if info == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        failed = ""
        do {
            let i = try await Renderer.find(device.ip)
            withAnimation { info = i }
        } catch {
            withAnimation { failed = error.localizedDescription }
        }
    }
}
