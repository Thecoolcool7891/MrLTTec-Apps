import Foundation
import Security

/// Talks to the Toast Bot server (FastAPI on the mini PC) over Tailscale.
/// Sign-in: a 6-digit code Toast texts you on Telegram (/app) is traded for a device token, kept in the Keychain.

struct APIError: LocalizedError {
    let message: String
    var status: Int = 0
    var errorDescription: String? { message }
}

extension Notification.Name {
    static let toastSignedOut = Notification.Name("toastSignedOut")
}

enum Keychain {
    private static let service = "com.mrlttec.toast"
    private static let fallbackPrefix = "kc_"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        // Some sideload signers leave the Keychain unusable; then the token sits in the app's own settings.
        return UserDefaults.standard.string(forKey: fallbackPrefix + key)
    }

    static func set(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackPrefix + key)
        }
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
    }
}

enum API {
    /// The mini PC's Tailscale address (same one MrLTTec Control uses). Changeable in Settings.
    static let defaultServer = "http://100.67.247.123:8787"

    static var server: String {
        get {
            let s = UserDefaults.standard.string(forKey: "server") ?? ""
            return s.isEmpty ? defaultServer : s
        }
        set { UserDefaults.standard.set(clean(newValue), forKey: "server") }
    }

    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static var token: String? {
        let t = Keychain.get("token") ?? ""
        return t.isEmpty ? nil : t
    }

    static func signOut() { Keychain.delete("token") }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 240
        c.timeoutIntervalForResource = 300
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func query(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func data(_ path: String, method: String = "GET", json: [String: Any]? = nil, auth: Bool = true,
                     timeout: TimeInterval = 60) async throws -> Data {
        guard let url = URL(string: server + path) else { throw APIError(message: "The server address isn't valid.") }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        if auth {
            guard let t = token else { throw APIError(message: "Not signed in.", status: 401) }
            r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        }
        if let json = json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let body: Data
        let resp: URLResponse
        do {
            let pair = try await session.data(for: r)
            body = pair.0
            resp = pair.1
        } catch {
            throw APIError(message: friendly(error))
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 && auth {
            NotificationCenter.default.post(name: .toastSignedOut, object: nil)
            throw APIError(message: "Toast signed this phone out. Sign in again with a new code.", status: 401)
        }
        if code < 200 || code >= 300 { throw APIError(message: errorText(body, code), status: code) }
        return body
    }

    static func get<T: Decodable>(_ path: String, timeout: TimeInterval = 60) async throws -> T {
        let d = try await data(path, timeout: timeout)
        return try decode(d)
    }

    static func send<T: Decodable>(_ path: String, method: String = "POST", json: [String: Any]? = nil,
                                   auth: Bool = true, timeout: TimeInterval = 60) async throws -> T {
        let d = try await data(path, method: method, json: json, auth: auth, timeout: timeout)
        return try decode(d)
    }

    static func decode<T: Decodable>(_ d: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: d)
        } catch {
            throw APIError(message: "Toast sent something this app version doesn't understand. Try updating the app.")
        }
    }

    /// Alerts Toast sent on its own after note number `after`. Empty on any error.
    static func notes(after: Int, timeout: TimeInterval) async -> [NoteItem] {
        do {
            let r: NotesReply = try await get("/api/notifications?after=\(after)", timeout: timeout)
            return r.items
        } catch {
            return []
        }
    }

    static func errorText(_ d: Data, _ code: Int) -> String {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let s = o["detail"] as? String, !s.isEmpty { return s }
            if let list = o["detail"] as? [[String: Any]], let first = list.first, let msg = first["msg"] as? String {
                return msg
            }
        }
        return "Toast answered with error \(code)."
    }

    static func friendly(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut:
                return "Toast took too long to answer. Try again."
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return "Can't reach Toast. Is Tailscale on, and is the mini PC on?"
            case .cancelled:
                return "Cancelled."
            default:
                return "Network problem: " + e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

// MARK: - What the server sends

struct OkReply: Decodable { let ok: Bool? }
struct TextReply: Decodable { let text: String }
struct PairReply: Decodable { let token: String }

struct GradeClass: Decodable, Identifiable, Hashable {
    let name: String
    let course: String
    let teacher: String
    let percent: Double?
    let letter: String
    let grade: String
    let honors: Bool
    let bad: Bool
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "class"
        case course, teacher, percent, letter, grade, honors, bad
    }
}

struct GPA: Decodable {
    let unweighted: Double?
    let weighted: Double?
}

struct GradesData: Decodable {
    let read_label: String
    let live: Bool
    let quarter: String
    let fried: Bool
    let gpa: GPA
    let classes: [GradeClass]
}

