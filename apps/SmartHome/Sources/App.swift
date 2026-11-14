import SwiftUI
import WebKit

@main
struct SmartHomeApp: App {
    init() { LowNet.raiseFileLimit() }

    var body: some Scene {
        WindowGroup {
            WebContainer()
                .ignoresSafeArea()
                .background(Color.black)
        }
    }
}

/// Hosts the MrLTTec page. Every request the page makes (/scan, /roku, /samsung ...) is answered
/// by the Swift "server" in Router.swift through the mrl:// scheme, so nothing needs a PC.
struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> UIHandler { UIHandler() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(Bridge.shared, forURLScheme: "mrl")
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.isInspectable = true
        web.load(URLRequest(url: URL(string: "mrl://app/")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Makes alert(), confirm() and prompt() in the page show real iOS dialogs.
final class UIHandler: NSObject, WKUIDelegate {
    private func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        guard let vc = top() else { completionHandler(); return }
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        guard let vc = top() else { completionHandler(false); return }
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        guard let vc = top() else { completionHandler(nil); return }
        vc.present(a, animated: true)
    }
}
