import SwiftUI

/// Keeps the last 30 error messages the app showed, so a problem report can include exactly what went wrong.
enum ErrorLog {
    private static let key = "errorLog"

    static func add(_ message: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm:ss a"
        list.append("[\(f.string(from: Date()))] \(message)")
        if list.count > 30 { list.removeFirst(list.count - 30) }
        UserDefaults.standard.set(list, forKey: key)
    }

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct ReportProblemView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var what = ""
    @State private var includeErrors = true
    @State private var includeDevices = true
    @State private var shareText: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                TextField("What happened? What were you trying to do?", text: $what, axis: .vertical)
                    .lineLimit(4...10)
            } header: {
                Text("Describe the problem")
            }

            Section {
                Toggle("Recent error messages (\(ErrorLog.all.count))", isOn: $includeErrors)
                Toggle("Device types on this network", isOn: $includeDevices)
            } header: {
                Text("Include")
            } footer: {
                Text("No passwords, pairing codes or IP addresses are included. Device names are left out too.")
            }

            Section {
                Button { shareText = report() } label: { Label("Send report", systemImage: "paperplane.fill") }
                Button {
                    UIPasteboard.general.string = report(); copied = true; Haptic.success()
                } label: { Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc") }
            } footer: {
                Text("Send it to MrLTTec by Messages, email or however you like.")
            }

            if includeErrors && !ErrorLog.all.isEmpty {
                Section("Recent errors") {
                    ForEach(ErrorLog.all.reversed().prefix(10), id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Button("Clear error history", role: .destructive) { ErrorLog.clear(); includeErrors = false }
                }
            }
        }
        .navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { shareText.map { ReportItem(text: $0) } }, set: { shareText = $0?.text })) { item in
            ShareSheet(items: [item.text]).ignoresSafeArea()
        }
    }

    struct ReportItem: Identifiable { let text: String; var id: Int { text.hashValue } }

    private func report() -> String {
        var s = "MrLTTec Home problem report\n"
        s += "Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")\n"
        s += "iOS: \(UIDevice.current.systemVersion), model: \(Self.model())\n"
        s += "On Wi-Fi: \(store.localAddrs.isEmpty ? "no" : "yes")\n\n"
        s += "What happened:\n\(what.isEmpty ? "(not described)" : what)\n"
        if includeDevices {
            let counts = Dictionary(grouping: store.here, by: { $0.kindName }).map { "\($0.value.count) × \($0.key)" }.sorted()
            s += "\nDevices saved on this network: \(counts.isEmpty ? "none" : counts.joined(separator: ", "))\n"
        }
        if includeErrors {
            let errs = ErrorLog.all.suffix(15)
            s += "\nRecent errors:\n" + (errs.isEmpty ? "(none)\n" : errs.joined(separator: "\n") + "\n")
        }
        // Keep IPs out of the report.
        return s.replacingOccurrences(of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, with: "x.x.x.x", options: .regularExpression)
    }

    static func model() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
