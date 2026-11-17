import SwiftUI

/// Every class with its grade, plus GPA. Always says when Focus was read; pull down for a live read.
struct GradesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Screen {
            if let g = model.grades {
                GradesSummary(grades: g, loading: model.gradesLoading)
                ForEach(g.classes) { c in
                    NavigationLink(value: c) {
                        ClassRow(item: c)
                    }
                    .buttonStyle(.plain)
                }
                BrownButton(title: "What's my GPA if…", icon: "function") {
                    model.ask("whats my gpa and what would it take to raise it")
                }
            } else if model.gradesLoading {
                ProgressView("Reading Focus…").tint(Tan.brown).padding(.top, 60)
            } else if model.gradesError == nil {
                Note(text: "No grades yet. Pull down to read Focus.")
            }
            if let e = model.gradesError {
                Card(title: "Focus problem", icon: "exclamationmark.triangle.fill") {
                    Note(text: e, bad: true)
                }
            }
        }
        .navigationTitle("Grades")
        .navigationDestination(for: GradeClass.self) { c in
            ClassDetailView(summary: c)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.loadGrades(live: true) }
                } label: {
                    if model.gradesLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.gradesLoading)
            }
        }
        .refreshable { await model.loadGrades(live: true) }
        .task {
            if model.grades == nil { await model.loadGrades(live: false) }
        }
    }
}

struct GradesSummary: View {
    let grades: GradesData
    let loading: Bool

    var body: some View {
        Card(title: grades.quarter, icon: "graduationcap.fill") {
            if grades.fried {
                Text("Ngl bro your fried 😭🥀").font(.headline).foregroundStyle(Tan.bad)
            }
            HStack(spacing: 22) {
                GpaNumber(label: "GPA", value: grades.gpa.unweighted)
                GpaNumber(label: "Weighted", value: grades.gpa.weighted)
                Spacer()
            }
            HStack(spacing: 6) {
                Circle().fill(grades.live ? Tan.green : Tan.gold).frame(width: 7, height: 7)
                Text(loading ? "Reading Focus now…"
                     : (grades.live ? "Live from Focus, " + grades.read_label
                        : "Read from Focus at " + grades.read_label + ". Pull down for live."))
                    .font(.caption)
                    .foregroundStyle(Tan.muted)
            }
            Text("This quarter only, not your transcript GPA.").font(.caption2).foregroundStyle(Tan.faint)
        }
    }
}

struct ClassRow: View {
    let item: GradeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.name).font(.headline).foregroundStyle(Tan.text)
                if item.honors {
                    Pill(text: "Honors", color: Tan.gold)
                }
                Spacer()
                Text(item.grade)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Tan.grade(item.percent))
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tan.faint)
            }
            Meter(value: (item.percent ?? 0) / 100, color: Tan.grade(item.percent))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tanCard()
    }
}

/// One class, read live from Focus: zeros worth fixing, categories, every assignment.
struct ClassDetailView: View {
    @EnvironmentObject var model: AppModel
    let summary: GradeClass
    @State private var detail: ClassDetail?
    @State private var problem: String?
    @State private var loading = false
    @State private var goalNote: String?

    var body: some View {
        Screen {
            header
            if let d = detail {
                if !d.zeros.isEmpty {
                    zerosCard(d)
                }
                if !d.categories.isEmpty {
                    categoriesCard(d)
                }
                assignmentsCard(d)
            } else if loading {
                ProgressView("Reading Focus…").tint(Tan.brown).padding(.top, 30)
            }
            if let p = problem {
                Card(title: "Focus problem", icon: "exclamationmark.triangle.fill") {
                    Note(text: p, bad: true)
                }
            }
            askCard
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if detail == nil { await load() }
        }
    }

