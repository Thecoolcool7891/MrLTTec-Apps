import SwiftUI

// MARK: - Theme

enum Theme {
    static let gold = Color(red: 0.91, green: 0.63, blue: 0.19)
    static let brown = Color(red: 0.29, green: 0.20, blue: 0.15)
}

enum Haptic {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() { if enabled { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func error() { if enabled { UINotificationFeedbackGenerator().notificationOccurred(.error) } }
}

// MARK: - Device model

enum Category: Int, CaseIterable {
    case media, lights, other
    var title: String {
        switch self {
        case .media: return "Speakers and TVs"
        case .lights: return "Lights and plugs"
        case .other: return "Other"
        }
    }
}

struct Device: Codable, Identifiable, Hashable {
    var type: String
    var ip: String
    var name: String
    var detail: String
    var custom: Bool = false
    var hidden: Bool = false
    var id: String { "\(type)|\(ip)" }

    /// The /24 the device lives on, used to tell "this network" from places you visited before.
    var network: String { ip.split(separator: ".").prefix(3).joined(separator: ".") }

    var kindName: String {
        switch type {
        case "sonos": return "Sonos"
        case "samsung": return "Samsung TV"
        case "roku": return "Roku"
        case "wemo": return "Wemo"
        case "wled": return "WLED"
        case "wiz": return "WiZ light"
        case "wizplug": return "WiZ outlet"
        case "xbox": return "Xbox"
        case "firetv": return "Fire TV"
        case "adb": return "Android TV"
        case "appletv": return "Apple TV"
        default: return type
        }
    }

    var icon: String {
        switch type {
        case "sonos": return "hifispeaker.fill"
        case "samsung", "roku", "firetv", "adb", "appletv": return "tv"
        case "wemo", "wizplug": return "powerplug.fill"
        case "wled": return "light.strip.2"
        case "wiz": return "lightbulb.fill"
        case "xbox": return "gamecontroller.fill"
        default: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch type {
        case "sonos": return Theme.gold
        case "roku": return .purple
        case "samsung": return .blue
        case "wiz": return .yellow
        case "wled": return .pink
        case "wemo", "wizplug": return .green
        case "xbox": return .green
        default: return .gray
        }
    }

    var category: Category {
        switch type {
        case "sonos", "samsung", "roku", "firetv", "adb", "appletv": return .media
        case "wiz", "wled", "wemo", "wizplug": return .lights
        default: return .other
        }
    }

    /// Lights and plugs get an on/off switch right in the list.
    var hasSwitch: Bool { ["wiz", "wled", "wemo", "wizplug"].contains(type) }

    static let types = ["sonos", "samsung", "roku", "wemo", "wled", "wiz", "wizplug", "xbox", "firetv", "adb", "appletv"]
}

// MARK: - Store

@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    @Published private(set) var all: [Device] = []
    @Published var localAddrs: [String] = []

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("saved-devices.json")
    }

    init() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Device].self, from: d) {
            all = list.filter { Device.types.contains($0.type) && isPrivateIp($0.ip) }
        }
        refreshNetwork()
    }

    func refreshNetwork() { localAddrs = LowNet.localAddrs() }

    var currentNetworks: Set<String> { Set(localAddrs.map { $0.split(separator: ".").prefix(3).joined(separator: ".") }) }
    var visible: [Device] { all.filter { !$0.hidden }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var here: [Device] { visible.filter { currentNetworks.contains($0.network) } }
    var elsewhere: [Device] { visible.filter { !currentNetworks.contains($0.network) } }

    func isSaved(_ type: String, _ ip: String) -> Bool { all.contains { $0.type == type && $0.ip == ip && !$0.hidden } }

    private func save() {
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url, options: .atomic) }
    }

    /// Merges scan results. Names you typed are kept; devices you removed stay removed.
    func addFound(_ found: [[String: String]]) {
        for f in found {
            let type = f["type"] ?? "", ip = f["ip"] ?? ""
            guard Device.types.contains(type), isPrivateIp(ip) else { continue }
            var name = cleanName(f["name"] ?? ""); let detail = cleanName(f["detail"] ?? "")
            if name.isEmpty { name = ip }
            if let i = all.firstIndex(where: { $0.type == type && $0.ip == ip }) {
                if !all[i].custom && !all[i].hidden { all[i].name = name; all[i].detail = detail }
            } else {
                all.append(Device(type: type, ip: ip, name: name, detail: detail))
            }
        }
        save()
    }

    /// Saving by hand also brings back a device you removed earlier.
    func add(type: String, ip: String, name: String, detail: String = "") {
        var n = cleanName(name); if n.isEmpty { n = ip }
        if let i = all.firstIndex(where: { $0.type == type && $0.ip == ip }) {
            all[i].name = n; all[i].custom = true; all[i].hidden = false
        } else {
            all.append(Device(type: type, ip: ip, name: n, detail: detail, custom: true))
        }
        save()
    }

    func rename(_ d: Device, to name: String) {
        guard let i = all.firstIndex(where: { $0.id == d.id }) else { return }
        let n = cleanName(name)
        all[i].name = n.isEmpty ? d.ip : n
        all[i].custom = true
        save()
    }

    func remove(_ d: Device) {
        guard let i = all.firstIndex(where: { $0.id == d.id }) else { return }
        all[i].hidden = true
        save()
    }

    func clearAll() { all = []; save() }
}
