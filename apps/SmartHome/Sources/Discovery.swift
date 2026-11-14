import Foundation

// MARK: - Discover everything (Find-Devices)

enum Discovery {
    static let ports: [UInt16] = [80, 1400, 5555, 8001, 8002, 8009, 8060, 49152, 49153, 49154, 49155, 55000]

    static func findDevices() async -> [[String: String]] {
        let ips = LowNet.subnetIps()
        if ips.isEmpty { return [] }
        async let wiz = Wiz.find()
        async let xbox = Xbox.find(ips)
        let targets = ips.flatMap { ip in ports.map { (ip, $0) } }
        let sweep = (try? await blocking { LowNet.tcpSweep(targets, timeoutMs: 2500) }) ?? LowNet.SweepResult()

        var byIp: [String: Set<UInt16>] = [:]
        for k in sweep.open {
            let parts = k.split(separator: ":")
            if parts.count == 2, let p = UInt16(parts[1]) { byIp[String(parts[0]), default: []].insert(p) }
        }

        var out: [[String: String]] = []
        await withTaskGroup(of: [[String: String]].self) { g in
            for (ip, p) in byIp { g.addTask { await identify(ip, p) } }
            for await r in g { out += r }
        }
        out += await wiz
        for x in await xbox where isPrivateIp(x.ip) {
            out.append(["ip": x.ip, "type": "xbox", "name": x.name, "detail": x.liveId.isEmpty ? "Xbox" : "Xbox, Live ID \(x.liveId)"])
        }
        return out.sorted { ipLess($0["ip"] ?? "", $1["ip"] ?? "") }
    }

    private static func identify(_ ip: String, _ p: Set<UInt16>) async -> [[String: String]] {
        var out: [[String: String]] = []
        if p.contains(1400), let x = try? await Http.call("http://\(ip):1400/xml/device_description.xml", timeout: 1.5).text,
           (xmlTag(x, "manufacturer") ?? "").contains("Sonos") {
            out.append(["ip": ip, "type": "sonos", "name": xmlTag(x, "roomName") ?? "Sonos", "detail": xmlTag(x, "displayName") ?? ""])
        }
        if let wp = [49153, 49152, 49154, 49155].first(where: { p.contains(UInt16($0)) }),
           let x = try? await Http.call("http://\(ip):\(wp)/setup.xml", timeout: 1.5).text, let n = xmlTag(x, "friendlyName") {
            out.append(["ip": ip, "type": "wemo", "name": n, "detail": "Wemo"])
        }
        if p.contains(8001) || p.contains(8002) {
            if p.contains(8001), let j = try? await Http.json("http://\(ip):8001/api/v2/", timeout: 1.5), let d = j["device"] as? [String: Any] {
                out.append(["ip": ip, "type": "samsung", "name": d["name"] as? String ?? "Samsung TV", "detail": d["modelName"] as? String ?? ""])
                if let mac = d["wifiMac"] as? String, Store.get("samsungMacs", ip).isEmpty, mac.count == 17 { Store.set("samsungMacs", ip, mac.uppercased()) }
            } else {
                out.append(["ip": ip, "type": "samsung", "name": "Samsung TV (probably)", "detail": "found by port \(p.contains(8001) ? 8001 : 8002)"])
            }
        } else if p.contains(55000) {
            out.append(["ip": ip, "type": "samsung", "name": "Older Samsung TV (probably)", "detail": "found by port 55000"])
        }
        if p.contains(80), let j = try? await Http.json("http://\(ip)/json/info", timeout: 1.5), j["brand"] as? String == "WLED" {
            out.append(["ip": ip, "type": "wled", "name": j["name"] as? String ?? "WLED", "detail": "WLED \(j["ver"] ?? "")"])
        }
        if p.contains(5555) { out.append(["ip": ip, "type": "adb", "name": "Android / Fire TV", "detail": "ADB debugging is on"]) }
        if p.contains(8060) {
            if let x = try? await Http.call("http://\(ip):8060/query/device-info", timeout: 1.5).text, x.contains("<device-info") {
                let n = xmlTag(x, "user-device-name") ?? xmlTag(x, "friendly-device-name") ?? xmlTag(x, "default-device-name") ?? "Roku"
                let m = xmlTag(x, "friendly-model-name") ?? xmlTag(x, "model-name") ?? "Roku"
                out.append(["ip": ip, "type": "roku", "name": n, "detail": m])
            } else {
                out.append(["ip": ip, "type": "roku", "name": "Roku (probably)", "detail": "found by port 8060"])
            }
        }
        if p.contains(8009), (try? await Http.call("http://\(ip):8009/apps/FireTVRemote", timeout: 1.5)) != nil {
            out.append(["ip": ip, "type": "firetv", "name": "Fire TV (PIN control)", "detail": "Fire TV Remote service found"])
        }
        return out
    }

