import SwiftUI

/// Fire TV by PIN: the Fire TV Remote app's own service on HTTPS port 8080 (no ADB needed).
/// Unofficial, worked out by the community. Ported from Tool-App.ps1. Pairing token is saved per TV.
enum FireTV {
    static let actions = ["up": "dpad_up", "down": "dpad_down", "left": "dpad_left", "right": "dpad_right", "ok": "select",
                          "home": "home", "back": "back", "menu": "menu", "sleep": "sleep"]

    struct Answer { let code: Int; let body: String }

    private static func call(_ ip: String, _ path: String, _ body: String, _ token: String) async -> Answer {
        var h = ["X-Api-Key": "0987654321", "User-Agent": "okhttp/4.10.0"]
        if !token.isEmpty { h["X-Client-Token"] = token }
        do {
            let r = try await Http.call("https://\(ip):8080\(path)", method: "POST", body: Data(body.utf8),
                                        contentType: body.isEmpty ? nil : "application/json; charset=utf-8", headers: h, timeout: 8)
            return Answer(code: r.status, body: r.text)
        } catch let e as HttpStatusError {
            return Answer(code: e.status, body: String(decoding: e.body, as: UTF8.self))
        } catch {
            return Answer(code: 0, body: error.localizedDescription)
        }
    }

    /// The remote service sleeps until it's woken through the TV's DIAL port.
    static func wakeService(_ ip: String) async {
        _ = try? await Http.call("http://\(ip):8009/apps/FireTVRemote", method: "POST", body: Data(), timeout: 4)
    }

    private static func ftv(_ ip: String, _ path: String, _ body: String, _ token: String) async -> Answer {
        var r = await call(ip, path, body, token)
        if r.code == 0 {
            await wakeService(ip)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            r = await call(ip, path, body, token)
        }
        return r
    }

    private static func describe(_ r: Answer) -> String {
        let msg = ((try? JSONSerialization.jsonObject(with: Data(r.body.utf8))) as? [String: Any])?["description"] as? String ?? ""
        if r.code == 0 { return "Could not reach the Fire TV on port 8080. Is it on and on this network?" }
        if r.code == 401 || r.code == 403 { return "The Fire TV didn't accept the saved pairing. Tap Show PIN on TV and pair again." }
        if !msg.isEmpty { return "The Fire TV said: \(msg)" }
        return "The Fire TV answered with HTTP \(r.code)."
    }

    static func isPaired(_ ip: String) -> Bool { !Store.get("firetv", ip).isEmpty }

    static func showPin(_ ip: String) async throws -> String {
        await wakeService(ip)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let r = await ftv(ip, "/v1/FireTV/pin/display", "{\"friendlyName\":\"MrLTTec Home\"}", "")
        guard r.code == 200 else { throw AppError(describe(r)) }
        return "A PIN should now be on the TV. Type it here and tap Pair."
    }