struct CategoryItem: Decodable {
    let name: String
    let weight: Double?
    let score: String
}

struct AssignmentItem: Decodable {
    let name: String
    let category: String
    let score: String
    let percent: Double?
    let missing: Bool
    let zero: Bool
    let late: Bool
    let due: String
}

struct ZeroItem: Decodable {
    let name: String
    let gain: Double?
    let class_goes_to: Double?
}

struct ClassDetail: Decodable {
    let read_label: String
    let name: String
    let course: String
    let teacher: String
    let grade: String
    let percent: Double?
    let honors: Bool
    let exact: Double?
    let categories: [CategoryItem]
    let assignments: [AssignmentItem]
    let zeros: [ZeroItem]

    enum CodingKeys: String, CodingKey {
        case name = "class"
        case read_label, course, teacher, grade, percent, honors, exact, categories, assignments, zeros
    }
}

struct TestItem: Decodable, Identifiable {
    let id: Int
    let date: String
    let when: String
    let days_left: Int
    let className: String
    let title: String
    let source: String
    let detail: String

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case id, date, when, days_left, title, source, detail
    }
}

struct TestsReply: Decodable { let tests: [TestItem] }

struct GoalNeed: Decodable {
    let category: String
    let need: Double?
}

struct GoalItem: Decodable, Identifiable {
    let name: String
    let target: Double
    let target_letter: String?
    let now: String
    let now_percent: Double?
    let reached: Bool
    let gap: Double?
    let zeros: Int?
    let if_zeros_fixed: String?
    let next_assignment: [GoalNeed]?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "class"
        case target, target_letter, now, now_percent, reached, gap, zeros, if_zeros_fixed, next_assignment
    }
}

struct GoalsReply: Decodable {
    let goals: [GoalItem]
    let read_label: String?
}

struct ReminderItem: Decodable, Identifiable {
    let id: Int
    let text: String
    let when: String
    let `repeat`: String
}

struct RemindersReply: Decodable { let reminders: [ReminderItem] }

struct DueItem: Decodable, Identifiable {
    let id: Int
    let className: String
    let name: String
    let due_at: String
    let due: String
    let past_due: Bool
    let turned_in: Bool
    let missing: Bool
    let points: Double?
    let url: String

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case id, name, due_at, due, past_due, turned_in, missing, points, url
    }
}

struct DueReply: Decodable {
    let read_label: String
    let items: [DueItem]
}

struct QuizState: Decodable {
    let topic: String
    let total: Int
    let asked: Int
    let correct: Int
}

struct QuizDone: Decodable {
    let topic: String
    let asked: Int
    let correct: Int
    let total: Int
    let percent: Double?
    let ended: String
}

struct QuizReply: Decodable {
    let current: QuizState?
    let history: [QuizDone]
}

struct HomeData: Decodable {
    let date_label: String
    let day_color: String?
    let school_today: Bool?
    let right_now: String?
    let schedule: [String]
    let tomorrow: [String]
    let tests: [TestItem]
    let reminders: [ReminderItem]
    let goals: [GoalItem]
    let grades: GradesData?
    let quiz: QuizState?
    let health: [String: String]
}

struct ScheduleReply: Decodable {
    let date: String
    let day_color: String?
    let lines: [String]
    let right_now: String?
}

struct RemindMessage: Decodable {
    let chat: String
    let from: String
    let when: String
    let text: String
    let announcement: Bool

    enum CodingKeys: String, CodingKey {
        case chat = "class"
        case from, when, text, announcement
    }
}

struct RemindReply: Decodable {
    let read_label: String
    let messages: [RemindMessage]
}

struct MemoryItem: Decodable, Identifiable {
    let id: Int
    let text: String
}

struct MemoryReply: Decodable { let items: [MemoryItem] }

struct LateRule: Decodable {
    let name: String
    let rule: String

    enum CodingKeys: String, CodingKey {
        case name = "class"
        case rule
    }
}

struct LateRulesReply: Decodable { let rules: [LateRule] }

struct HistoryItem: Decodable {
    let id: Int
    let ts: String
    let role: String
    let text: String
    let source: String
    let kind: String
}

struct HistoryReply: Decodable {
    let items: [HistoryItem]
    let last_note_id: Int
}

struct NoteItem: Decodable {
    let id: Int
    let ts: String
    let kind: String
    let text: String
}

struct NotesReply: Decodable { let items: [NoteItem] }

struct ChatReply: Decodable {
    let reply: String
    let heads_up: [String]
    let user_id: Int?
    let reply_id: Int?
}