    // MARK: Sonos (/discover)

    static func findSonos() async -> [[String: String]] {
        let ips = LowNet.subnetIps()
        let sweep = (try? await blocking { LowNet.tcpSweep(ips.map { ($0, UInt16(1400)) }, timeoutMs: 1800) }) ?? LowNet.SweepResult()
        var out: [[String: String]] = []
        await withTaskGroup(of: [String: String]?.self) { g in
            for k in sweep.open {
                let ip = String(k.split(separator: ":")[0])
                g.addTask {
                    guard let x = try? await Http.call("http://\(ip):1400/xml/device_description.xml", timeout: 3).text,
                          (xmlTag(x, "manufacturer") ?? "").contains("Sonos") else { return nil }
                    return ["ip": ip, "room": xmlTag(x, "roomName") ?? "", "model": xmlTag(x, "displayName") ?? ""]
                }
            }
            for await r in g { if let r { out.append(r) } }
        }
        return out.sorted { ($0["room"] ?? "") < ($1["room"] ?? "") }
    }
}

// MARK: - Saved devices (saved-devices.json on the phone)

enum Saved {
    static let types: Set<String> = ["sonos", "samsung", "wemo", "adb", "firetv", "appletv", "roku", "wled", "wiz", "wizplug", "xbox"]
    private static let lock = NSLock()

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("saved-devices.json")
    }

    private static func load() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: url), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a.filter { types.contains($0["type"] as? String ?? "") && isPrivateIp($0["ip"] as? String ?? "") }
    }

    private static func save(_ list: [[String: Any]]) {
        if let d = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) { try? d.write(to: url, options: .atomic) }
    }

    /// Merges scan results in. Names the user typed are kept; removed devices stay removed.
    static func addFound(_ found: [[String: String]]) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        for f in found {
            let type = f["type"] ?? "", ip = f["ip"] ?? ""
            guard types.contains(type), isPrivateIp(ip) else { continue }
            var name = cleanName(f["name"] ?? ""); let detail = cleanName(f["detail"] ?? "")
            if name.isEmpty { name = ip }
            if let i = list.firstIndex(where: { $0["type"] as? String == type && $0["ip"] as? String == ip }) {
                if list[i]["custom"] as? Bool != true && list[i]["hidden"] as? Bool != true { list[i]["name"] = name; list[i]["detail"] = detail }
            } else {
                list.append(["type": type, "ip": ip, "name": name, "detail": detail, "custom": false, "hidden": false])
            }
        }
        save(list)
    }

    static func run(_ v: String, _ type: String, _ ip: String, _ name: String) throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        if v == "add" || v == "remove" {
            guard types.contains(type) else { throw AppError("Device type not allowed.") }
            try assertLocalIp(ip)
            let i = list.firstIndex { $0["type"] as? String == type && $0["ip"] as? String == ip }
            if v == "add" {
                var n = cleanName(name); if n.isEmpty { n = ip }
                if let i { list[i]["name"] = n; list[i]["custom"] = true; list[i]["hidden"] = false }
                else { list.append(["type": type, "ip": ip, "name": n, "detail": "", "custom": true, "hidden": false]) }
            } else if let i {
                list[i]["hidden"] = true
            }
            save(list)
        } else if v != "list" {
            throw AppError("Command not allowed.")
        }
        return list.filter { $0["hidden"] as? Bool != true }
            .map { ["type": $0["type"] as? String ?? "", "ip": $0["ip"] as? String ?? "", "name": $0["name"] as? String ?? "", "detail": $0["detail"] as? String ?? ""] }
            .sorted { $0["type"]! != $1["type"]! ? $0["type"]! < $1["type"]! : ipLess($0["ip"]!, $1["ip"]!) }
    }
}

