import Foundation

/// Samsung TVs: the websocket remote on port 8002 (2016 and newer) and the legacy remote on TCP 55000.
/// Ported from Tool-App.ps1. Pairing tokens and MAC addresses are saved on the phone.
actor Samsung {
    static let shared = Samsung()

    private var ws: URLSessionWebSocketTask?
    private var wsIp = ""
    private var used = Date.distantPast
    private var modes: [String: (mode: String, at: Date)] = [:]

    // MARK: Websocket connection

    private func closeSocket() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    private func open(_ ip: String) async throws -> URLSessionWebSocketTask {
        let name = Data("MrLTTecControl".utf8).base64EncodedString()
        let tok = Store.get("samsungTokens", ip)
        var s = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if !tok.isEmpty { s += "&token=\(tok)" }
        guard let url = URL(string: s) else { throw AppError("Bad address.") }
        let task = Http.shared.wsSession.webSocketTask(with: url)
        task.resume()
        // The first message says whether the TV accepted us. On first use it waits until you press Allow on the TV.
        guard let first = await wsReceive(task, timeout: 15) else {
            task.cancel()
            let up = (try? await blocking { LowNet.tcpOpen(ip, 8002, timeoutMs: 800) }) ?? false
            throw AppError(up ? "The TV did not answer. If it is showing an Allow prompt, choose Allow and try again."
                              : "The TV did not answer. Is it on?")
        }
        let j = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any]
        let event = j?["event"] as? String ?? ""
        switch event {
        case "ms.channel.connect":
            if let nt = (j?["data"] as? [String: Any])?["token"] as? String,
               nt.wholeMatch(of: #/[A-Za-z0-9]+/#) != nil, nt != tok {
                Store.set("samsungTokens", ip, nt)
            }
        case "ms.channel.unauthorized":
            Store.set("samsungTokens", ip, "")
            task.cancel()
            throw AppError("The TV did not allow this app. Choose Allow on the TV when it asks, then try again.")
        case "ms.channel.timeout":
            task.cancel()
            throw AppError("The TV timed out waiting for you. Try again and choose Allow on the TV.")
        default:
            break
        }
        return task
    }

    private func socket(_ ip: String) async throws -> URLSessionWebSocketTask {
        if let ws, wsIp == ip, ws.state == .running, Date().timeIntervalSince(used) < 45 { return ws }
        closeSocket()
        let t = try await open(ip)
        ws = t; wsIp = ip; used = Date()
        return t
    }

    private func send(_ ip: String, _ json: String) async throws {
        do {
            try await socket(ip).send(.string(json))
        } catch let e as AppError {
            throw e
        } catch {
            closeSocket()   // the old connection went stale: reconnect once
            do { try await socket(ip).send(.string(json)) }
            catch let e as AppError { throw e }
            catch { throw AppError("The TV closed the connection.") }
        }
        used = Date()
    }

    private func apps(_ ip: String) async throws -> String {
        let s = try await socket(ip)
        try await s.send(.string("{\"method\":\"ms.channel.emit\",\"params\":{\"event\":\"ed.installedApp.get\",\"to\":\"host\"}}"))
        var list: [[String: Any]]?
        let end = Date().addingTimeInterval(10)
        while Date() < end, list == nil {
            guard let m = await wsReceive(s, timeout: 4) else { closeSocket(); break }
            guard let j = (try? JSONSerialization.jsonObject(with: Data(m.utf8))) as? [String: Any],
                  j["event"] as? String == "ed.installedApp.get" else { continue }
            let inner = (j["data"] as? [String: Any])?["data"]
            if let a = inner as? [[String: Any]] { list = a }
            else if let str = inner as? String, let a = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [[String: Any]] { list = a }
            else { list = [] }
        }
        used = Date()
        guard let list else { throw AppError("The TV did not send its app list. Some Samsung TVs do not allow this.") }
        return list.compactMap { a -> (String, String)? in
            guard let id = a["appId"] as? String, id.wholeMatch(of: #/[A-Za-z0-9._-]{3,64}/#) != nil else { return nil }
            let n = (a["name"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "|", with: " ")
            return (id, n)
        }
        .sorted { $0.1 < $1.1 }
        .map { "\($0.0)|\($0.1)" }
        .joined(separator: "\n")
    }

    private func info(_ ip: String) async throws -> String {
        let j = try await Http.json("http://\(ip):8001/api/v2/")
        let d = j["device"] as? [String: Any] ?? [:]
        var lines: [String] = []
        for (label, key) in [("Name", "name"), ("Model", "modelName"), ("Type", "type"), ("OS", "OS"), ("Power", "PowerState"),
                             ("Resolution", "resolution"), ("Network", "networkType"), ("Country", "countryCode")] {
            if let v = d[key], !"\(v)".isEmpty { lines.append("\(label): \(v)") }
        }
        if let mac = d["wifiMac"] as? String, mac.wholeMatch(of: #/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/#) != nil, Store.get("samsungMacs", ip).isEmpty {
            Store.set("samsungMacs", ip, mac.uppercased())
        }
        lines.append("Pairing saved: " + (Store.get("samsungTokens", ip).isEmpty ? "no" : "yes"))
        let mac = Store.get("samsungMacs", ip)
        lines.append(mac.isEmpty ? "MAC address: not known yet" : "MAC address: \(mac)")
        return lines.joined(separator: "\n")
    }

    // MARK: Older TVs (port 55000)

    private func mode(_ ip: String) async -> String {
        if let m = modes[ip], Date().timeIntervalSince(m.at) < 30 { return m.mode }
        let r = (try? await blocking { LowNet.tcpSweep([(ip, 8002), (ip, 8001), (ip, 55000)], timeoutMs: 600) }) ?? LowNet.SweepResult()
        let legacy = !r.open.contains("\(ip):8002") && !r.open.contains("\(ip):8001") && r.open.contains("\(ip):55000")
        let mode = legacy ? "legacy" : "modern"
        modes[ip] = (mode, Date())
        return mode
    }

    private static func part(_ text: String) -> [UInt8] {
        let b = [UInt8](Data(text.utf8).base64EncodedString().utf8)
        return [UInt8(b.count), 0] + b
    }
    private static func raw(_ d: [UInt8]) -> [UInt8] { [UInt8(d.count), 0] + d }

    private static func readReply(_ s: LowNet.Stream) throws -> [UInt8] {
        let h = try s.read(3)
        let nameLen = Int(h[1]) + 256 * Int(h[2])
        if nameLen > 0 { _ = try s.read(nameLen) }
        let l = try s.read(2)
        let n = Int(l[0]) + 256 * Int(l[1])
        if n == 0 { return [] }
        return try s.read(n)
    }

    private static func sendLegacy(_ ip: String, _ key: String) throws {
        guard key.wholeMatch(of: #/KEY_[A-Z0-9_]+/#) != nil else { throw AppError("Key not allowed.") }
        let s: LowNet.Stream
        do { s = try LowNet.Stream(ip, 55000, connectMs: 4000) }
        catch { throw AppError("The TV did not answer on port 55000. Is it fully on?") }
        s.setTimeout(30000)
        let payload: [UInt8] = [0x64, 0x00] + part("MrLTTec Control") + part("") + part("MrLTTec")
        try s.write([0, 0, 0] + raw(payload))
        while true {
            let r = try readReply(s)
            if r.count >= 4, r[0] == 0x64, r[1] == 0, r[2] == 1, r[3] == 0 { break }
            if r.count >= 4, r[0] == 0x64, r[2] == 0 { throw AppError("The TV refused this app. Check the TV settings for blocked or denied remote devices, then try again.") }
            if r.first == 0x65 { throw AppError("The TV cancelled the pairing (the Allow prompt timed out or was dismissed). Press a button again and accept it on the TV.") }
            if r.first == 0x0a { continue }
            throw AppError("The TV sent an answer this app does not understand.")
        }
        let kp: [UInt8] = [0, 0, 0] + part(key)
        try s.write([0, 0, 0] + raw(kp))
        s.setTimeout(800)
        _ = try? readReply(s)
        usleep(150_000)
    }

    // MARK: Entry point (same commands as /samsung on the PC)

    func run(_ ip: String, _ key: String, _ arg: String) async throws -> String {
        if key != "wake" && key != "mac", await mode(ip) == "legacy" {
            if key.wholeMatch(of: #/KEY_[A-Z0-9_]+/#) != nil {
                try await blocking { try Samsung.sendLegacy(ip, key) }
                return ""
            }
            switch key {
            case "info": return "Older Samsung TV (remote control on port 55000). This kind of TV only accepts remote keys, so there is no app list, typing or model info."
            case "repair": return "Older Samsung TVs keep the pairing themselves. To make the TV ask again, remove this app from the TV's external device or remote access permissions (the menu name varies by model)."
            default: throw AppError("This older Samsung only accepts remote keys. Apps, typing and the app list are not available on it.")
            }
        }
        switch key {
        case "info":
            return try await info(ip)
        case "repair":
            closeSocket()
            Store.set("samsungTokens", ip, "")
            return "Saved pairing forgotten. The next key you press will ask the TV to Allow again."
        case "apps":
            return try await apps(ip)
        case "mac":
            if !arg.isEmpty {
                guard arg.wholeMatch(of: #/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/#) != nil else {
                    throw AppError("That does not look like a MAC address. Example: AA:BB:CC:DD:EE:FF")
                }
                let m = arg.uppercased().replacingOccurrences(of: "-", with: ":")
                Store.set("samsungMacs", ip, m)
                return "Saved MAC address \(m) for this TV."
            }
            if Store.get("samsungMacs", ip).isEmpty { _ = try? await info(ip) }
            let m = Store.get("samsungMacs", ip)
            return m.isEmpty ? "No MAC address saved for this TV yet. iPhones cannot read MAC addresses from the network, so type it in the MAC box (on the TV: Settings > General > About This TV, or Network Status)." : "MAC address for this TV: \(m)"
        case "wake":
            var m = Store.get("samsungMacs", ip)
            if m.isEmpty { _ = try? await info(ip); m = Store.get("samsungMacs", ip) }
            if m.isEmpty { throw AppError("No MAC address saved for this TV yet. Turn the TV on once and press Device info so the app can learn it, or type the MAC in the MAC box.") }
            try await WakeOnLan.send(ip: ip, mac: m)
            return "Wake signal sent to \(m). If the TV does not turn on, check that Wake-on-LAN (often called Power on with Mobile) is enabled in its network settings. Wi-Fi TVs often cannot be woken, and iOS can block the wake signal on some networks. It can take 10 to 30 seconds."
        default:
            break
        }
        let json: String
        if key.wholeMatch(of: #/KEY_[A-Z0-9_]+/#) != nil {
            json = "{\"method\":\"ms.remote.control\",\"params\":{\"Cmd\":\"Click\",\"DataOfCmd\":\"\(key)\",\"Option\":\"false\",\"TypeOfRemote\":\"SendRemoteKey\"}}"
        } else if key == "text" {
            guard arg.wholeMatch(of: #/[\x20-\x7E]{1,100}/#) != nil else { throw AppError("Text can only use standard keyboard characters (up to 100).") }
            let b64 = Data(arg.utf8).base64EncodedString()
            json = "{\"method\":\"ms.remote.control\",\"params\":{\"Cmd\":\"\(b64)\",\"DataOfCmd\":\"base64\",\"TypeOfRemote\":\"SendInputString\"}}"
        } else if key == "app" {
            guard arg.wholeMatch(of: #/[A-Za-z0-9._-]{3,64}/#) != nil else { throw AppError("App id not allowed.") }
            json = "{\"method\":\"ms.channel.emit\",\"params\":{\"event\":\"ed.apps.launch\",\"to\":\"host\",\"data\":{\"appId\":\"\(arg)\",\"action_type\":\"DEEP_LINK\"}}}"
        } else {
            throw AppError("Key not allowed.")
        }
        try await send(ip, json)
        return ""
    }
}

/// Waits for one text message. On timeout or error it cancels the socket (the caller then drops it).
func wsReceive(_ ws: URLSessionWebSocketTask, timeout: Double) async -> String? {
    await withTaskGroup(of: String?.self) { g in
        g.addTask {
            do {
                switch try await ws.receive() {
                case .string(let s): return s
                case .data(let d): return String(decoding: d, as: UTF8.self)
                @unknown default: return nil
                }
            } catch { return nil }
        }
        g.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await g.next() ?? nil
        if first == nil { ws.cancel(with: .goingAway, reason: nil) }
        g.cancelAll()
        return first
    }
}
