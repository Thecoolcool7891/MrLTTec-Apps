import SwiftUI
import UIKit
import UserNotifications

/// Study mode, Remind, schedule, Toast's notebook, recap, settings.
struct MoreView: View {
    var body: some View {
        Screen {
            Card {
                MoreLink(title: "Study mode", subtitle: "Toast quizzes you, one question at a time", icon: "brain.head.profile") {
                    StudyView()
                }
                Divider()
                MoreLink(title: "Remind", subtitle: "What your teachers posted", icon: "megaphone.fill") {
                    RemindFeedView()
                }
                Divider()
                MoreLink(title: "Schedule", subtitle: "Any day's classes and bells", icon: "calendar") {
                    ScheduleView()
                }
            }
            Card {
                MoreLink(title: "Weekly recap", subtitle: "Due, tests, grades that moved, missing work", icon: "chart.line.uptrend.xyaxis") {
                    TextJobView(title: "Weekly recap", path: "/api/recap",
                                hint: "Also sent by itself every Sunday at 6pm.")
                }
                Divider()
                MoreLink(title: "Morning brief", subtitle: "The 7am text, right now", icon: "sun.max.fill") {
                    TextJobView(title: "Morning brief", path: "/api/brief",
                                hint: "Also sent by itself at 7am on school days.")
                }
            }
            Card {
                MoreLink(title: "Toast's notebook", subtitle: "What Toast remembers about you", icon: "book.closed.fill") {
                    MemoryView()
                }
                Divider()
                MoreLink(title: "Late work rules", subtitle: "Each teacher's late penalty", icon: "clock.badge.exclamationmark") {
                    LateRulesView()
                }
                Divider()
                MoreLink(title: "Settings", subtitle: "Server, notifications, sign out", icon: "gearshape.fill") {
                    SettingsView()
                }
            }
        }
        .navigationTitle("More")
    }
}

struct MoreLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Tan.brown)
                    .frame(width: 34, height: 34)
                    .background(Tan.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.text)
                    Text(subtitle).font(.caption).foregroundStyle(Tan.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tan.faint)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Study mode

struct StudyView: View {
    @EnvironmentObject var model: AppModel
    @State private var topic = ""
    @State private var count = 10
    @State private var current: QuizState?
    @State private var history: [QuizDone] = []
    @State private var problem: String?

