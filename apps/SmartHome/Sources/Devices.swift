import Foundation
import Security

// Ported from Tool-App.ps1. Messages match the PC version so the page reads the same.

// MARK: - Wemo (UPnP SOAP)

enum Wemo {
    static func body(_ action: String, _ inner: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"urn:Belkin:service:basicevent:1\">\(inner)</u:\(action)></s:Body></s:Envelope>").utf8)
    }

    static func run(_ ip: String, _ state: String) async throws {
        guard ["on", "off", "toggle"].contains(state) else { throw AppError("Command not allowed.") }
        var last = "no answer"
        for p in [49153, 49152, 49154, 49155] {
            let uri = "http://\(ip):\(p)/upnp/control/basicevent1"
            let ct = "text/xml; charset=\"utf-8\""
            do {
                var want = state
                if state == "toggle" {
                    let g = try await Http.call(uri, method: "POST", body: body("GetBinaryState", ""), contentType: ct,
                                                headers: ["SOAPAction": "\"urn:Belkin:service:basicevent:1#GetBinaryState\""], timeout: 2)
                    let cur = xmlTag(g.text, "BinaryState") ?? "0"
                    want = cur.hasPrefix("0") ? "on" : "off"
                }
                let v = want == "on" ? 1 : 0
                _ = try await Http.call(uri, method: "POST", body: body("SetBinaryState", "<BinaryState>\(v)</BinaryState>"), contentType: ct,
                                        headers: ["SOAPAction": "\"urn:Belkin:service:basicevent:1#SetBinaryState\""], timeout: 2)
                return
            } catch { last = error.localizedDescription }
        }
        throw AppError("Wemo did not respond (\(last))")
    }
}

// MARK: - WLED

enum Wled {
    static func run(_ ip: String, _ cmd: String) async throws {
        let body: String
        if cmd == "on" { body = "{\"on\":true}" }
        else if cmd == "off" { body = "{\"on\":false}" }
        else if let m = cmd.wholeMatch(of: #/bri(\d{1,3})/#) { body = "{\"on\":true,\"bri\":\(min(255, Int(m.1) ?? 0))}" }
        else { throw AppError("Command not allowed.") }
        _ = try await Http.call("http://\(ip)/json/state", method: "POST", body: Data(body.utf8), contentType: "application/json", timeout: 3)
    }
}

// MARK: - Roku (ECP on port 8060)

enum Roku {
    static let keys: Set<String> = ["Home", "Rev", "Fwd", "Play", "Select", "Left", "Right", "Down", "Up", "Back", "InstantReplay", "Info",
        "Backspace", "Search", "Enter", "FindRemote", "VolumeDown", "VolumeMute", "VolumeUp", "PowerOff", "PowerOn",
        "ChannelUp", "ChannelDown", "InputTuner", "InputHDMI1", "InputHDMI2", "InputHDMI3", "InputHDMI4", "InputAV1"]
    static let blocked = "The Roku refused that. On the Roku go to Settings > System > Advanced system settings > Control by mobile apps > Network access and set it to Enabled. (Since Roku OS 14.1, button presses need that setting; opening apps works without it.)"

    static func http(_ ip: String, _ path: String, _ method: String = "POST") async throws -> Http.Result {
        do { return try await Http.call("http://\(ip):8060\(path)", method: method, timeout: 3) }
        catch let e as HttpStatusError {
            if e.status == 401 || e.status == 403 { throw AppError(blocked) }
            throw AppError("The Roku returned HTTP \(e.status).")
        } catch { throw AppError("The Roku did not answer. Is it on and on this network?") }
    }

