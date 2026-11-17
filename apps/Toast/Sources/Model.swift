import BackgroundTasks
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// One bubble in the chat.
struct ChatMsg: Identifiable, Equatable {
    let id: String
    let role: String      // user | assistant | info
    let text: String
    let date: Date?
    let kind: String      // chat | note | local
    let serverId: Int?
    var source: String = ""
}

/// A file picked to send with the next message.
struct Attachment: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let data: Data
    var thumb: UIImage? = nil
}

enum Stamp {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    /// Server timestamps are UTC ISO ("2026-11-17T02:36:07.123456+00:00").
    static func parse(_ ts: String) -> Date? {
        parser.date(from: String(ts.prefix(19)))
    }

    static func label(_ d: Date?) -> String {
        guard let d = d else { return "" }
        if Calendar.current.isDateInToday(d) { return time.string(from: d) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday " + time.string(from: d) }
        return day.string(from: d) + ", " + time.string(from: d)
    }
}

/// Checks for new Toast alerts while the app is closed (iOS decides how often) and shows them as notifications.
enum Background {
    static let taskId = "com.mrlttec.toast.refresh"
    static let lastNoteKey = "lastNoteId"

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: taskId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func show(_ text: String, id: Int) {
        let c = UNMutableNotificationContent()
        c.title = "Toast"
        c.body = text
        c.sound = .default
        let req = UNNotificationRequest(identifier: "note-\(id)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    static func run() async {
        schedule()
        let after = UserDefaults.standard.integer(forKey: lastNoteKey)
        if after <= 0 || API.token == nil { return }
        let items = await API.notes(after: after, timeout: 20)
        if items.isEmpty { return }
        for n in items.suffix(5) {
            show(n.text, id: n.id)
        }
        if let last = items.last {
            UserDefaults.standard.set(last.id, forKey: lastNoteKey)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var paired: Bool = API.token != nil
    @Published var tab: Int = 0

    // Home
    @Published var home: HomeData?
    @Published var homeError: String?
    @Published var due: [DueItem] = []
    @Published var dueLabel: String = ""
    @Published var dueError: String?

    // Grades
    @Published var grades: GradesData?
    @Published var gradesLoading = false
    @Published var gradesError: String?

    // Chat
    @Published var messages: [ChatMsg] = []
    @Published var sending = false
    @Published var unread = 0
    @Published var historyLoaded = false
    @Published var chatError: String?

    private var lastNoteId: Int {
        get { UserDefaults.standard.integer(forKey: Background.lastNoteKey) }
        set { UserDefaults.standard.set(newValue, forKey: Background.lastNoteKey) }
    }

    // MARK: sign in / out

    func pair(code: String, server: String) async throws {
        let cleaned = API.clean(server)
        if !cleaned.isEmpty { API.server = cleaned }
        let name = "Toast app (" + UIDevice.current.model + ")"
        let r: PairReply = try await API.send("/api/pair", json: ["code": code, "name": String(name.prefix(40))],
                                              auth: false, timeout: 20)
        Keychain.set("token", r.token)
        paired = true
        Background.askPermission()
        Background.schedule()
        await refreshAll()
    }

    func signOut() {
        API.signOut()
        paired = false
        home = nil
        grades = nil
        due = []
        messages = []
        historyLoaded = false
        unread = 0
        tab = 0
    }

    // MARK: loading

    func refreshAll() async {
        async let a: Void = loadHome()
        async let b: Void = loadDue()
        async let c: Void = loadHistory()
        _ = await (a, b, c)
    }

    func loadHome() async {
        do {
            let h: HomeData = try await API.get("/api/home", timeout: 25)
            home = h
            homeError = nil
            if grades == nil || grades?.live == false { grades = h.grades }
        } catch {
            homeError = error.localizedDescription
        }
    }

    func loadDue() async {
        do {
            let d: DueReply = try await API.get("/api/due", timeout: 45)
            due = d.items
            dueLabel = d.read_label
            dueError = nil
        } catch {
            dueError = error.localizedDescription
        }
    }

    /// live = a fresh Focus read (a few seconds); otherwise the last read, labelled with its time.
    func loadGrades(live: Bool) async {
        if gradesLoading { return }
        gradesLoading = true
        defer { gradesLoading = false }
        do {
            let g: GradesData = try await API.get("/api/grades?live=" + (live ? "true" : "false"), timeout: 150)
            grades = g
            gradesError = nil
            if live { Haptic.done() }
        } catch {
            gradesError = error.localizedDescription
        }
    }

    // MARK: chat

    func loadHistory() async {
        do {
            let h: HistoryReply = try await API.get("/api/history?limit=120", timeout: 25)
            messages = h.items.map { item in
                ChatMsg(id: item.kind + "-\(item.id)", role: item.role, text: item.text, date: Stamp.parse(item.ts),
                        kind: item.kind, serverId: item.id, source: item.source)
            }
            lastNoteId = max(lastNoteId, h.last_note_id)
            historyLoaded = true
            chatError = nil
        } catch {
            chatError = error.localizedDescription
        }
    }

    /// New alerts/reminders Toast sent on its own since the last look.
    func pollNotes() async {
        if !paired || !historyLoaded { return }
        let items = await API.notes(after: lastNoteId, timeout: 15)
        if items.isEmpty { return }
        for n in items {
            let id = "note-\(n.id)"
            if messages.contains(where: { $0.id == id }) { continue }
            messages.append(ChatMsg(id: id, role: "assistant", text: n.text, date: Stamp.parse(n.ts), kind: "note",
                                    serverId: n.id, source: n.kind))
            if tab != 1 { unread += 1 }
        }
        if let last = items.last { lastNoteId = max(lastNoteId, last.id) }
    }

    /// Jump to the chat tab and send a message (used by buttons all over the app).
    func ask(_ text: String) {
        tab = 1
        unread = 0
        Task { await send(text: text, files: []) }
    }

    func send(text: String, files: [Attachment]) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty && files.isEmpty { return }
        if sending { return }
        sending = true
        defer { sending = false }

        let localId = "local-" + UUID().uuidString
        var shown = clean
        if !files.isEmpty {
            let names = files.map { $0.name }.joined(separator: ", ")
            shown = clean.isEmpty ? "[sent: \(names)]" : clean + "\n[sent: \(names)]"
        }
        messages.append(ChatMsg(id: localId, role: "user", text: shown, date: Date(), kind: "local", serverId: nil))

        var json: [String: Any] = ["text": clean]
        if !files.isEmpty {
            json["files"] = files.map { ["name": $0.name, "type": $0.type, "data": $0.data.base64EncodedString()] }
        }
        do {
            let r: ChatReply = try await API.send("/api/chat", json: json, timeout: 280)
            if let i = messages.firstIndex(where: { $0.id == localId }), let uid = r.user_id {
                messages[i] = ChatMsg(id: "chat-\(uid)", role: "user", text: shown, date: messages[i].date, kind: "chat",
                                      serverId: uid, source: "app")
            }
            let rid = r.reply_id
            let newId = rid == nil ? "local-" + UUID().uuidString : "chat-\(rid ?? 0)"
            messages.append(ChatMsg(id: newId, role: "assistant", text: r.reply, date: Date(),
                                    kind: rid == nil ? "local" : "chat", serverId: rid, source: "app"))
            Haptic.tap()
            // The reply may have changed tests, goals, or reminders.
            Task { await self.loadHome() }
        } catch {
            messages.append(ChatMsg(id: "local-" + UUID().uuidString, role: "info",
                                    text: "Didn't send: " + error.localizedDescription, date: Date(), kind: "local",
                                    serverId: nil))
            Haptic.fail()
        }
    }

    func delete(_ m: ChatMsg) async {
        guard let sid = m.serverId, m.kind == "chat" || m.kind == "note" else {
            messages.removeAll { $0.id == m.id }
            return
        }
        do {
            let _: OkReply = try await API.send("/api/messages/\(m.kind)/\(sid)", method: "DELETE", timeout: 15)
            messages.removeAll { $0.id == m.id }
        } catch let e as APIError where e.status == 404 {
            messages.removeAll { $0.id == m.id }
        } catch {
            chatError = error.localizedDescription
        }
    }
}