// MARK: - Network tools (/net)

enum NetTools {
    static let common: [(UInt16, String)] = [(21, "FTP"), (22, "SSH"), (23, "Telnet"), (53, "DNS"), (80, "HTTP"), (135, "Windows RPC"), (139, "NetBIOS"),
        (443, "HTTPS"), (445, "Windows file sharing (SMB)"), (3389, "Remote Desktop"), (5900, "VNC"), (8080, "HTTP (alternate)"), (9100, "Printer")]

    static func run(_ v: String, _ ip: String, _ t: String) async throws -> String {
        switch v {
        case "ping":
            try assertLocalIp(ip)
            var lines: [String] = []; var ok = 0
            for _ in 0..<4 {
                let r = try await blocking { LowNet.icmpSweep([ip], waitMs: 1500) }
                if let ms = r[ip] { ok += 1; lines.append("Reply from \(ip): time=\(Int(ms.rounded())) ms") } else { lines.append("No reply: TimedOut") }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            lines.append("\(ok) of 4 replies")
            return lines.joined(separator: "\n")
        case "port":
            try assertLocalIp(ip)
            guard let p = Int(t), (1...65535).contains(p) else { throw AppError("Port must be a number from 1 to 65535.") }
            let open = try await blocking { LowNet.tcpOpen(ip, UInt16(p), timeoutMs: 1500) }
            return "Port \(p) on \(ip): \(open ? "OPEN" : "closed or not answering")"
        case "common":
            try assertLocalIp(ip)
            let r = try await blocking { LowNet.tcpSweep(common.map { (ip, $0.0) }, timeoutMs: 1500) }
            let open = common.filter { r.open.contains("\(ip):\($0.0)") }.map { "\($0.0)  \($0.1)" }
            if open.isEmpty { return "No common ports are open on \(ip) (or it is not answering)." }
            return "Open ports on \(ip):\n" + open.joined(separator: "\n")
        case "devices":
            return try await devices()
        case "wol":
            guard t.wholeMatch(of: #/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/#) != nil else { throw AppError("Type the MAC address like AA:BB:CC:DD:EE:FF.") }
            if !ip.isEmpty { try assertLocalIp(ip) }
            try await WakeOnLan.send(ip: ip.isEmpty ? nil : ip, mac: t)
            return "Wake signal sent."
        default:
            throw AppError("Command not allowed.")
        }
    }

    /// Pings every address and knocks on a few common ports (some devices ignore ping), then lists what answered.
    /// iOS does not let apps read MAC addresses, so those columns stay empty.
    static func devices() async throws -> String {
        let ips = LowNet.subnetIps()
        if ips.isEmpty { return "[]" }
        async let pings = blocking { LowNet.icmpSweep(ips, waitMs: 2000) }
        let knock: [UInt16] = [80, 443, 22, 445, 7000, 8080, 62078]
        let sweep = try await blocking { LowNet.tcpSweep(ips.flatMap { ip in knock.map { (ip, $0) } }, timeoutMs: 2000) }
        var alive = sweep.alive
        let pingRes = try await pings
        for ip in pingRes.keys { alive.insert(ip) }
        let mine = Set(LowNet.localAddrs())
        let sorted = alive.filter { isPrivateIp($0) && !$0.hasSuffix(".255") }.sorted(by: ipLess)
        var hosts: [String: String] = [:]
        await withTaskGroup(of: (String, String).self) { g in
            for ip in sorted { g.addTask { (ip, (try? await blocking { LowNet.hostName(ip) }) ?? "") } }
            for await (ip, h) in g { hosts[ip] = h }
        }
        let rows: [[String: String]] = sorted.map { ip in
            ["ip": ip, "mac": "", "host": mine.contains(ip) ? "This iPhone" : (hosts[ip] ?? ""), "maker": ""]
        }
        let d = try JSONSerialization.data(withJSONObject: rows)
        return String(decoding: d, as: UTF8.self)
    }
}
