import SwiftUI
import ReplayKit

/// iOS's own "Start Broadcast" button, pointed at the MrLTTec Mirror extension.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.mrlttec.smarthome") + ".ScreenBroadcast"
        v.showsMicrophoneButton = false
        if let b = v.subviews.compactMap({ $0 as? UIButton }).first {
            b.imageView?.tintColor = UIColor(Theme.gold)
        }
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// "Mirror my screen" for DLNA Renderer TVs (like Hisense): broadcast the screen, then tell the TV to play the live stream.
struct MirrorSection: View {
    let target: CastTarget
    @ObservedObject var runner: Runner
    @State private var live = false
    @State private var sent = false

    static let streamPort = 8799

    var body: some View {
        Section {
            HStack(spacing: 14) {
                BroadcastButton().frame(width: 56, height: 56)
                    .background(Theme.gold.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(live ? "Your screen is being broadcast" : "1. Tap the button, then Start Broadcast")
                        .font(.subheadline.weight(.semibold))
                    Text(live ? (sent ? "Showing on \(target.name)." : "Sending it to the TV…") : "Pick \"MrLTTec Mirror\" if it asks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await sendToTV() }
            } label: {
                Label(sent ? "Send to the TV again" : "2. Show on the TV", systemImage: "tv")
            }
            .disabled(!live)
            if sent {
                Button("Stop on the TV", role: .destructive) {
                    runner.fire("Stopped") { try await Dlna.call(target.avt, "Stop", "") }
                    sent = false
                }
            }
        } header: {
            Text("Mirror my screen")
        } footer: {
            Text("Works on TVs that only have a DLNA \"Renderer\", like many Hisense TVs. The TV runs about 2 to 5 seconds behind your phone and there's no sound. To stop the broadcast, tap the red bar at the top of your screen.")
        }
        .task {
            // Watch for the broadcast to start, then send it to the TV automatically.
            while !Task.isCancelled {
                let up = (try? await Http.call("http://127.0.0.1:\(Self.streamPort)/status", timeout: 1)) != nil
                if up != live { withAnimation { live = up } }
                if up && !sent { await sendToTV() }
                if !up { sent = false }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func sendToTV() async {
        let net = target.ip.split(separator: ".").prefix(3).joined(separator: ".")
        let addrs = LowNet.localAddrs()
        guard let me = addrs.first(where: { $0.hasPrefix(net + ".") }) ?? addrs.first,
              let url = URL(string: "http://\(me):\(Self.streamPort)/screen.ts") else {
            runner.show("This iPhone isn't on the TV's Wi-Fi.", error: true); return
        }
        sent = true
        if await runner.run("Your screen is on \(target.name)", {
            try await Dlna.play(target.avt, url: url, type: "video/mp2t", title: "iPhone screen")
            return ""
        }) == nil { sent = false }
    }
}
