import SwiftUI

/// Checks the MrLTTec source for a newer build of this app, downloads it, and hands the IPA to the
/// share sheet so you can open it in your signer (Flare, etc). Works even when the signer changed the
/// app's bundle ID, because it looks the app up by its ORIGINAL ID (passed in), not the installed one.
@MainActor
final class Updater: ObservableObject {
    static let sourceURL = URL(string: "https://github.com/Thecoolcool7891/MrLTTec-Apps/releases/download/source/source.json")!
    /// GitHub's API serves the newest source.json within about a minute (the download links can lag a few minutes).
    static let apiURL = URL(string: "https://api.github.com/repos/Thecoolcool7891/MrLTTec-Apps/contents/source.json")!

    struct Release: Equatable { let version: String; let notes: String; let url: URL; let size: Int }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Double), ready(URL), failed(String)
    }

    @Published var state: State = .idle
    let bundleId: String
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    init(bundleId: String) { self.bundleId = bundleId }

    var available: Release? { if case .available(let r) = state { return r }; return nil }

    func check() async {
        switch state {
        case .downloading, .ready, .available: return   // keep an open update sheet steady
        default: state = .checking
        }
        do {
            var api = URLRequest(url: Self.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            api.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            var data: Data
            if let res = try? await URLSession.shared.data(for: api), (res.1 as? HTTPURLResponse)?.statusCode == 200 {
                data = res.0
            } else {
                var req = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                (data, _) = try await URLSession.shared.data(for: req)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = root["apps"] as? [[String: Any]],
                  let app = apps.first(where: { $0["bundleIdentifier"] as? String == bundleId }) else {
                state = .failed("This app isn't in the source.")
                return
            }
            let v = (app["versions"] as? [[String: Any]])?.first
            let version = v?["version"] as? String ?? app["version"] as? String ?? ""
            let link = v?["downloadURL"] as? String ?? app["downloadURL"] as? String ?? ""
            guard let url = URL(string: link), !version.isEmpty else { state = .failed("The source has no download for this app."); return }
            if Self.isNewer(version, than: current) {
                state = .available(Release(version: version, notes: v?["localizedDescription"] as? String ?? "",
                                            url: url, size: v?["size"] as? Int ?? 0))
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("Couldn't check for updates. Are you online?")
        }
    }

    func download(_ r: Release) async {
        state = .downloading(0)
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(from: r.url)
            let total = max(Int(resp.expectedContentLength), r.size, 1)
            var data = Data()
            data.reserveCapacity(total)
            var last = 0.0
            for try await b in bytes {
                data.append(b)
                if data.count % 65536 == 0 {
                    let p = min(1, Double(data.count) / Double(total))
                    if p - last > 0.02 { last = p; state = .downloading(p) }
                }
            }
            let name = r.url.lastPathComponent.isEmpty ? "update.ipa" : r.url.lastPathComponent
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: file)
            try data.write(to: file)
            state = .ready(file)
        } catch {
            state = .failed("The download didn't finish. Try again.")
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// Banner shown when a newer version is in the source.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    @State private var showSheet = false

    var body: some View {
        if let r = updater.available {
            Button { showSheet = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update \(r.version) available").font(.subheadline.weight(.semibold))
                        Text("You have \(updater.current). Tap to get it.").font(.caption).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .padding(14)
                .foregroundStyle(.white)
                .background(.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSheet) { UpdateSheet(updater: updater) }
        }
    }
}

struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    @State private var release: Updater.Release?
    @State private var notFound = false

    /// Flare Store's app link. We try the likely ones in order, then fall back to its website.
    static let flareLinks = ["flarestore://", "flare://", "flare-store://"]
    static let flareWeb = URL(string: "https://flarestore.app")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.app.fill").font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 20)
                Text("Version \(release?.version ?? "") is out").font(.title2.weight(.bold))
                if let n = release?.notes, !n.isEmpty {
                    Text(n).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Open Flare Store")
                    step(2, "Go to Library")
                    step(3, "Press this app")
                    step(4, "Tap Update")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 24)

                Spacer()

                Button { openFlare() } label: {
                    Label("Open Flare Store", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal, 30)

                if notFound {
                    Text("Couldn't open the Flare Store app, so its website opened instead. Open Flare Store from your Home Screen.")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                Text("You have \(updater.current). Your saved devices stay after updating.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }
            .navigationTitle("Update available")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .onAppear { release = updater.available ?? release }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(.tint, in: Circle())
            Text(text).font(.body)
        }
    }

    private func openFlare(_ i: Int = 0) {
        guard i < Self.flareLinks.count, let u = URL(string: Self.flareLinks[i]) else {
            notFound = true
            UIApplication.shared.open(Self.flareWeb)
            return
        }
        UIApplication.shared.open(u) { ok in if !ok { openFlare(i + 1) } }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Row for a Settings screen: shows the version and lets you check by hand.
struct UpdateSettingsRow: View {
    @ObservedObject var updater: Updater
    @State private var showSheet = false
    var body: some View {
        Group {
            LabeledContent("Version", value: updater.current)
            Button {
                if updater.available != nil { showSheet = true } else { Task { await updater.check() } }
            } label: {
                HStack {
                    Text(updater.available != nil ? "Get update \(updater.available!.version)" : "Check for updates")
                    Spacer()
                    switch updater.state {
                    case .checking: ProgressView()
                    case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                    case .failed(let m): Text(m).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    default: EmptyView()
                    }
                }
            }
            .sheet(isPresented: $showSheet) { UpdateSheet(updater: updater) }
        }
    }
}
