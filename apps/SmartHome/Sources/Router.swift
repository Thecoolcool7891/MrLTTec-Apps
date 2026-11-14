import Foundation

/// The iPhone version of the request handler in Tool-App.ps1: same paths, same parameters, same answers.
enum Router {
    static let sonosPaths: Set<String> = [
        "/MediaRenderer/RenderingControl/Control", "/MediaRenderer/AVTransport/Control",
        "/DeviceProperties/Control", "/ZoneGroupTopology/Control",
        "/MediaRenderer/GroupRenderingControl/Control", "/AlarmClock/Control",
        "/MediaServer/ContentDirectory/Control", "/MusicServices/Control",
    ]
    static let notYet = "That part is not in the iPhone app yet. It is coming in a later update."

    /// Query string parsing that treats + as a space (URLSearchParams on the page writes spaces that way).
    static func query(_ url: URL) -> [String: String] {
        var q: [String: String] = [:]
        for pair in (url.query ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            if q[k] == nil { q[k] = v }
        }
        return q
    }

    static func handle(_ req: URLRequest) async -> Reply {
        guard let url = req.url else { return .text("Bad request", 400) }
        let path = url.path.isEmpty ? "/" : url.path
        let method = req.httpMethod ?? "GET"
        let q = query(url)
        do {
            return try await route(path, method, q, req)
        } catch {
            return .text(error.localizedDescription, 502)
        }
    }

    private static func route(_ path: String, _ method: String, _ q: [String: String], _ req: URLRequest) async throws -> Reply {
        let ip = q["ip"] ?? ""
        let v = q["v"] ?? ""
        let t = q["t"] ?? ""

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            guard let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web"),
                  let d = try? Data(contentsOf: u) else { return .text("index.html is missing from the app.", 500) }
            return .data(d, "text/html; charset=utf-8")

        case ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"), ("GET", "/favicon.ico"):
            guard let u = Bundle.main.url(forResource: "apple-touch-icon", withExtension: "png", subdirectory: "Web"),
                  let d = try? Data(contentsOf: u) else { return .text("Not found", 404) }
            return .data(d, "image/png")

        case ("GET", "/health"):
            return .text("ok")

        // ----- Sonos -----
        case ("POST", "/proxy"):
            try assertLocalIp(ip)
            guard let p = q["path"], sonosPaths.contains(p) else { throw AppError("Path not allowed.") }
            var headers: [String: String] = [:]
            if let soap = req.value(forHTTPHeaderField: "X-Soap-Action"), !soap.trimmingCharacters(in: .whitespaces).isEmpty { headers["SOAPAction"] = soap }
            do {
                let r = try await Http.call("http://\(ip):1400\(p)", method: "POST", body: req.httpBody ?? Data(),
                                            contentType: "text/xml; charset=\"utf-8\"", headers: headers, timeout: 8)
                return .data(r.data, "text/xml; charset=utf-8")
            } catch let e as HttpStatusError {
                throw AppError(e.message)
            }

        case ("GET", "/discover"):
            return .json(await Discovery.findSonos())

        case ("GET", "/art"):
            try assertLocalIp(ip)
            guard let p = q["path"], p.hasPrefix("/getaa?") else { throw AppError("Path not allowed.") }
            let r = try await Http.call("http://\(ip):1400\(p)", timeout: 8)
            return .data(r.data, r.contentType.isEmpty ? "image/jpeg" : r.contentType)

        case ("GET", "/get"):
            try assertLocalIp(ip)
            guard let p = q["path"], p.wholeMatch(of: #/\/(xml\/device_description\.xml|status\/(zp|topology|info))/#) != nil else { throw AppError("Path not allowed.") }
            let r = try await Http.call("http://\(ip):1400\(p)", timeout: 8)
            return .data(r.data, "text/plain; charset=utf-8")

        case ("GET", "/info"):
            try assertLocalIp(ip)
            let r = try await Http.call("http://\(ip):1400/xml/device_description.xml", timeout: 8)
            return .data(r.data, "text/xml; charset=utf-8")

        // ----- Discover + saved devices -----
        case ("GET", "/scan"):
            let found = await Discovery.findDevices()
            Saved.addFound(found)
            return .json(found)

        case ("GET", "/saved"):
            return .json(try Saved.run("list", "", "", ""))
        case ("POST", "/saved"):
            return .json(try Saved.run(v, q["type"] ?? "", ip, q["name"] ?? ""))

        case ("GET", "/roku/icon"):
            try assertLocalIp(ip)
            let r = try await Roku.icon(ip, q["id"] ?? "")
            let ct = r.contentType.hasPrefix("image/") ? r.contentType : "image/png"
            return .data(r.data, ct)

        // ----- Device commands -----
        case ("POST", "/wemo"):
            try assertLocalIp(ip); try await Wemo.run(ip, v); return .text("ok")
        case ("POST", "/wled"):
            try assertLocalIp(ip); try await Wled.run(ip, v); return .text("ok")
        case ("POST", "/wiz"):
            try assertLocalIp(ip); return okText(try await Wiz.run(ip, v, t))
        case ("POST", "/roku"):
            try assertLocalIp(ip); return okText(try await Roku.run(ip, v, t))
        case ("POST", "/samsung"):
            try assertLocalIp(ip); return okText(try await Samsung.shared.run(ip, v, t))
        case ("POST", "/xbox"):
            try assertLocalIp(ip); return okText(try await Xbox.run(ip, v, t))
        case ("POST", "/net"):
            return okText(try await NetTools.run(v, ip, t))

        // ----- Not ported yet -----
        case ("POST", "/adb"), ("GET", "/adb/screen"):
            throw AppError("Android / Fire TV over ADB is not in the iPhone app yet. Use Fire TV (PIN) when it arrives, or the laptop Tool for now.")
        case ("POST", "/appletv"):
            throw AppError("Apple TV control is not in the iPhone app yet. It is planned for a later update.")
        case ("POST", "/firetv"):
            throw AppError("Fire TV (PIN) is not in the iPhone app yet. It is coming in the next update.")
        default:
            if path.hasPrefix("/cast/") || path.hasPrefix("/cloud/") || ["/pc", "/hook", "/sys", "/movie", "/wakeup", "/offtimer"].contains(path) {
                throw AppError(notYet)
            }
            return .text("Not found", 404)
        }
    }

    private static func okText(_ s: String) -> Reply { .text(s.isEmpty ? "ok" : s) }
}
