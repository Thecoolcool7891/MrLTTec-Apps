import Foundation

/// Sonos over UPnP SOAP on port 1400 (the same calls the PC page made through /proxy).
enum Sonos {
    static let ns = "urn:schemas-upnp-org:service:"

    enum Svc {
        case av, rc, gr, zt, cd, dp
        var type: String {
            switch self {
            case .av: return "AVTransport:1"
            case .rc: return "RenderingControl:1"
            case .gr: return "GroupRenderingControl:1"
            case .zt: return "ZoneGroupTopology:1"
            case .cd: return "ContentDirectory:1"
            case .dp: return "DeviceProperties:1"
            }
        }
        var path: String {
            switch self {
            case .av: return "/MediaRenderer/AVTransport/Control"
            case .rc: return "/MediaRenderer/RenderingControl/Control"
            case .gr: return "/MediaRenderer/GroupRenderingControl/Control"
            case .zt: return "/ZoneGroupTopology/Control"
            case .cd: return "/MediaServer/ContentDirectory/Control"
            case .dp: return "/DeviceProperties/Control"
            }
        }
        var instance: Bool { self == .av || self == .rc || self == .gr }
    }

    @discardableResult
    static func soap(_ ip: String, _ svc: Svc, _ action: String, _ args: String = "") async throws -> String {
        let iid = svc.instance ? "<InstanceID>0</InstanceID>" : ""
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(ns)\(svc.type)\">\(iid)\(args)</u:\(action)></s:Body></s:Envelope>"
        do {
            return try await Http.call("http://\(ip):1400\(svc.path)", method: "POST", body: Data(body.utf8),
                                       contentType: "text/xml; charset=\"utf-8\"",
                                       headers: ["SOAPAction": "\"\(ns)\(svc.type)#\(action)\""], timeout: 6).text
        } catch {
            throw AppError("The speaker didn't accept that, or couldn't be reached at \(ip).")
        }
    }

    // MARK: Now playing

