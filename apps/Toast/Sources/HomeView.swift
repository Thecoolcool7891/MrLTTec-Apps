import SwiftUI

/// Today at a glance: schedule, tests, what's due, grades, goals, reminders.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTomorrow = false

    var body: some View {
        Screen {
            if let h = model.home {
                HomeHeader(home: h)
                HealthCard(home: h)
                if let q = h.quiz {
                    QuizCard(quiz: q)
                }
                ScheduleCard(home: h, showTomorrow: $showTomorrow)
                TestsCard(tests: h.tests)
                DueCard()
                GradesCard(grades: model.grades ?? h.grades)
                GoalsCard(goals: h.goals)
                RemindersCard(reminders: h.reminders)
                QuickCard()
            } else if let e = model.homeError {
                Card(title: "Can't load", icon: "wifi.slash") {
                    Note(text: e, bad: true)
                    BrownButton(title: "Try again", icon: "arrow.clockwise") {
                        Task { await model.refreshAll() }
                    }
                }
            } else {
                ProgressView().tint(Tan.brown).padding(.top, 60)
            }
        }
        .navigationTitle("Toast")
        .refreshable { await model.refreshAll() }
    }
}

struct HomeHeader: View {
    let home: HomeData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(home.date_label).font(.title3.weight(.semibold)).foregroundStyle(Tan.text)
                Spacer()
                if let color = home.day_color {
                    Pill(text: color + " day", color: .white, fill: Tan.dayColor(color))
                } else if home.school_today == false {
                    Pill(text: "no school")
                }
            }
            if let now = home.right_now {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill").foregroundStyle(Tan.brown)
                    Text(now).font(.subheadline).foregroundStyle(Tan.text)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// Only shows when Toast can't read one of its sources.
struct HealthCard: View {
    let home: HomeData

    var broken: [String] {
        home.health.filter { $0.value != "ok" }.map { $0.key }.sorted()
    }

    var body: some View {
        if !broken.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tan.bad)
                Text("Toast can't read " + broken.joined(separator: ", ") + " right now.")
                    .font(.subheadline)
                    .foregroundStyle(Tan.bad)
                Spacer()
            }
            .tanCard()
        }
    }
}

struct QuizCard: View {
    @EnvironmentObject var model: AppModel
    let quiz: QuizState

    var body: some View {
        Card(title: "Quiz in progress", icon: "brain.head.profile") {
            Text(quiz.topic).font(.headline).foregroundStyle(Tan.text)
            Text("\(quiz.correct) right out of \(quiz.asked) so far · \(quiz.total) questions")
                .font(.subheadline)
                .foregroundStyle(Tan.muted)
            Meter(value: quiz.total > 0 ? Double(quiz.asked) / Double(quiz.total) : 0)
            BrownButton(title: "Keep going", icon: "arrow.right") { model.tab = 1 }
        }
    }
}

struct ScheduleCard: View {
    let home: HomeData
    @Binding var showTomorrow: Bool

    var lines: [String] { showTomorrow ? home.tomorrow : home.schedule }

    var body: some View {
        Card(title: "Schedule", icon: "calendar") {
            Picker("Day", selection: $showTomorrow) {
                Text("Today").tag(false)
                Text("Tomorrow").tag(true)
            }
            .pickerStyle(.segmented)
            ScheduleLines(lines: lines)
        }
    }
}

/// Renders the schedule text Toast sends ("• 7:40–9:12 Geo (Consbruck)").
struct ScheduleLines: View {
    let lines: [String]