    static func run(_ ip: String, _ cmd: String, _ arg: String) async throws -> String {
        if keys.contains(cmd) { _ = try await http(ip, "/keypress/\(cmd)"); return "" }
        switch cmd {
        case "text":
            guard (1...100).contains(arg.count) else { throw AppError("Type 1 to 100 characters.") }
            if arg.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value > 0xFFFF }) {
                throw AppError("That text has characters the Roku keyboard cannot take (no emoji or control characters).")
            }
            for ch in arg {
                let enc = String(ch).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                _ = try await http(ip, "/keypress/Lit_\(enc)")
            }
            return ""
        case "app":
            guard arg.wholeMatch(of: #/[A-Za-z0-9._-]{1,60}/#) != nil else { throw AppError("App id not allowed.") }
            _ = try await http(ip, "/launch/\(arg)")
            return ""
        case "apps":
            let x = try await http(ip, "/query/apps", "GET").text
            var list: [[String: String]] = []
            for m in x.matches(of: #/<app\s+([^>]*)>([^<]*)</app>/#) {
                let attrs = String(m.1)
                func attr(_ n: String) -> String {
                    if let a = attrs.firstMatch(of: try! Regex("\(n)=\"([^\"]*)\"")) { return String(a.output[1].substring ?? "") }
                    return ""
                }
                list.append(["id": attr("id"), "name": xmlUnescape(String(m.2)), "type": attr("type")])
            }
            let d = try JSONSerialization.data(withJSONObject: list)
            return String(decoding: d, as: UTF8.self)
        case "active":
            let x = try await http(ip, "/query/active-app", "GET").text
            var name = xmlTag(x, "app") ?? "Home screen"
            if let ss = xmlTag(x, "screensaver") { name += " (screensaver: \(ss))" }
            return "Open now: \(name)"
        case "info":
            let x = try await http(ip, "/query/device-info", "GET").text
            guard x.contains("<device-info") else { throw AppError("The Roku answered, but not with device info.") }
            let fields = [("Name", "user-device-name"), ("Model", "model-name"), ("Model number", "model-number"), ("Roku OS", "software-version"),
                          ("Power", "power-mode"), ("Roku TV", "is-tv"), ("Network", "network-type"), ("Wi-Fi name", "network-name"), ("Serial", "serial-number")]
            return fields.compactMap { f in xmlTag(x, f.1).map { "\(f.0): \($0)" } }.joined(separator: "\n")
        default:
            throw AppError("Command not allowed.")
        }
    }

    static func icon(_ ip: String, _ id: String) async throws -> Http.Result {
        guard id.wholeMatch(of: #/[A-Za-z0-9._-]{1,60}/#) != nil else { throw AppError("App id not allowed.") }
        return try await http(ip, "/query/icon/\(id)", "GET")
    }
}

// MARK: - WiZ (UDP 38899)

enum Wiz {
    static let noAnswer = "The light did not answer. Is it powered on (check the wall switch) and on this network? If so, look in the WiZ app for a setting like \"Allow local communication\" and turn it on."

