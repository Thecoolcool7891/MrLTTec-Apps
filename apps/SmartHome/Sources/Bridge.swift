import Foundation
import WebKit

struct Reply {
    var status: Int = 200
    var type: String = "text/plain; charset=utf-8"
    var body: Data = Data()

    static func text(_ s: String, _ status: Int = 200) -> Reply { Reply(status: status, body: Data(s.utf8)) }
    static func json(_ obj: Any) -> Reply {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return Reply(type: "application/json; charset=utf-8", body: d)
    }
    static func data(_ d: Data, _ type: String) -> Reply { Reply(type: type, body: d) }
}

/// Answers the page's fetch() calls to mrl://app/... the way Tool-App.ps1 answered them on the PC.
final class Bridge: NSObject, WKURLSchemeHandler {
    static let shared = Bridge()
    private var live = Set<ObjectIdentifier>()   // touched on the main thread only

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        var req = task.request
        if req.httpBody == nil, let stream = req.httpBodyStream { req.httpBody = Bridge.read(stream) }
        let request = req
        Task.detached {
            let reply = await Router.handle(request)
            await MainActor.run {
                guard self.live.remove(id) != nil, let url = request.url else { return }
                let headers = ["Content-Type": reply.type, "Cache-Control": "no-store",
                               "Content-Length": String(reply.body.count)]
                let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
                task.didReceive(resp)
                task.didReceive(reply.body)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private static func read(_ s: InputStream) -> Data {
        var out = Data()
        s.open(); defer { s.close() }
        var buf = [UInt8](repeating: 0, count: 65536)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}