    var body: some View {
        if lines.isEmpty {
            Note(text: "No schedule yet.")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines.indices, id: \.self) { i in
                    row(lines[i], first: i == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ raw: String, first: Bool) -> some View {
        let isNow = raw.contains("← rn")
        let text = raw.replacingOccurrences(of: " ← rn", with: "").replacingOccurrences(of: "• ", with: "")
        if first {
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.text)
        } else {
            HStack(spacing: 8) {
                Circle().fill(isNow ? Tan.green : Tan.crust).frame(width: 7, height: 7)
                Text(text)
                    .font(.subheadline.weight(isNow ? .bold : .regular))
                    .foregroundStyle(isNow ? Tan.green : Tan.text)
                Spacer()
                if isNow {
                    Pill(text: "now", color: Tan.green, fill: Tan.greenBg)
                }
            }
        }
    }
}

struct TestRow: View {
    let test: TestItem

    var urgent: Bool { test.days_left <= 1 }

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Text(test.days_left <= 0 ? "!" : "\(test.days_left)")
                    .font(.headline.bold())
                    .foregroundStyle(urgent ? .white : Tan.chipText)
                Text(test.days_left <= 0 ? "today" : (test.days_left == 1 ? "day" : "days"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(urgent ? .white : Tan.muted)
            }
            .frame(width: 44, height: 44)
            .background(urgent ? Tan.bad : Tan.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(test.title).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.text)
                Text([test.className, test.when].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Tan.muted)
            }
            Spacer()
        }
    }
}

struct TestsCard: View {
    @EnvironmentObject var model: AppModel
    let tests: [TestItem]

