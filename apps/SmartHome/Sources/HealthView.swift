import SwiftUI

/// Tools > Network health check: a quick report for "my Wi-Fi is bad" moments.
struct HealthView: View {
    @EnvironmentObject var store: DeviceStore

    enum Grade: Int { case good = 0, ok = 1, bad = 2, info = 3
        var color: Color { [Color.green, .yellow, .red, .secondary][rawValue] }
        var icon: String { ["checkmark.circle.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill", "info.circle.fill"][rawValue] }
    }
    struct Item: Identifiable { let id = UUID(); let title: String; let grade: Grade; let detail: String }

    @State private var items: [Item] = []
    @State private var running = false
    @State private var step = ""

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: summaryIcon).font(.system(size: 44)).foregroundStyle(summaryColor)
                        .symbolEffect(.pulse, isActive: running)
                    Text(running ? step : items.isEmpty ? "Check how this Wi-Fi is doing" : summaryText).font(.headline).multilineTextAlignment(.center)
                    Button { Task { await run() } } label: {
                        Label(items.isEmpty ? "Run check" : "Run again", systemImage: "stethoscope").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            if !items.isEmpty {
                Section("Results") {
                    ForEach(items) { it in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: it.grade.icon).foregroundStyle(it.grade.color).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(it.title).font(.subheadline.weight(.semibold))
                                Text(it.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Network health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var worst: Grade { items.map(\.grade).filter { $0 != .info }.max { $0.rawValue < $1.rawValue } ?? .good }
    private var summaryIcon: String { items.isEmpty ? "wifi" : worst.icon }
    private var summaryColor: Color { items.isEmpty ? Theme.gold : worst.color }
    private var summaryText: String {
        switch worst {
        case .good: return "This network looks healthy"
        case .ok: return "Mostly fine, a few things to look at"
        default: return "This network has problems"
        }
    }

    private func add(_ title: String, _ g: Grade, _ d: String) { withAnimation(.snappy) { items.append(Item(title: title, grade: g, detail: d)) } }

    private func run() async {
        running = true
        items = []
        defer { running = false; worst == .bad ? Haptic.error() : Haptic.success() }
        store.refreshNetwork()

        // 1. Wi-Fi
        step = "Checking Wi-Fi…"
        guard let me = store.localAddrs.first else {
            add("Wi-Fi", .bad, "This iPhone isn't on Wi-Fi. Join the network you want to check.")
            return
        }
        let net = me.split(separator: ".").prefix(3).joined(separator: ".")
        add("Wi-Fi", .good, "Connected. This iPhone is \(me) on \(net).x")

        // 2. Router
        step = "Testing the router…"
        let router = "\(net).1"
        var times: [Double] = []
        for _ in 0..<10 {
            if let t = (try? await blocking { LowNet.icmpSweep([router], waitMs: 1000) })?[router] { times.append(t) }
        }
        if times.isEmpty {
            let open = (try? await blocking { LowNet.tcpSweep([(router, 80), (router, 443), (router, 53)], timeoutMs: 1000) })?.alive.contains(router) ?? false
            add("Router (\(router))", open ? .ok : .bad, open ? "Answers, but ignores ping, so speed can't be measured." : "Didn't answer. The router may use a different address, or the connection is very poor.")
        } else {
            let avg = times.reduce(0, +) / Double(times.count)
            let loss = 100 - times.count * 10
            let g: Grade = loss == 0 && avg < 15 ? .good : (loss <= 20 && avg < 60 ? .ok : .bad)
            add("Router (\(router))", g, "\(Int(avg.rounded())) ms average, \(loss)% of pings lost" + (g == .good ? "." : ". Moving closer to the router usually helps."))
        }

        // 3. Internet + Wi-Fi login pages
        step = "Checking the internet…"
        let t0 = Date()
        if let r = try? await Http.call("http://captive.apple.com/hotspot-detect.html", timeout: 6) {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if r.text.contains("Success") {
                add("Internet", ms < 300 ? .good : .ok, "Online, answered in \(ms) ms.")
            } else {
                add("Internet", .bad, "This Wi-Fi wants you to sign in on a login page first (common in hotels and schools).")
            }
        } else {
            add("Internet", .bad, "No internet. Devices on this network can still be controlled, but nothing online will work.")
        }

        // 4. DNS
        step = "Checking DNS…"
        let d0 = Date()
        let resolved = (try? await blocking { () -> Bool in
            var res: UnsafeMutablePointer<addrinfo>?
            let ok = getaddrinfo("www.apple.com", nil, nil, &res) == 0
            if res != nil { freeaddrinfo(res) }
            return ok
        }) ?? false
        let dms = Int(Date().timeIntervalSince(d0) * 1000)
        add("Name lookups (DNS)", resolved ? (dms < 150 ? .good : .ok) : .bad, resolved ? "Took \(dms) ms." : "Couldn't look up websites. The router's DNS may be broken.")

        // 5. Download speed
        if items.last(where: { $0.title == "Internet" })?.grade != .bad {
            step = "Measuring download speed…"
            let s0 = Date()
            if let r = try? await Http.call("https://speed.cloudflare.com/__down?bytes=20000000", timeout: 25) {
                let secs = max(0.05, Date().timeIntervalSince(s0))
                let mbps = Double(r.data.count) * 8 / secs / 1_000_000
                add("Download speed", mbps >= 50 ? .good : mbps >= 10 ? .ok : .bad,
                    String(format: "%.0f Mbps", mbps) + (mbps >= 25 ? " (enough for 4K streaming)." : mbps >= 10 ? " (fine for HD streaming)." : " (slow; video may buffer)."))
            } else {
                add("Download speed", .ok, "Couldn't finish the speed test.")
            }
        }

        // 6. Everything on the network
        step = "Finding every device…"
        let hosts = await NetTools.hosts()
        let slow = hosts.filter { ($0.ping ?? 0) > 150 }
        add("Devices online", .info, "\(hosts.count) device\(hosts.count == 1 ? "" : "s") answered on this network.")
        if !slow.isEmpty {
            add("Slow devices", .ok, slow.prefix(5).map { "\($0.name.isEmpty ? $0.ip : $0.name) (\(Int(($0.ping ?? 0).rounded())) ms)" }.joined(separator: ", ")
                + ". Weak Wi-Fi signal or a busy device.")
        }

        // 7. Saved devices that aren't answering
        step = "Checking your saved devices…"
        let saved = store.here
        if !saved.isEmpty {
            let aliveSet = Set(hosts.map(\.ip))
            let ports: [String: UInt16] = ["sonos": 1400, "roku": 8060, "samsung": 8001, "wemo": 49153, "wled": 80, "firetv": 8009, "adb": 5555]
            var down: [String] = []
            for d in saved where !aliveSet.contains(d.ip) {
                var up = false
                if let p = ports[d.type] { up = (try? await blocking { LowNet.tcpOpen(d.ip, p, timeoutMs: 800) }) ?? false }
                if !up { down.append(d.name) }
            }
            if down.isEmpty { add("Saved devices", .good, "All \(saved.count) saved devices here answered.") }
            else { add("Saved devices not answering", .ok, down.prefix(6).joined(separator: ", ") + ". They may be off, asleep, or have a new IP address (run Discover).") }
        }
        step = ""
    }
}