    var body: some View {
        Screen {
            if let q = current {
                QuizCard(quiz: q)
            }
            Card(title: "New quiz", icon: "brain.head.profile") {
                TextField("What's it on? (WH ch 8, geo proofs…)", text: $topic)
                    .foregroundStyle(Tan.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Tan.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Picker("Questions", selection: $count) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("15").tag(15)
                    Text("20").tag(20)
                }
                .pickerStyle(.segmented)
                BrownButton(title: "Start quiz", icon: "play.fill") { start(topic) }
                    .opacity(topic.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                Note(text: "Tip: send Toast a photo of your study guide in Chat first, then say \"quiz me on that\".")
            }
            if let tests = model.home?.tests, !tests.isEmpty {
                Card(title: "Quiz for a test", icon: "pencil.and.list.clipboard") {
                    ForEach(tests.prefix(4)) { t in
                        Button {
                            start((t.className + " " + t.title).trimmingCharacters(in: .whitespaces))
                        } label: {
                            HStack {
                                TestRow(test: t)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Tan.brown)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !history.isEmpty {
                Card(title: "Past quizzes", icon: "clock.arrow.circlepath") {
                    ForEach(history.indices, id: \.self) { i in
                        HStack {
                            Text(history[i].topic).font(.subheadline).foregroundStyle(Tan.text).lineLimit(1)
                            Spacer()
                            Text("\(history[i].correct)/\(history[i].asked)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Tan.grade(history[i].percent))
                        }
                    }
                }
            }
            if let p = problem {
                Note(text: p, bad: true)
            }
        }
        .navigationTitle("Study mode")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func start(_ what: String) {
        let t = what.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        model.ask("quiz me on \(t), \(count) questions")
    }

    private func load() async {
        do {
            let r: QuizReply = try await API.get("/api/quiz", timeout: 20)
            current = r.current
            history = r.history
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Remind

struct RemindFeedView: View {
    @State private var days = 7
    @State private var messages: [RemindMessage] = []
    @State private var label = ""
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        Screen {
            Picker("Days", selection: $days) {
                Text("2 days").tag(2)
                Text("Week").tag(7)
                Text("2 weeks").tag(14)
                Text("Month").tag(30)
            }
            .pickerStyle(.segmented)
            if loading && messages.isEmpty {
                ProgressView("Reading Remind…").tint(Tan.brown).padding(.top, 30)
            }
            if let p = problem {
                Card {
                    Note(text: p, bad: true)
                }
            }
            if !loading && messages.isEmpty && problem == nil {
                Card {
                    Note(text: "Nothing on Remind in that time.")
                }
            }
            ForEach(messages.indices, id: \.self) { i in
                RemindCard(msg: messages[i])
            }
            if !label.isEmpty {
                Text("Remind, read " + label + ". Read-only: Toast can't reply there.")
                    .font(.caption)
                    .foregroundStyle(Tan.faint)
            }
        }
        .navigationTitle("Remind")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: days) { await load() }
    }

    private func load() async {
        loading = true
        do {
            let r: RemindReply = try await API.get("/api/remind?days=\(days)", timeout: 90)
            messages = r.messages
            label = r.read_label
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}

struct RemindCard: View {
    let msg: RemindMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(msg.from == "you" ? "You" : msg.from).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.text)
                if msg.announcement {
                    Pill(text: "announcement")
                }
                Spacer()
                Text(msg.when).font(.caption).foregroundStyle(Tan.faint)
            }
            if msg.chat != msg.from {
                Text(msg.chat).font(.caption).foregroundStyle(Tan.muted)
            }
            Text(msg.text).font(.subheadline).foregroundStyle(Tan.text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tanCard()
    }
}

// MARK: - Schedule

struct ScheduleView: View {
    @State private var date = Date()
    @State private var reply: ScheduleReply?
    @State private var problem: String?

    var body: some View {
        Screen {
            Card {
                HStack {
                    Button {
                        shift(-1)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill").font(.title2).foregroundStyle(Tan.brown)
                    }
                    Spacer()
                    DatePicker("Day", selection: $date, displayedComponents: .date).labelsHidden()
                    Spacer()
                    Button {
                        shift(1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill").font(.title2).foregroundStyle(Tan.brown)
                    }
                }
                .buttonStyle(.plain)
            }
            if let r = reply {
                Card(title: "Classes", icon: "calendar", trailing: r.day_color.map { $0 + " day" }) {
                    ScheduleLines(lines: r.lines)
                    if let now = r.right_now {
                        Text(now).font(.caption).foregroundStyle(Tan.green)
                    }
                }
            }
            if let p = problem {
                Card {
                    Note(text: p, bad: true)
                }
            }
        }
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: date) { await load() }
    }

    private func shift(_ days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    private func load() async {
        do {
            let r: ScheduleReply = try await API.get("/api/schedule?day=" + Fmt.day.string(from: date), timeout: 20)
            reply = r
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Recap / brief

struct TextJobView: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let path: String
    let hint: String
    @State private var text: String?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        Screen {
            BrownButton(title: busy ? "Reading Focus + Canvas, about a minute…" : "Make it now", icon: "wand.and.stars",
                        busy: busy) { run() }
            if let t = text {
                Card {
                    Text(t).font(.subheadline).foregroundStyle(Tan.text).textSelection(.enabled)
                }
            }
            if let p = problem {
                Card {
                    Note(text: p, bad: true)
                }
            }
            Text(hint).font(.caption).foregroundStyle(Tan.faint)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        busy = true
        problem = nil
        Task {
            do {
                let r: TextReply = try await API.send(path, timeout: 280)
                text = r.text
                Haptic.done()
            } catch {
                problem = error.localizedDescription
                Haptic.fail()
            }
            busy = false
        }
    }
}

// MARK: - Notebook

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [MemoryItem] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Screen {
            Card(title: "Toast remembers", icon: "book.closed.fill", trailing: "\(items.count)") {
                if items.isEmpty {
                    Note(text: loaded ? "Nothing saved yet. Tell Toast \"remember…\"." : "Loading…")
                }
                ForEach(items) { item in
                    HStack(alignment: .top) {
                        Text(item.text).font(.subheadline).foregroundStyle(Tan.text).textSelection(.enabled)
                        Spacer()
                        Button {
                            forget(item)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Tan.faint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let p = problem {
                Note(text: p, bad: true)
            }
            BrownButton(title: "Tell Toast something to remember", icon: "plus") {
                model.tab = 1
            }
        }
        .navigationTitle("Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let r: MemoryReply = try await API.get("/api/memory", timeout: 20)
            items = r.items
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func forget(_ item: MemoryItem) {
        Task {
            do {
                let r: MemoryReply = try await API.send("/api/memory/\(item.id)", method: "DELETE", timeout: 20)
                items = r.items
                Haptic.tap()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Late rules

struct LateRulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [LateRule] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Screen {
            Card(title: "Late penalties", icon: "clock.badge.exclamationmark") {
                if rules.isEmpty {
                    Note(text: loaded ? "No rules saved yet." : "Loading…")
                }
                ForEach(rules.indices, id: \.self) { i in
                    HStack {
                        Text(rules[i].name).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.text)
                        Spacer()
                        Text(rules[i].rule).font(.caption).foregroundStyle(Tan.muted)
                    }
                }
            }
            Note(text: "Tell Toast each teacher's real rule once, like \"World History takes 11 points off every silver day it's late\". Then ask \"if I turn in the essay 2 days late, what's my grade?\"")
            if let p = problem {
                Note(text: p, bad: true)
            }
            BrownButton(title: "Tell Toast a rule", icon: "bubble.left.fill") {
                model.tab = 1
            }
        }
        .navigationTitle("Late work")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let r: LateRulesReply = try await API.get("/api/late-rules", timeout: 20)
            rules = r.rules
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var server = API.server
    @State private var usage: String?
    @State private var note: String?
    @State private var confirmSignOut = false

    var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        Screen {
            Card(title: "Server", icon: "server.rack") {
                TextField(API.defaultServer, text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .foregroundStyle(Tan.text)
                BrownButton(title: "Save and test", icon: "checkmark") { saveServer() }
                if let n = note {
                    Note(text: n)
                }
                Note(text: "Only reachable with Tailscale on.")
            }
            Card(title: "Notifications", icon: "bell.badge.fill") {
                Note(text: "Telegram is still the fastest way Toast reaches you. This app also checks for new alerts in the background when iOS lets it.")
                BrownButton(title: "Allow notifications", icon: "bell") {
                    Background.askPermission()
                    Background.schedule()
                }
            }
            Card(title: "AI usage", icon: "dollarsign.circle.fill") {
                Text(usage ?? "Loading…").font(.subheadline).foregroundStyle(Tan.text)
            }
            Card(title: "This phone", icon: "iphone") {
                Text("Toast " + version).font(.subheadline).foregroundStyle(Tan.muted)
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tan.bad)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUsage() }
        .confirmationDialog("Sign this phone out of Toast?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadUsage() async {
        do {
            let r: TextReply = try await API.get("/api/usage", timeout: 20)
            usage = r.text
        } catch {
            usage = error.localizedDescription
        }
    }

    private func saveServer() {
        API.server = server
        server = API.server
        note = "Testing…"
        Task {
            do {
                let _: OkReply = try await API.send("/api/health", method: "GET", auth: false, timeout: 10)
                note = "Connected ✅"
                Haptic.done()
                await model.refreshAll()
            } catch {
                note = error.localizedDescription
                Haptic.fail()
            }
        }
    }
}