    var body: some View {
        Card(title: "Tests", icon: "pencil.and.list.clipboard") {
            if tests.isEmpty {
                Note(text: "No tests coming up. Tell Toast when you have one.")
            } else {
                ForEach(tests.prefix(4)) { t in
                    TestRow(test: t)
                }
                if let next = tests.first, next.days_left <= 2 {
                    Button {
                        model.ask("quiz me for my \(next.className) \(next.title)")
                    } label: {
                        Label("Quiz me for this", systemImage: "brain.head.profile")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tan.brown)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct DueRow: View {
    let item: DueItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.turned_in ? "checkmark.circle.fill" : (item.past_due ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(item.turned_in ? Tan.green : (item.past_due ? Tan.bad : Tan.faint))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(Tan.text)
                    .strikethrough(item.turned_in, color: Tan.faint)
                    .lineLimit(2)
                Text(item.className + " · " + item.due + (item.missing ? " · missing" : ""))
                    .font(.caption)
                    .foregroundStyle(item.past_due && !item.turned_in ? Tan.bad : Tan.muted)
            }
            Spacer()
        }
    }
}

struct DueCard: View {
    @EnvironmentObject var model: AppModel

    var todo: [DueItem] { model.due.filter { !$0.turned_in } }
    var overdue: [DueItem] { todo.filter { $0.past_due } }
    var upcoming: [DueItem] { todo.filter { !$0.past_due } }

    var body: some View {
        Card(title: "Due soon", icon: "tray.full.fill", trailing: model.dueLabel.isEmpty ? nil : "canvas, " + model.dueLabel) {
            if let e = model.dueError, model.due.isEmpty {
                Note(text: e, bad: true)
            } else if todo.isEmpty {
                Note(text: model.dueLabel.isEmpty ? "Checking Canvas…" : "Nothing to turn in this week.")
            } else {
                if !overdue.isEmpty {
                    HStack {
                        Pill(text: "\(overdue.count) past due", color: .white, fill: Tan.bad)
                        Spacer()
                    }
                }
                ForEach(upcoming.prefix(4)) { item in
                    DueRow(item: item)
                }
                Button {
                    model.tab = 3
                } label: {
                    Text("See everything").font(.subheadline.weight(.semibold)).foregroundStyle(Tan.brown)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct GradesCard: View {
    @EnvironmentObject var model: AppModel
    let grades: GradesData?

    var body: some View {
        Card(title: "Grades", icon: "chart.bar.fill", trailing: grades.map { "focus, read " + $0.read_label }) {
            if let g = grades {
                if g.fried {
                    Text("Ngl bro your fried 😭🥀").font(.subheadline.weight(.semibold)).foregroundStyle(Tan.bad)
                }
                HStack(spacing: 18) {
                    GpaNumber(label: "GPA", value: g.gpa.unweighted)
                    GpaNumber(label: "Weighted", value: g.gpa.weighted)
                    Spacer()
                }
                ForEach(g.classes.prefix(3)) { c in
                    HStack {
                        Text(c.name).font(.subheadline).foregroundStyle(Tan.text)
                        Spacer()
                        Text(c.grade).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.grade(c.percent))
                    }
                }
                Button {
                    model.tab = 2
                } label: {
                    Text("All classes").font(.subheadline.weight(.semibold)).foregroundStyle(Tan.brown)
                }
                .buttonStyle(.plain)
            } else {
                Note(text: "No grades read yet. Open the Grades tab.")
            }
        }
    }
}

struct GpaNumber: View {
    let label: String
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.map { String(format: "%.1f", $0) } ?? "–")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Tan.text)
            Text(label).font(.caption).foregroundStyle(Tan.muted)
        }
    }
}

struct GoalRow: View {
    let goal: GoalItem

    var progress: Double {
        guard let now = goal.now_percent, goal.target > 0 else { return 0 }
        return now / goal.target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(goal.name).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.text)
                Spacer()
                Text(goal.now + " → " + String(format: "%g", goal.target) + "% " + (goal.target_letter ?? ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(goal.reached ? Tan.green : Tan.muted)
            }
            Meter(value: progress, color: goal.reached ? Tan.green : Tan.brown)
            Text(detail).font(.caption).foregroundStyle(Tan.muted)
        }
    }

    var detail: String {
        if goal.reached { return "Goal reached 🔥" }
        var parts: [String] = []
        if let gap = goal.gap { parts.append(String(format: "%g", gap) + " points to go") }
        if let z = goal.zeros, z > 0, let fixed = goal.if_zeros_fixed {
            parts.append("fixing \(z) zero" + (z == 1 ? "" : "s") + " gets you to " + fixed)
        }
        if let needs = goal.next_assignment, let first = needs.first, let need = first.need {
            let cat = first.category == "any" ? "" : " " + first.category
            parts.append("or " + String(format: "%g", need) + "/100 on the next" + cat + " grade")
        }
        return parts.isEmpty ? "Open Grades for a live read." : parts.joined(separator: " · ")
    }
}

struct GoalsCard: View {
    let goals: [GoalItem]

    var body: some View {
        if !goals.isEmpty {
            Card(title: "Goals", icon: "target") {
                ForEach(goals) { g in
                    GoalRow(goal: g)
                }
            }
        }
    }
}

struct RemindersCard: View {
    let reminders: [ReminderItem]

    var body: some View {
        if !reminders.isEmpty {
            Card(title: "Reminders", icon: "bell.fill") {
                ForEach(reminders) { r in
                    HStack(alignment: .top) {
                        Text(r.text).font(.subheadline).foregroundStyle(Tan.text)
                        Spacer()
                        Text(r.when + (r.repeat.isEmpty ? "" : " 🔁")).font(.caption).foregroundStyle(Tan.muted)
                    }
                }
            }
        }
    }
}

struct QuickCard: View {
    @EnvironmentObject var model: AppModel

    private let asks: [[String]] = [
        ["What should I do first?", "what should i do first", "list.number"],
        ["Missing work", "what am i missing", "exclamationmark.bubble.fill"],
        ["Quiz me", "quiz me", "brain.head.profile"],
        ["Recap my week", "recap my week", "chart.line.uptrend.xyaxis"],
    ]

    var body: some View {
        Card(title: "Ask Toast", icon: "sparkles") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(asks, id: \.self) { a in
                    Button {
                        Haptic.tap()
                        model.ask(a[1])
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: a[2]).foregroundStyle(Tan.brown)
                            Text(a[0]).font(.footnote.weight(.semibold)).foregroundStyle(Tan.chipText).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tan.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