    struct NowPlaying: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var art: URL?
        var state = ""          // PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING
        var source = ""
        var volume = 0
        var muted = false
        var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    }

    static func sourceType(_ u: String) -> String {
        if u.isEmpty { return "" }
        if u.contains("htastream") { return "TV audio" }
        if u.hasPrefix("x-rincon-queue") { return "Sonos queue" }
        if u.hasPrefix("x-rincon-stream") { return "Line-in" }
        if u.contains("x-sonosapi-stream") || u.contains("radio") { return "Radio" }
        if u.hasPrefix("x-rincon:") { return "Grouped" }
        return "Streaming"
    }

    static func now(_ ip: String) async -> NowPlaying {
        var n = NowPlaying()
        async let vol = try? soap(ip, .rc, "GetVolume", "<Channel>Master</Channel>")
        async let mute = try? soap(ip, .rc, "GetMute", "<Channel>Master</Channel>")
        async let tr = try? soap(ip, .av, "GetTransportInfo")
        async let pos = try? soap(ip, .av, "GetPositionInfo")
        async let media = try? soap(ip, .av, "GetMediaInfo")
        if let v = await vol, let x = xmlTag(v, "CurrentVolume") { n.volume = Int(x) ?? 0 }
        if let m = await mute { n.muted = xmlTag(m, "CurrentMute") == "1" }
        if let t = await tr { n.state = xmlTag(t, "CurrentTransportState") ?? "" }
        if let m = await media { n.source = sourceType(xmlTag(m, "CurrentURI") ?? "") }
        if let p = await pos, let meta = xmlTag(p, "TrackMetaData"), meta != "NOT_IMPLEMENTED" {
            n.title = xmlTag(meta, "dc:title") ?? ""
            n.artist = xmlTag(meta, "dc:creator") ?? ""
            n.album = xmlTag(meta, "upnp:album") ?? ""
            if let stream = xmlTag(meta, "r:streamContent"), !stream.isEmpty {
                n.artist = n.title; n.title = stream
            }
            if let a = xmlTag(meta, "upnp:albumArtURI") {
                n.art = a.hasPrefix("/") ? URL(string: "http://\(ip):1400\(a)") : URL(string: a)
            }
            if n.title.hasPrefix("x-sonos") || n.title.hasPrefix("x-rincon") { n.title = "" }
        }
        return n
    }

    // MARK: Simple controls

    static func play(_ ip: String) async throws { try await soap(ip, .av, "Play", "<Speed>1</Speed>") }
    static func pause(_ ip: String) async throws { try await soap(ip, .av, "Pause") }
    static func next(_ ip: String) async throws { try await soap(ip, .av, "Next") }
    static func previous(_ ip: String) async throws { try await soap(ip, .av, "Previous") }
    static func setVolume(_ ip: String, _ v: Int) async throws {
        try await soap(ip, .rc, "SetVolume", "<Channel>Master</Channel><DesiredVolume>\(max(0, min(100, v)))</DesiredVolume>")
    }
    static func setMute(_ ip: String, _ m: Bool) async throws {
        try await soap(ip, .rc, "SetMute", "<Channel>Master</Channel><DesiredMute>\(m ? 1 : 0)</DesiredMute>")
    }

    // MARK: EQ

    struct EQ: Equatable { var bass = 0; var treble = 0; var loudness = true }

    static func eq(_ ip: String) async -> EQ {
        var e = EQ()
        if let b = try? await soap(ip, .rc, "GetBass"), let x = xmlTag(b, "CurrentBass") { e.bass = Int(x) ?? 0 }
        if let t = try? await soap(ip, .rc, "GetTreble"), let x = xmlTag(t, "CurrentTreble") { e.treble = Int(x) ?? 0 }
        if let l = try? await soap(ip, .rc, "GetLoudness", "<Channel>Master</Channel>") { e.loudness = xmlTag(l, "CurrentLoudness") == "1" }
        return e
    }
    static func setBass(_ ip: String, _ v: Int) async throws { try await soap(ip, .rc, "SetBass", "<DesiredBass>\(v)</DesiredBass>") }
    static func setTreble(_ ip: String, _ v: Int) async throws { try await soap(ip, .rc, "SetTreble", "<DesiredTreble>\(v)</DesiredTreble>") }
    static func setLoudness(_ ip: String, _ on: Bool) async throws {
        try await soap(ip, .rc, "SetLoudness", "<Channel>Master</Channel><DesiredLoudness>\(on ? 1 : 0)</DesiredLoudness>")
    }

    // MARK: Speaker info

    struct Info { var room = ""; var model = ""; var uuid = ""; var lines: [String] = [] }

    static func info(_ ip: String) async throws -> Info {
        let x = try await Http.call("http://\(ip):1400/xml/device_description.xml", timeout: 4).text
        var i = Info()
        i.room = xmlTag(x, "roomName") ?? ""
        i.model = xmlTag(x, "displayName") ?? xmlTag(x, "modelName") ?? "Sonos"
        i.uuid = (xmlTag(x, "UDN") ?? "").replacingOccurrences(of: "uuid:", with: "")
        for (label, tag) in [("Room", "roomName"), ("Model", "displayName"), ("Model number", "modelNumber"),
                             ("Software", "displayVersion"), ("Hardware", "hardwareVersion"), ("Serial", "serialNum")] {
            if let v = xmlTag(x, tag) { i.lines.append("\(label): \(v)") }
        }
        return i
    }

    // MARK: Grouping

    struct Member: Identifiable, Hashable { let uuid: String; let name: String; let ip: String; let coordinator: String; var id: String { uuid } }

    static func topology(_ ip: String) async throws -> [Member] {
        let r = try await soap(ip, .zt, "GetZoneGroupState")
        guard let state = xmlTag(r, "ZoneGroupState") else { return [] }
        var out: [Member] = []
        let groupRx = try NSRegularExpression(pattern: "<ZoneGroup\\s+([^>]*)>(.*?)</ZoneGroup>", options: [.dotMatchesLineSeparators])
        let memberRx = try NSRegularExpression(pattern: "<ZoneGroupMember\\s+([^>]*?)/?>")
        for g in groupRx.matches(in: state, range: NSRange(state.startIndex..., in: state)) {
            guard let ar = Range(g.range(at: 1), in: state), let br = Range(g.range(at: 2), in: state) else { continue }
            let coord = attr(String(state[ar]), "Coordinator")
            let body = String(state[br])
            for m in memberRx.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let r = Range(m.range(at: 1), in: body) else { continue }
                let a = String(body[r])
                if attr(a, "Invisible") == "1" { continue }
                let loc = attr(a, "Location")
                let mip = loc.firstMatch(of: #/http:\/\/([\d.]+):/#).map { String($0.1) } ?? ""
                out.append(Member(uuid: attr(a, "UUID"), name: xmlUnescape(attr(a, "ZoneName")), ip: mip, coordinator: coord))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func join(_ ip: String, coordinatorUUID: String) async throws {
        try await soap(ip, .av, "SetAVTransportURI", "<CurrentURI>x-rincon:\(coordinatorUUID)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
    }
    static func leave(_ ip: String) async throws { try await soap(ip, .av, "BecomeCoordinatorOfStandaloneGroup") }

    // MARK: Sources

    static func playLineIn(_ ip: String, uuid: String) async throws {
        try await soap(ip, .av, "SetAVTransportURI", "<CurrentURI>x-rincon-stream:\(uuid)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
        try await play(ip)
    }
    static func playTV(_ ip: String, uuid: String) async throws {
        try await soap(ip, .av, "SetAVTransportURI", "<CurrentURI>x-sonos-htastream:\(uuid):spdif</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
        try await play(ip)
    }

    // MARK: Favorites

    struct Favorite: Identifiable, Hashable { let id = UUID(); let title: String; let uri: String; let meta: String; let art: URL? }

    static func favorites(_ ip: String) async throws -> [Favorite] {
        let r = try await soap(ip, .cd, "Browse", "<ObjectID>FV:2</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>60</RequestedCount><SortCriteria></SortCriteria>")
        guard let didl = xmlTag(r, "Result") else { return [] }
        let rx = try NSRegularExpression(pattern: "<item[^>]*>(.*?)</item>", options: [.dotMatchesLineSeparators])
        var out: [Favorite] = []
        for m in rx.matches(in: didl, range: NSRange(didl.startIndex..., in: didl)) {
            guard let r = Range(m.range(at: 1), in: didl) else { continue }
            let item = String(didl[r])
            guard let title = xmlTag(item, "dc:title") else { continue }
            let uri = xmlTag(item, "res") ?? ""
            let meta = xmlTag(item, "r:resMD") ?? ""
            var art: URL?
            if let a = xmlTag(item, "upnp:albumArtURI") { art = a.hasPrefix("/") ? URL(string: "http://\(ip):1400\(a)") : URL(string: a) }
            out.append(Favorite(title: title, uri: uri, meta: meta, art: art))
        }
        return out
    }

    static func playFavorite(_ ip: String, _ f: Favorite, uuid: String) async throws {
        let isContainer = f.uri.hasPrefix("x-rincon-cpcontainer") || f.uri.hasPrefix("file:") || f.meta.contains("object.container")
        if isContainer {
            try await soap(ip, .av, "RemoveAllTracksFromQueue")
            try await soap(ip, .av, "AddURIToQueue", "<EnqueuedURI>\(xmlEscape(f.uri))</EnqueuedURI><EnqueuedURIMetaData>\(xmlEscape(f.meta))</EnqueuedURIMetaData><DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>")
            try await soap(ip, .av, "SetAVTransportURI", "<CurrentURI>x-rincon-queue:\(uuid)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
        } else {
            try await soap(ip, .av, "SetAVTransportURI", "<CurrentURI>\(xmlEscape(f.uri))</CurrentURI><CurrentURIMetaData>\(xmlEscape(f.meta))</CurrentURIMetaData>")
        }
        try await play(ip)
    }

    // MARK: Sleep timer

    static func setSleep(_ ip: String, minutes: Int) async throws {
        let d = minutes <= 0 ? "" : String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
        try await soap(ip, .av, "ConfigureSleepTimer", "<NewSleepTimerDuration>\(d)</NewSleepTimerDuration>")
    }
    static func sleepRemaining(_ ip: String) async -> String {
        guard let r = try? await soap(ip, .av, "GetRemainingSleepTimerDuration") else { return "" }
        return xmlTag(r, "RemainingSleepTimerDuration") ?? ""
    }
}

func attr(_ s: String, _ name: String) -> String {
    guard let rx = try? NSRegularExpression(pattern: "\\b\(name)=\"([^\"]*)\""),
          let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range(at: 1), in: s) else { return "" }
    return String(s[r])
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