    static func ask(_ ip: String, _ json: String, waitMs: Int = 1000) async -> [String: Any]? {
        let d = try? await blocking { LowNet.udpAsk(ip, port: 38899, Data(json.utf8), waitMs: waitMs) }
        guard let d = d ?? nil else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func pilot(_ ip: String) async throws -> [String: Any] {
        guard let j = await ask(ip, "{\"method\":\"getPilot\",\"params\":{}}") else { throw AppError(noAnswer) }
        guard let r = j["result"] as? [String: Any] else { throw AppError("The light sent an answer this app could not read.") }
        return r
    }

    static func info(_ ip: String) async throws -> String {
        let p = try await pilot(ip)
        var lines = ["Power: " + ((p["state"] as? Bool) == true ? "on" : "off")]
        for (label, key) in [("Brightness (%)", "dimming"), ("Color temperature (K)", "temp"), ("Scene id", "sceneId"), ("Red", "r"),
                             ("Green", "g"), ("Blue", "b"), ("Signal (dBm)", "rssi"), ("MAC", "mac")] {
            if let v = p[key] { lines.append("\(label): \(v)") }
        }
        if let c = (await ask(ip, "{\"method\":\"getSystemConfig\",\"params\":{}}"))?["result"] as? [String: Any] {
            if let v = c["moduleName"] { lines.append("Module: \(v)") }
            if let v = c["fwVersion"] { lines.append("Firmware: \(v)") }
        }
        return lines.joined(separator: "\n")
    }

    static func run(_ ip: String, _ cmd: String, _ arg: String) async throws -> String {
        var params: String
        if cmd == "on" { params = "{\"state\":true}" }
        else if cmd == "off" { params = "{\"state\":false}" }
        else if cmd == "toggle" {
            let cur = try await pilot(ip)
            params = (cur["state"] as? Bool) == true ? "{\"state\":false}" : "{\"state\":true}"
        }
        else if let m = cmd.wholeMatch(of: #/bri(\d{1,3})/#) { params = "{\"state\":true,\"dimming\":\(max(10, min(100, Int(m.1) ?? 100)))}" }
        else if let m = cmd.wholeMatch(of: #/temp(\d{4})/#) { params = "{\"state\":true,\"temp\":\(max(2200, min(6500, Int(m.1) ?? 4000)))}" }
        else if let m = cmd.wholeMatch(of: #/scene(\d{1,4})/#) { params = "{\"state\":true,\"sceneId\":\(Int(m.1) ?? 1)}" }
        else if cmd == "color" {
            guard let m = arg.wholeMatch(of: #/(\d{1,3}),(\d{1,3}),(\d{1,3})/#),
                  let r = Int(m.1), let g = Int(m.2), let b = Int(m.3) else { throw AppError("Color must look like 255,128,0.") }
            if r > 255 || g > 255 || b > 255 { throw AppError("Color values go from 0 to 255.") }
            if r + g + b == 0 { throw AppError("Pick a color (black is the same as off).") }
            params = "{\"state\":true,\"r\":\(r),\"g\":\(g),\"b\":\(b)}"
        }
        else if cmd == "info" { return try await info(ip) }
        else { throw AppError("Command not allowed.") }
        guard let j = await ask(ip, "{\"method\":\"setPilot\",\"params\":\(params)}") else { throw AppError(noAnswer) }
        if let e = j["error"] as? [String: Any] { throw AppError("The light refused that: \(e["message"] ?? "error")") }
        return ""
    }

    /// WiZ has no TCP ports, so ask every address on the network (and the broadcast address) over UDP.
    static func find() async -> [[String: String]] {
        let ips = LowNet.subnetIps()
        if ips.isEmpty { return [] }
        let bcasts = Set(ips.map { $0.split(separator: ".").prefix(3).joined(separator: ".") + ".255" })
        let pilotMsg = Data("{\"method\":\"getPilot\",\"params\":{}}".utf8)
        let replies = (try? await blocking { LowNet.udpSweep(ips, port: 38899, payloads: [pilotMsg], waitMs: 1500, repeats: 2, broadcast: Array(bcasts)) }) ?? []
        var found: [String: [String: Any]] = [:]
        for (ip, d) in replies where isPrivateIp(ip) {
            if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = j["result"] as? [String: Any] { found[ip] = r }
        }
        var out: [[String: String]] = []
        for ip in found.keys.sorted(by: ipLess) {
            let r = found[ip]!
            let st = (r["state"] as? Bool).map { $0 ? " - on" : " - off" } ?? ""
            let mac = r["mac"] as? String ?? ""
            let mod = ((await ask(ip, "{\"method\":\"getSystemConfig\",\"params\":{}}", waitMs: 500))?["result"] as? [String: Any])?["moduleName"] as? String ?? ""
            if mod.uppercased().contains("SOCKET") {
                out.append(["ip": ip, "type": "wizplug", "name": "WiZ outlet", "detail": "MAC \(mac)\(st)"])
            } else {
                out.append(["ip": ip, "type": "wiz", "name": "WiZ light", "detail": "MAC \(mac)\(st)"])
            }
        }
        return out
    }
}

// MARK: - Xbox (SmartGlass discovery / power-on, UDP 5050)

enum Xbox {
    static let discovery = Data([0xDD, 0x00, 0x00, 0x0A, 0x00, 0x00, 0, 0, 0, 0, 0x00, 0x08, 0x00, 0x00, 0x00, 0x02])

    struct Console { let ip: String; let name: String; let liveId: String }

    private static func sgString(_ b: [UInt8], _ pos: inout Int) -> String {
        guard pos + 2 <= b.count else { pos = b.count; return "" }
        let n = Int(b[pos]) * 256 + Int(b[pos + 1])
        guard pos + 2 + n <= b.count else { pos = b.count; return "" }
        let s = String(decoding: b[(pos + 2)..<(pos + 2 + n)], as: UTF8.self)
        pos += 2 + n + 1
        return s
    }

    static func parse(_ ip: String, _ d: Data) -> Console? {
        let b = [UInt8](d)
        guard b.count >= 12, b[0] == 0xDD, b[1] == 0x01 else { return nil }
        var pos = 6 + 4 + 2
        guard pos + 2 <= b.count else { return Console(ip: ip, name: "Xbox", liveId: "") }
        let name = sgString(b, &pos)
        guard pos + 2 <= b.count else { return Console(ip: ip, name: cleanName(name), liveId: "") }
        _ = sgString(b, &pos)        // uuid
        pos += 4                     // last error
        var live = ""
        if pos + 2 <= b.count {
            let cl = Int(b[pos]) * 256 + Int(b[pos + 1])
            if pos + 2 + cl <= b.count, let cert = SecCertificateCreateWithData(nil, Data(b[(pos + 2)..<(pos + 2 + cl)]) as CFData) {
                var cn: CFString?
                if SecCertificateCopyCommonName(cert, &cn) == errSecSuccess, let cn { live = cleanName(cn as String) }
            }
        }
        if !live.isEmpty, isPrivateIp(ip) { Store.set("xbox", ip, live) }
        return Console(ip: ip, name: cleanName(name).isEmpty ? "Xbox" : cleanName(name), liveId: live)
    }

    static func find(_ targets: [String], waitMs: Int = 1500) async -> [Console] {
        let replies = (try? await blocking {
            LowNet.udpSweep(targets, port: 5050, payloads: [discovery], waitMs: waitMs, repeats: 3, broadcast: ["255.255.255.255"])
        }) ?? []
        var seen: [String: Console] = [:]
        for (ip, d) in replies where seen[ip] == nil { if let c = parse(ip, d) { seen[ip] = c } }
        return Array(seen.values)
    }

    static func run(_ ip: String, _ cmd: String, _ arg: String) async throws -> String {
        switch cmd {
        case "status":
            if let x = await find([ip]).first(where: { $0.ip == ip }) {
                return "On: \(x.name) answered." + (x.liveId.isEmpty ? "" : " Live ID \(x.liveId) is saved, so Turn on works from now on.")
            }
            return "The Xbox did not answer. It is off, asleep, unplugged or not at this address. (A sleeping Xbox can still be turned on if its Live ID is saved.)"
        case "info":
            let id = Store.get("xbox", ip)
            return id.isEmpty ? "No Live ID saved for this Xbox yet. Press Is it on? while the Xbox is on, or type it from Settings > System > Console info." : "Live ID saved: \(id)"
        case "setid":
            let id = arg.trimmingCharacters(in: .whitespaces).uppercased()
            if !id.isEmpty && id.wholeMatch(of: #/[0-9A-Z]{8,32}/#) == nil {
                throw AppError("That does not look like a Live ID. It is letters and numbers only, for example FD00112233445566.")
            }
            Store.set("xbox", ip, id)
            return id.isEmpty ? "Live ID removed." : "Live ID \(id) saved."
        case "on":
            var id = Store.get("xbox", ip)
            if id.isEmpty, let x = await find([ip], waitMs: 1000).first(where: { $0.ip == ip && !$0.liveId.isEmpty }) { id = x.liveId }
            if id.isEmpty { throw AppError("The Live ID of this Xbox is not saved yet. Turn the Xbox on once and press Is it on?, or type the Live ID below (Settings > System > Console info on the Xbox).") }
            let idb = [UInt8](id.utf8)
            let len = 2 + idb.count + 1
            var pkt = [UInt8](repeating: 0, count: 6 + len)
            pkt[0] = 0xDD; pkt[1] = 0x02; pkt[2] = UInt8(len >> 8); pkt[3] = UInt8(len & 255)
            pkt[6] = UInt8(idb.count >> 8); pkt[7] = UInt8(idb.count & 255)
            for (i, v) in idb.enumerated() { pkt[8 + i] = v }
            let data = Data(pkt)
            _ = try await blocking { LowNet.udpSend(data, to: ["255.255.255.255", ip], ports: [5050], times: 5, gapMs: 100) }
            return "Turn on sent. The Xbox needs its power mode set to Sleep to wake this way. It takes a few seconds."
        default:
            throw AppError("Unknown Xbox command.")
        }
    }
}

// MARK: - Wake-on-LAN

enum WakeOnLan {
    static func send(ip: String?, mac: String) async throws {
        let hex = mac.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        guard hex.count == 12 else { throw AppError("Type the MAC address like AA:BB:CC:DD:EE:FF.") }
        var mb: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex, mb.count < 6 {
            let j = hex.index(i, offsetBy: 2)
            guard let v = UInt8(hex[i..<j], radix: 16) else { throw AppError("Type the MAC address like AA:BB:CC:DD:EE:FF.") }
            mb.append(v); i = j
        }
        guard mb.count == 6 else { throw AppError("Type the MAC address like AA:BB:CC:DD:EE:FF.") }
        var pkt = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { pkt += mb }
        var dests = ["255.255.255.255"]
        let nets = ip.map { [$0] } ?? LowNet.localAddrs()
        for n in nets { dests.append(n.split(separator: ".").prefix(3).joined(separator: ".") + ".255") }
        if let ip { dests.append(ip) }
        let data = Data(pkt)
        let sent = try await blocking { LowNet.udpSend(data, to: dests, ports: [9, 7]) }
        if sent == 0 { throw AppError("Could not send the wake signal. iOS may be blocking it on this network.") }
    }
}

func ipLess(_ a: String, _ b: String) -> Bool {
    let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
    return x.lexicographicallyPrecedes(y)
}

// MARK: - Live state for the app screens

extension Wemo {
    /// nil = no answer
    static func state(_ ip: String) async -> Bool? {
        for p in [49153, 49152, 49154, 49155] {
            if let g = try? await Http.call("http://\(ip):\(p)/upnp/control/basicevent1", method: "POST", body: body("GetBinaryState", ""),
                                            contentType: "text/xml; charset=\"utf-8\"",
                                            headers: ["SOAPAction": "\"urn:Belkin:service:basicevent:1#GetBinaryState\""], timeout: 2) {
                return !(xmlTag(g.text, "BinaryState") ?? "0").hasPrefix("0")
            }
        }
        return nil
    }

    static func info(_ ip: String) async throws -> String {
        for p in [49153, 49152, 49154, 49155] {
            if let x = try? await Http.call("http://\(ip):\(p)/setup.xml", timeout: 2).text {
                let fields = [("Name", "friendlyName"), ("Model", "modelName"), ("Model number", "modelNumber"),
                              ("Firmware", "firmwareVersion"), ("Serial", "serialNumber"), ("MAC", "macAddress")]
                return fields.compactMap { f in xmlTag(x, f.1).map { "\(f.0): \($0)" } }.joined(separator: "\n")
            }
        }
        throw AppError("Wemo did not respond.")
    }
}

extension Wled {
    struct State { var on = false; var bri = 128 }

    static func state(_ ip: String) async -> State? {
        guard let j = try? await Http.json("http://\(ip)/json/state", timeout: 2) else { return nil }
        return State(on: j["on"] as? Bool ?? false, bri: j["bri"] as? Int ?? 128)
    }

    static func setColor(_ ip: String, r: Int, g: Int, b: Int) async throws {
        let body = "{\"on\":true,\"seg\":[{\"col\":[[\(r),\(g),\(b)]]}]}"
        _ = try await Http.call("http://\(ip)/json/state", method: "POST", body: Data(body.utf8), contentType: "application/json", timeout: 3)
    }

    static func effects(_ ip: String) async throws -> [String] {
        let r = try await Http.call("http://\(ip)/json/eff", timeout: 3)
        return (try? JSONSerialization.jsonObject(with: r.data) as? [String]) ?? []
    }

    static func setEffect(_ ip: String, _ index: Int) async throws {
        let body = "{\"on\":true,\"seg\":[{\"fx\":\(index)}]}"
        _ = try await Http.call("http://\(ip)/json/state", method: "POST", body: Data(body.utf8), contentType: "application/json", timeout: 3)
    }

    static func info(_ ip: String) async throws -> String {
        let j = try await Http.json("http://\(ip)/json/info", timeout: 3)
        var lines: [String] = []
        if let v = j["name"] { lines.append("Name: \(v)") }
        if let v = j["ver"] { lines.append("WLED version: \(v)") }
        if let leds = j["leds"] as? [String: Any], let c = leds["count"] { lines.append("LEDs: \(c)") }
        if let w = j["wifi"] as? [String: Any], let s = w["signal"] { lines.append("Wi-Fi signal: \(s)%") }
        if let v = j["arch"] { lines.append("Chip: \(v)") }
        if let v = j["mac"] { lines.append("MAC: \(v)") }
        return lines.joined(separator: "\n")
    }
}

enum WizScenes {
    static let all: [(Int, String)] = [(1, "Ocean"), (2, "Romance"), (3, "Sunset"), (4, "Party"), (5, "Fireplace"), (6, "Cozy"),
        (7, "Forest"), (8, "Pastel colors"), (9, "Wake up"), (10, "Bedtime"), (11, "Warm white"), (12, "Daylight"),
        (13, "Cool white"), (14, "Night light"), (15, "Focus"), (16, "Relax"), (17, "True colors"), (18, "TV time"),
        (19, "Plant growth"), (20, "Spring"), (21, "Summer"), (22, "Fall"), (23, "Deep dive"), (24, "Jungle"),
        (25, "Mojito"), (26, "Club"), (27, "Christmas"), (28, "Halloween"), (29, "Candlelight"), (30, "Golden white"),
        (31, "Pulse"), (32, "Steampunk")]
}
