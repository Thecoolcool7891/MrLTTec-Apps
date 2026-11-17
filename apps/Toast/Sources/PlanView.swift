import SwiftUI

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let minute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
}

/// Due work, tests, goals and reminders.
struct PlanView: View {
    @EnvironmentObject var model: AppModel
    @State private var section = 0

    var body: some View {
        Screen {
            Picker("Section", selection: $section) {
                Text("Due").tag(0)
                Text("Tests").tag(1)
                Text("Goals").tag(2)
                Text("Reminders").tag(3)
            }
            .pickerStyle(.segmented)
            if section == 0 {
                DueSection()
            } else if section == 1 {
                TestsSection()
            } else if section == 2 {
                GoalsSection()
            } else {
                RemindersSection()
            }
        }
        .navigationTitle("Plan")
        .refreshable { await model.refreshAll() }
    }
}

// MARK: - Due

struct DueSection: View {
    @EnvironmentObject var model: AppModel

    var overdue: [DueItem] { model.due.filter { $0.past_due && !$0.turned_in } }
    var todo: [DueItem] { model.due.filter { !$0.past_due && !$0.turned_in } }
    var done: [DueItem] { model.due.filter { !$0.past_due && $0.turned_in } }

    var body: some View {
        if let e = model.dueError {
            Card(title: "Canvas problem", icon: "exclamationmark.triangle.fill") {
                Note(text: e, bad: true)
            }
        }
        if !overdue.isEmpty {
            DueGroup(title: "Past due, not turned in", icon: "exclamationmark.circle.fill", items: overdue)
        }
        if !todo.isEmpty {
            DueGroup(title: "Coming up", icon: "tray.full.fill", items: todo)
        }
        if !done.isEmpty {
            DueGroup(title: "Already turned in", icon: "checkmark.circle.fill", items: done)
        }
        if model.due.isEmpty && model.dueError == nil {
            Card {
                Note(text: model.dueLabel.isEmpty ? "Checking Canvas…" : "Nothing due this week. You're chillin 😎")
            }
        }
        if !model.dueLabel.isEmpty {
            Text("Canvas, checked " + model.dueLabel).font(.caption).foregroundStyle(Tan.faint)
        }
    }
}

struct DueGroup: View {
    let title: String
    let icon: String
    let items: [DueItem]

    var body: some View {
        Card(title: title, icon: icon, trailing: "\(items.count)") {
            ForEach(items) { item in
                if let url = URL(string: item.url), !item.url.isEmpty {
                    Link(destination: url) {
                        DueRow(item: item)
                    }
                    .buttonStyle(.plain)
                } else {
                    DueRow(item: item)
                }
            }
        }
    }
}

// MARK: - Tests