    private var header: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(detail?.grade ?? summary.grade)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Tan.grade(detail?.percent ?? summary.percent))
                Spacer()
                if let exact = detail?.exact {
                    Text("exact " + String(format: "%.1f", exact) + "%").font(.caption).foregroundStyle(Tan.muted)
                }
            }
            Text(summary.course + (summary.teacher.isEmpty ? "" : " · " + summary.teacher))
                .font(.caption)
                .foregroundStyle(Tan.muted)
            if let d = detail {
                Text("Live from Focus, " + d.read_label).font(.caption2).foregroundStyle(Tan.faint)
            }
            Menu {
                Button("A (90%)") { setGoal("A") }
                Button("B (80%)") { setGoal("B") }
                Button("C (70%)") { setGoal("C") }
            } label: {
                Label("Set a goal for this class", systemImage: "target")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tan.brown)
            }
            if let g = goalNote {
                Text(g).font(.caption).foregroundStyle(Tan.muted)
            }
        }
    }

    private func zerosCard(_ d: ClassDetail) -> some View {
        Card(title: "Zeros worth fixing", icon: "flame.fill") {
            ForEach(d.zeros.indices, id: \.self) { i in
                HStack(alignment: .top) {
                    Text(d.zeros[i].name).font(.subheadline).foregroundStyle(Tan.text).lineLimit(2)
                    Spacer()
                    if let gain = d.zeros[i].gain {
                        Pill(text: "+" + String(format: "%.1f", gain) + "%", color: Tan.green, fill: Tan.greenBg)
                    }
                }
            }
        }
    }

    private func categoriesCard(_ d: ClassDetail) -> some View {
        Card(title: "Categories", icon: "square.grid.2x2.fill") {
            ForEach(d.categories.indices, id: \.self) { i in
                HStack {
                    Text(d.categories[i].name).font(.subheadline).foregroundStyle(Tan.text)
                    if let w = d.categories[i].weight {
                        Text(String(format: "%g", w) + "%").font(.caption).foregroundStyle(Tan.faint)
                    }
                    Spacer()
                    Text(d.categories[i].score).font(.caption).foregroundStyle(Tan.muted).lineLimit(1)
                }
            }
        }
    }

    private func assignmentsCard(_ d: ClassDetail) -> some View {
        Card(title: "Assignments", icon: "list.bullet", trailing: "\(d.assignments.count)") {
            if d.assignments.isEmpty {
                Note(text: "Nothing in the gradebook yet.")
            }
            ForEach(d.assignments.indices, id: \.self) { i in
                AssignmentRow(item: d.assignments[i])
            }
        }
    }

    private var askCard: some View {
        Card(title: "Ask Toast", icon: "sparkles") {
            askButton("What do I need for a B?", "what do i need in \(summary.name) to get a B")
            askButton("What's missing here?", "what am i missing in \(summary.name)")
            askButton("What if I ace the next test?", "what if i get 100 on the next test in \(summary.name)")
        }
    }

    private func askButton(_ title: String, _ ask: String) -> some View {
        Button {
            Haptic.tap()
            model.ask(ask)
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Tan.chipText)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(Tan.brown)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Tan.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if loading { return }
        loading = true
        problem = nil
        do {
            let d: ClassDetail = try await API.get("/api/grades/class?name=" + API.query(summary.name), timeout: 150)
            detail = d
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }

    private func setGoal(_ letter: String) {
        goalNote = "Saving your goal…"
        let name = summary.name
        Task {
            do {
                let r: GoalsReply = try await API.send("/api/goals", json: ["class_name": name, "target": letter],
                                                       timeout: 150)
                goalNote = r.goals.contains(where: { $0.name == name }) ? "Goal saved: \(letter) in \(name) 🎯"
                    : "Goal saved."
                Haptic.done()
                await model.loadHome()
            } catch {
                goalNote = error.localizedDescription
                Haptic.fail()
            }
        }
    }
}

struct AssignmentRow: View {
    let item: AssignmentItem

    var color: Color {
        if item.missing || item.zero { return Tan.bad }
        if item.score == "NG" || item.score == "excused" { return Tan.faint }
        return Tan.grade(item.percent)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline).foregroundStyle(Tan.text).lineLimit(2)
                Text([item.category, item.due, item.late ? "late" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Tan.muted)
            }
            Spacer()
            Text(item.score).font(.subheadline.weight(.semibold)).foregroundStyle(color)
        }
    }
}
