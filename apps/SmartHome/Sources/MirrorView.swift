import SwiftUI
import ReplayKit
import CoreImage.CIFilterBuiltins

/// iOS's own "Start Broadcast" button, pointed at the MrLTTec Mirror extension.
/// The system button's icon can't be positioned reliably, so our own icon is drawn underneath and the
/// system button sits on top almost invisible (it still gets the taps).
final class CenteredBroadcastPicker: RPSystemBroadcastPickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        // Stretch the (invisible) system button over the whole circle so any tap starts the broadcast.
        for case let b as UIButton in subviews { b.frame = bounds }
    }
}

struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> CenteredBroadcastPicker {
        let v = CenteredBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.mrlttec.smarthome") + ".ScreenBroadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ uiView: CenteredBroadcastPicker, context: Context) { uiView.setNeedsLayout() }
}

enum Mirror {
    static let port = 8799

    static func isLive() async -> Bool {
        (try? await Http.call("http://127.0.0.1:\(port)/status", timeout: 1)) != nil
    }

    /// The iPhone's address on the same network as `ip` (or its first Wi-Fi address).
    static func myAddress(near ip: String? = nil) -> String? {
        let addrs = LowNet.localAddrs()
        if let ip {
            let net = ip.split(separator: ".").prefix(3).joined(separator: ".")
            if let m = addrs.first(where: { $0.hasPrefix(net + ".") }) { return m }
        }
        return addrs.first
    }

    /// Asks for the HLS playlist (which switches HLS on) and waits until it has a couple of segments.
    static func waitForHLS() async throws {
        for _ in 0..<20 {
            if let r = try? await Http.call("http://127.0.0.1:\(port)/live.m3u8", timeout: 2),
               r.text.components(separatedBy: "#EXTINF").count >= 3 { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        throw AppError("The screen stream didn't get going. Is the broadcast still on?")
    }
}

/// Header with the broadcast button and its status, shared by both mirror screens.
struct BroadcastHeader: View {
    let live: Bool
    let subtitle: String
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.15))
                Image(systemName: live ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(live ? .red : Theme.gold)
                BroadcastButton().opacity(0.02)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(live ? "Your screen is being broadcast" : "Tap the button, then Start Broadcast")
                    .font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// "Screen mirror" for a cast target: DLNA gets live MPEG-TS, Chromecast and AirPlay get HLS.
struct MirrorSection: View {
    let target: CastTarget
    let method: String
    @ObservedObject var runner: Runner
    @State private var live = false
    @State private var sent = false
    @State private var sending = false

    var body: some View {
        Section {
            BroadcastHeader(live: live, subtitle: live ? (sent ? "Showing on \(target.name)." : "Sending it to the TV…") : "Pick \"MrLTTec Mirror\" if it asks.")
            Button { Task { await send() } } label: {
                Label(sent ? "Send to the TV again" : "Show my screen on the TV", systemImage: "rectangle.on.rectangle")
            }
            .disabled(!live || sending)
            if sent {
                Button("Stop on the TV", role: .destructive) { stop() }
            }
        } header: {
            Text("Screen mirror")
        } footer: {
            Text(footer)
        }
        .task {
            while !Task.isCancelled {
                let up = await Mirror.isLive()
                if up != live { withAnimation { live = up } }
                if up && !sent && !sending { await send() }
                if !up { sent = false }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private var footer: String {
        let lag = method == "dlna" ? "2 to 5" : "5 to 10"
        return "The TV runs about \(lag) seconds behind your phone and there's no sound yet. To stop broadcasting, tap the red bar at the top of your screen."
    }

    private func send() async {
        guard let me = Mirror.myAddress(near: target.ip) else { runner.show("This iPhone isn't on the TV's Wi-Fi.", error: true); return }
        sending = true
        defer { sending = false }
        let ok = await runner.run("Your screen is on \(target.name)") {
            switch method {
            case "cast":
                try await Mirror.waitForHLS()
                try await Cast.load(target.ip, url: URL(string: "http://\(me):\(Mirror.port)/live.m3u8")!, type: "application/x-mpegURL", live: true)
            case "airplay":
                guard AirPlay2.isPaired(target.ip) else { throw AppError("Pair with AirPlay first (above), then try again.") }
                try await Mirror.waitForHLS()
                try await AirPlay2.shared.playURL(target.ip, URL(string: "http://\(me):\(Mirror.port)/live.m3u8")!)
            default:
                try await Dlna.play(target.avt, url: URL(string: "http://\(me):\(Mirror.port)/screen.ts")!, type: "video/mp2t", title: "iPhone screen")
            }
            return ""
        }
        sent = ok != nil
    }

    private func stop() {
        let m = method
        runner.fire("Stopped") {
            switch m {
            case "cast": try await Cast.control(target.ip, "stop")
            case "airplay": try await AirPlay2.shared.control(target.ip, "stop")
            default: try await Dlna.call(target.avt, "Stop", "")
            }
        }
        sent = false
    }
}

/// Tools > Watch in a web browser: shows the address any other device can open to see this screen.
struct BrowserMirrorView: View {
    @State private var live = false
    @State private var addr: String?

    private var url: String? { addr.map { "http://\($0):\(Mirror.port)" } }

    var body: some View {
        Form {
            Section {
                BroadcastHeader(live: live, subtitle: live ? "Open the address below on the other device." : "Pick \"MrLTTec Mirror\" if it asks.")
            }
            Section {
                if let url {
                    Text(url).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                    if let qr = qrImage(url) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 180, height: 180).frame(maxWidth: .infinity)
                    }
                    Button { UIPasteboard.general.string = url; Haptic.success() } label: { Label("Copy address", systemImage: "doc.on.doc") }
                } else {
                    Label("Connect to Wi-Fi first", systemImage: "wifi.slash").foregroundStyle(.orange)
                }
            } header: {
                Text("On the other device, open")
            } footer: {
                Text("Works in any web browser (computer, tablet, phone or smart TV) on the same Wi-Fi. Scan the code with a phone's camera, or type the address. Double-click the picture on a computer for full screen. Keep this app's broadcast running; there's no sound.")
            }
        }
        .navigationTitle("Watch in a browser")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                addr = Mirror.myAddress()
                let up = await Mirror.isLive()
                if up != live { withAnimation { live = up } }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func qrImage(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