struct TestsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var tests: [TestItem] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        Card(title: "Upcoming tests", icon: "pencil.and.list.clipboard") {
            if tests.isEmpty {
                Note(text: loaded ? "No tests on your list. Toast adds the ones teachers post on Remind." : "Loading…")
            }
            ForEach(tests) { t in
                HStack {
                    TestRow(test: t)
                    Button {
                        remove(t)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(Tan.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let p = problem {
                Note(text: p, bad: true)
            }
        }
        BrownButton(title: "Add a test", icon: "plus") { adding = true }
        Text("Toast texts you at 7pm the night before, and puts tests in your 7am brief.")
            .font(.caption)
            .foregroundStyle(Tan.faint)
            .task { await load() }
            .sheet(isPresented: $adding) {
                AddTestSheet(classes: model.grades?.classes.map { $0.name } ?? []) { list in
                    tests = list
                    Task { await model.loadHome() }
                }
            }
    }

    private func load() async {
        do {
            let r: TestsReply = try await API.get("/api/tests", timeout: 20)
            tests = r.tests
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func remove(_ t: TestItem) {
        Task {
            do {
                let r: TestsReply = try await API.send("/api/tests/\(t.id)", method: "DELETE", timeout: 20)
                tests = r.tests
                Haptic.tap()
                await model.loadHome()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct AddTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let classes: [String]
    let saved: ([TestItem]) -> Void
    @State private var title = ""
    @State private var className = ""
    @State private var date = Date().addingTimeInterval(86400)
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    TextField("Ch. 8 Test", text: $title)
                    Picker("Class", selection: $className) {
                        Text("None").tag("")
                        ForEach(classes, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                }
                Section("When") {
                    DatePicker("Day", selection: $date, in: Date()..., displayedComponents: .date)
                }
                if let p = problem {
                    Section {
                        Text(p).foregroundStyle(Tan.bad)
                    }
                }
            }
            .navigationTitle("Add a test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        busy = true
        let body: [String: Any] = ["date": Fmt.day.string(from: date), "class_name": className, "title": title]
        Task {
            do {
                let r: TestsReply = try await API.send("/api/tests", json: body, timeout: 20)
                saved(r.tests)
                Haptic.done()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Goals

struct GoalsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var goals: [GoalItem] = []
    @State private var label: String?
    @State private var loaded = false
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        Card(title: "Grade goals", icon: "target", trailing: label.map { "focus, read " + $0 }) {
            if goals.isEmpty {
                Note(text: loaded ? "No goals yet. Pick a class and a grade to aim for." : "Loading…")
            }
            ForEach(goals) { g in
                HStack(alignment: .top) {
                    GoalRow(goal: g)
                    Button {
                        remove(g)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(Tan.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let p = problem {
                Note(text: p, bad: true)
            }
        }
        BrownButton(title: "Add a goal", icon: "plus") { adding = true }
        Text("Toast texts you whenever a goal class's grade moves.")
            .font(.caption)
            .foregroundStyle(Tan.faint)
            .task { await load() }
            .sheet(isPresented: $adding) {
                AddGoalSheet(classes: model.grades?.classes.map { $0.name } ?? []) { reply in
                    goals = reply.goals
                    label = reply.read_label
                    Task { await model.loadHome() }
                }
            }
    }

    private func load() async {
        do {
            let r: GoalsReply = try await API.get("/api/goals", timeout: 20)
            goals = r.goals
            label = r.read_label
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func remove(_ g: GoalItem) {
        Task {
            do {
                let r: GoalsReply = try await API.send("/api/goals?class_name=" + API.query(g.name), method: "DELETE",
                                                       timeout: 20)
                goals = r.goals
                Haptic.tap()
                await model.loadHome()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct AddGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let classes: [String]
    let saved: (GoalsReply) -> Void
    @State private var className = ""
    @State private var target = "B"
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Class") {
                    if classes.isEmpty {
                        TextField("Class name", text: $className)
                    } else {
                        Picker("Class", selection: $className) {
                            Text("Pick one").tag("")
                            ForEach(classes, id: \.self) { c in
                                Text(c).tag(c)
                            }
                        }
                    }
                }
                Section("Goal") {
                    Picker("Grade", selection: $target) {
                        Text("A (90%)").tag("A")
                        Text("B (80%)").tag("B")
                        Text("C (70%)").tag("C")
                        Text("D (60%)").tag("D")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text(busy ? "Reading Focus live, a few seconds…" : "Saving reads this class live from Focus.")
                        .font(.footnote)
                        .foregroundStyle(Tan.muted)
                    if let p = problem {
                        Text(p).foregroundStyle(Tan.bad)
                    }
                }
            }
            .navigationTitle("Add a goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(busy || className.isEmpty)
                }
            }
        }
    }

    private func save() {
        busy = true
        problem = nil
        let body: [String: Any] = ["class_name": className, "target": target]
        Task {
            do {
                let r: GoalsReply = try await API.send("/api/goals", json: body, timeout: 150)
                saved(r)
                Haptic.done()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Reminders

struct RemindersSection: View {
    @EnvironmentObject var model: AppModel
    @State private var reminders: [ReminderItem] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        Card(title: "Reminders", icon: "bell.fill") {
            if reminders.isEmpty {
                Note(text: loaded ? "No reminders set." : "Loading…")
            }
            ForEach(reminders) { r in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.text).font(.subheadline).foregroundStyle(Tan.text)
                        Text(r.when + (r.repeat.isEmpty ? "" : " · 🔁 " + r.repeat))
                            .font(.caption)
                            .foregroundStyle(Tan.muted)
                    }
                    Spacer()
                    Button {
                        cancel(r)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(Tan.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let p = problem {
                Note(text: p, bad: true)
            }
        }
        BrownButton(title: "Add a reminder", icon: "plus") { adding = true }
        Text("Reminders arrive on Telegram and here in the chat.")
            .font(.caption)
            .foregroundStyle(Tan.faint)
            .task { await load() }
            .sheet(isPresented: $adding) {
                AddReminderSheet { list in
                    reminders = list
                    Task { await model.loadHome() }
                }
            }
    }

    private func load() async {
        do {
            let r: RemindersReply = try await API.get("/api/reminders", timeout: 20)
            reminders = r.reminders
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func cancel(_ item: ReminderItem) {
        Task {
            do {
                let r: RemindersReply = try await API.send("/api/reminders/\(item.id)", method: "DELETE", timeout: 20)
                reminders = r.reminders
                Haptic.tap()
                await model.loadHome()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct AddReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let saved: ([ReminderItem]) -> Void
    @State private var text = ""
    @State private var when = Date().addingTimeInterval(3600)
    @State private var repeatRule = ""
    @State private var busy = false
    @State private var problem: String?

    private let rules: [[String]] = [
        ["", "One time"], ["daily", "Every day"], ["weekdays", "Weekdays"], ["school_days", "School days"],
        ["silver_days", "Silver days"], ["burgundy_days", "Burgundy days"], ["weekly", "Every week"],
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Remind me to") {
                    TextField("pack my bag", text: $text)
                }
                Section("When") {
                    DatePicker("Time", selection: $when)
                    Picker("Repeat", selection: $repeatRule) {
                        ForEach(rules, id: \.self) { r in
                            Text(r[1]).tag(r[0])
                        }
                    }
                }
                if let p = problem {
                    Section {
                        Text(p).foregroundStyle(Tan.bad)
                    }
                }
            }
            .navigationTitle("Add a reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        busy = true
        problem = nil
        let body: [String: Any] = ["when": Fmt.minute.string(from: when), "text": text, "repeat": repeatRule]
        Task {
            do {
                let r: RemindersReply = try await API.send("/api/reminders", json: body, timeout: 20)
                saved(r.reminders)
                Haptic.done()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}