    static func pair(_ ip: String, pin: String) async throws -> String {
        guard pin.wholeMatch(of: #/\d{3,8}/#) != nil else { throw AppError("The PIN is the number shown on the TV.") }
        let r = await ftv(ip, "/v1/FireTV/pin/verify", "{\"pin\":\"\(pin)\"}", "")
        guard r.code == 200 else { throw AppError(describe(r)) }
        let tok = ((try? JSONSerialization.jsonObject(with: Data(r.body.utf8))) as? [String: Any])?["description"] as? String ?? ""
        guard tok.wholeMatch(of: #/[A-Za-z0-9._-]{3,200}/#) != nil else { throw AppError("The Fire TV didn't give back a pairing code. Check the PIN and try again.") }
        Store.set("firetv", ip, tok)
        return "Paired. The buttons work now."
    }

    static func forget(_ ip: String) { Store.set("firetv", ip, "") }

    static func run(_ ip: String, _ cmd: String, _ arg: String = "") async throws {
        let tok = Store.get("firetv", ip)
        guard !tok.isEmpty else { throw AppError("Not paired yet. Tap Show PIN on TV, type the PIN and tap Pair.") }
        var path = "", body = ""
        if let a = actions[cmd] { path = "/v1/FireTV?action=\(a)" }
        else if cmd == "playpause" { path = "/v1/media?action=play" }
        else if cmd == "ffwd" { path = "/v1/media?action=scan"; body = "{\"direction\":\"forward\",\"keyAction\":{\"keyActionType\":\"keyDown\"}}" }
        else if cmd == "rewind" { path = "/v1/media?action=scan"; body = "{\"direction\":\"back\",\"keyAction\":{\"keyActionType\":\"keyDown\"}}" }
        else if cmd == "text" {
            guard arg.wholeMatch(of: #/[\x20\x21\x23-\x5B\x5D-\x7E]{1,100}/#) != nil else {
                throw AppError("Text can only use standard keyboard characters, without quotes or backslashes (up to 100).")
            }
            path = "/v1/FireTV/keyboard"; body = "{\"text\":\"\(arg)\"}"
        }
        else if cmd == "app" {
            guard arg.wholeMatch(of: #/[A-Za-z0-9_.]{3,120}/#) != nil else { throw AppError("App name not allowed.") }
            path = "/v1/FireTV/app/\(arg)"
        }
        else if cmd == "wake" {
            await wakeService(ip)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            path = "/v1/FireTV?action=home"
        }
        else { throw AppError("Command not allowed.") }
        let r = await ftv(ip, path, body, tok)
        guard (200...299).contains(r.code) else { throw AppError(describe(r)) }
    }
}

struct FireTVView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var paired = false
    @State private var pin = ""
    @State private var advanced = false
    @State private var text = ""
    @State private var pkg = ""

    static let apps = [("YouTube", "com.amazon.firetv.youtube"), ("Netflix", "com.netflix.ninja"), ("Prime Video", "com.amazon.cloud9"),
                       ("Disney+", "com.disney.disneyplus"), ("Hulu", "com.hulu.plus"), ("Apple TV", "com.apple.atve.amazon.appletv")]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DeviceHeader(device: device, subtitle: paired ? "Paired · \(device.ip)" : "Not paired yet · \(device.ip)").padding(.horizontal)

                if !paired { pairCard.padding(.horizontal) }

                HStack(spacing: 22) {
                    RemoteKey(icon: "moon.fill", label: "Sleep", tint: Theme.gold.opacity(0.2), fg: Theme.gold) { key("sleep") }
                    RemoteKey(icon: "arrow.uturn.backward", label: "Back") { key("back") }
                    RemoteKey(icon: "house.fill", label: "Home") { key("home") }
                    RemoteKey(icon: "line.3.horizontal", label: "Menu") { key("menu") }
                }

                DPad { k in key(k) }

                HStack(spacing: 30) {
                    RemoteKey(icon: "backward.fill", label: "Rewind", repeats: true) { key("rewind") }
                    RemoteKey(icon: "playpause.fill", label: "Play") { key("playpause") }
                    RemoteKey(icon: "forward.fill", label: "Forward", repeats: true) { key("ffwd") }
                }

                Text("Fire TV's PIN control can't change the volume or turn the TV on. Use the TV's own remote for those.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)

                advancedSection
            }
            .padding(.vertical)
        }
        .notes(runner)
        .onAppear { paired = FireTV.isPaired(device.ip) }
    }

    private var pairCard: some View {
        Card("Pair with this Fire TV") {
            Text("Tap Show PIN on TV, then type the number the TV shows.").font(.footnote).foregroundStyle(.secondary)
            Button { Task { await runner.run { try await FireTV.showPin(device.ip) } } } label: {
                Label("Show PIN on TV", systemImage: "tv").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            HStack {
                TextField("PIN", text: $pin).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                Button("Pair") {
                    let p = pin.trimmed
                    Task {
                        if await runner.run(nil, { try await FireTV.pair(device.ip, pin: p) }) != nil {
                            withAnimation { paired = true }; pin = ""; Haptic.success()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(Self.apps.map { [$0.0, $0.1] }, id: \.self) { a in
                            Button(a[0]) { runner.fire("Opening \(a[0])") { try await FireTV.run(device.ip, "app", a[1]) } }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }
                    }
                    .font(.footnote)
                    HStack {
                        TextField("Or a package, like com.hulu.plus", text: $pkg)
                            .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Open") { let p = pkg.trimmed; runner.fire("Opening \(p)") { try await FireTV.run(device.ip, "app", p) } }
                            .buttonStyle(.bordered)
                    }
                }

                Card("Type on the TV") {
                    HStack {
                        TextField("Search text", text: $text).textFieldStyle(.roundedBorder)
                        Button("Send") { let t = text; runner.fire("Typed") { try await FireTV.run(device.ip, "text", t) } }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Card("Device") {
                    Button("Wake the remote service") { runner.fire("Woke the Fire TV") { try await FireTV.run(device.ip, "wake") } }
                    if paired {
                        Button("Pair again", role: .destructive) { FireTV.forget(device.ip); withAnimation { paired = false } }
                    }
                    PingRow(ip: device.ip, runner: runner)
                }
            }
        }
        .padding(.horizontal)
    }

    private func key(_ k: String) {
        guard paired else { runner.show("Pair first: tap Show PIN on TV.", error: true); Haptic.error(); return }
        Task { await runner.run(nil) { try await FireTV.run(device.ip, k); return "" } }
    }
}
