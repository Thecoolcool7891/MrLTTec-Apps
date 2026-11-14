import Foundation

/// HTTP to devices on the local network. Accepts the self-signed certificates TVs use, but only for private IPs.
final class Http: NSObject, URLSessionDelegate {
    static let shared = Http()
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    /// Long-lived websockets (Samsung TV) must not hit the 30 s resource timeout above.
    lazy var wsSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           isPrivateIp(challenge.protectionSpace.host), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    struct Result {
        let data: Data
        let status: Int
        let contentType: String
        var headers: [AnyHashable: Any] = [:]
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
        }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// Throws on network failure or a non-2xx answer (like Invoke-Http in the PC version).
    static func call(_ url: String, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                     headers: [String: String] = [:], timeout: Double = 5) async throws -> Result {
        guard let u = URL(string: url) else { throw AppError("Bad address.") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await shared.session.data(for: r) }
        catch let e as URLError where e.code == .timedOut { throw AppError("The device did not answer in time.") }
        catch { throw AppError("Could not reach the device (\(error.localizedDescription)).") }
        let h = resp as? HTTPURLResponse
        let code = h?.statusCode ?? 0
        let ct = h?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(code) else {
            let text = String(decoding: data, as: UTF8.self)
            var detail = ""
            if let m = text.firstMatch(of: #/<errorCode>(\d+)</errorCode>/#) { detail = " (UPnP error \(m.1))" }
            throw HttpStatusError(status: code, body: data, message: "The device returned HTTP \(code)\(detail).")
        }
        return Result(data: data, status: code, contentType: ct, headers: h?.allHeaderFields ?? [:])
    }

    static func json(_ url: String, timeout: Double = 3) async throws -> [String: Any] {
        let r = try await call(url, timeout: timeout)
        guard let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] else { throw AppError("The device answered with something unexpected.") }
        return o
    }
}

struct HttpStatusError: LocalizedError {
    let status: Int
    let body: Data
    let message: String
    var errorDescription: String? { message }
}

// MARK: Tiny XML helpers (device answers are small and flat)

func xmlTag(_ xml: String, _ tag: String) -> String? {
    let esc = NSRegularExpression.escapedPattern(for: tag)
    guard let rx = try? NSRegularExpression(pattern: "<\(esc)(?:\\s[^>]*)?>([^<]*)</\(esc)>"),
          let m = rx.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
          let r = Range(m.range(at: 1), in: xml) else { return nil }
    let v = xmlUnescape(String(xml[r])).trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
}

func xmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
}

/// Printable ASCII only, 60 characters at most (same as Get-CleanName).
func cleanName(_ s: String) -> String {
    let c = String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }).trimmingCharacters(in: .whitespaces)
    return c.count > 60 ? String(c.prefix(60)).trimmingCharacters(in: .whitespaces) : c
}

/// Small key/value store in UserDefaults for tokens, MACs and Live IDs.
enum Store {
    static func get(_ table: String, _ key: String) -> String {
        (UserDefaults.standard.dictionary(forKey: table) as? [String: String])?[key] ?? ""
    }
    static func set(_ table: String, _ key: String, _ value: String) {
        var d = (UserDefaults.standard.dictionary(forKey: table) as? [String: String]) ?? [:]
        if value.isEmpty { d.removeValue(forKey: key) } else { d[key] = value }
        UserDefaults.standard.set(d, forKey: table)
    }
}
