import GRDB
import SwiftUI
import WorklogCore

struct TicketsView: View {
    @Environment(AppModel.self) private var model
    @State private var tickets: [TicketSummary] = []
    @State private var noTicket = 0
    @State private var search = ""
    @State private var showNoTicket = false

    private var filtered: [TicketSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tickets }
        return tickets.filter { $0.key.localizedCaseInsensitiveContains(q) || $0.displayTitle.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Screen(scrolls: false, spacing: 16) {
            HStack(spacing: 12) {
                MonoSearchInput(placeholder: "Filter tickets…", text: $search)
                Text("\(tickets.count) tickets").font(Theme.monoMeta).foregroundStyle(Theme.textMuted)
            }
        } content: {
            FlexRow {
                list.flex(2, min: 320)
                detail.flex(3, min: 440)
            }
            .frame(maxHeight: .infinity)
        }
        .task(id: model.revision) { await load() }
    }

    private func load() async {
        guard let result = try? await model.db.writer.read({ db in
            (try Queries.ticketSummaries(db), try Queries.noTicketCount(db))
        }) else { return }
        tickets = result.0
        noTicket = result.1
        if model.selectedTicketId == nil && !showNoTicket { model.selectedTicketId = tickets.first?.id }
    }

    private var list: some View {
        Card(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([TicketStatus.active, .review, .done], id: \.self) { status in
                        let group = filtered.filter { $0.status == status }
                        if !group.isEmpty {
                            HStack(spacing: 8) {
                                StatusDot(color: Theme.ticketDot(status))
                                SectionLabel(status == .active ? "in progress" : status.label)
                                Text("\(group.count)").font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 6)
                            ForEach(group) { t in
                                TicketRowView(ticket: t, selected: !showNoTicket && model.selectedTicketId == t.id, showLines: true) {
                                    showNoTicket = false
                                    model.selectedTicketId = t.id
                                }
                            }
                        }
                    }
                    if noTicket > 0 {
                        SectionLabel("no ticket").padding(.top, 12).padding(.bottom, 6)
                        Button {
                            showNoTicket = true
                        } label: {
                            HoverBackground(radius: 6, isSelected: showNoTicket) {
                                HStack(spacing: 10) {
                                    StatusDot(color: Theme.textMuted)
                                    Text("No ticket").font(Theme.body).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(noTicket)c").font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                                }
                                .frame(minHeight: 44)
                                .padding(.horizontal, showNoTicket ? 8 : 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .rowDivider(.top)
                    }
                    if tickets.isEmpty {
                        EmptyState("no tickets yet — they appear when commits mention keys like PAY-218")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if showNoTicket {
            NoTicketDetail()
        } else if let id = model.selectedTicketId, let t = tickets.first(where: { $0.id == id }) {
            TicketDetail(summary: t).id(t.id)
        } else {
            Card { EmptyState("select a ticket") }
        }
    }
}

private struct TicketDetail: View {
    @Environment(AppModel.self) private var model
    let summary: TicketSummary
    @State private var title = ""
    @State private var notes = ""
    @State private var commits: [CommitRow] = []
    @State private var tasks: [TaskRow] = []

    var body: some View {
        Card(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(summary.key).font(.plexMono(14, .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                MonoSegmentedControl(
                    options: TicketStatus.allCases.map { ($0.label, $0) },
                    selection: Binding(get: { summary.status }, set: { model.setTicketStatus(summary.id, $0) }),
                    height: 30, background: Theme.bg
                )
            }
            TextField("", text: $title, prompt: Text(summary.firstSubject ?? "Ticket title").foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain)
                .font(Theme.detailTitle)
                .foregroundStyle(Theme.textPrimary)
                .onSubmit(save)
            HStack(spacing: 18) {
                Text("\(summary.commitCount) commits")
                LineCounts(additions: summary.additions, deletions: summary.deletions, font: Theme.monoMeta)
                if let first = summary.firstActivity, let last = summary.lastActivity {
                    Text("\(first.formatted(.dateTime.month(.abbreviated).day())) → \(Fmt.relative(last))")
                }
                Spacer()
                Button("commits →") { model.showCommits(ticket: summary.key) }.buttonStyle(LinkButtonStyle())
            }
            .font(Theme.monoMeta)
            .foregroundStyle(Theme.textMuted)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("notes")
                TextEditor(text: $notes)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 76)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.controlBorder, lineWidth: 1))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !tasks.isEmpty {
                        SectionLabel("linked tasks")
                        VStack(spacing: 0) {
                            ForEach(tasks) { row in TaskRowView(row: row) { model.toggleTask(row.task) } }
                        }
                    }
                    SectionLabel("commits")
                    let ids = commits.map(\.id)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(commits.enumerated()), id: \.element.id) { i, c in
                            GitGraphRow(commit: c, isFirst: i == 0, isLast: i == commits.count - 1) {
                                model.openCommit(c.id, context: ids)
                            }
                        }
                    }
                    if commits.isEmpty { Text("No commits yet.").font(Theme.monoSmall).foregroundStyle(Theme.textMuted) }
                }
            }
        }
        .onAppear {
            title = summary.title ?? ""
            notes = summary.notes ?? ""
        }
        .onDisappear(perform: save)
        .onChange(of: notes) { debounceSave() }
        .task(id: model.revision) { await load() }
    }

    @State private var saveTask: Task<Void, Never>?

    private func debounceSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { save() }
        }
    }

    private func save() {
        guard title != (summary.title ?? "") || notes != (summary.notes ?? "") else { return }
        model.saveTicket(id: summary.id, title: title, notes: notes)
    }

    private func load() async {
        let key = summary.key
        let id = summary.id
        guard let result = try? await model.db.writer.read({ db -> ([CommitRow], [TaskRow]) in
            var f = CommitFilter()
            f.ticketKey = key
            return (try Queries.commits(db, filter: f, limit: 200), try Queries.tasks(db).filter { $0.task.ticketId == id })
        }) else { return }
        commits = result.0
        tasks = result.1
    }
}

private struct NoTicketDetail: View {
    @Environment(AppModel.self) private var model
    @State private var commits: [CommitRow] = []

    var body: some View {
        Card(spacing: 12) {
            CardHeader(title: "No ticket", meta: "commits that don't mention a ticket") {
                Button("commits →") { model.showCommits(ticket: "∅") }.buttonStyle(LinkButtonStyle())
            }
            ScrollView {
                let ids = commits.map(\.id)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { i, c in
                        GitGraphRow(commit: c, isFirst: i == 0, isLast: i == commits.count - 1) {
                            model.openCommit(c.id, context: ids)
                        }
                    }
                }
            }
        }
        .task(id: model.revision) {
            var f = CommitFilter()
            f.noTicket = true
            f.includeMerges = false
            let filter = f
            commits = (try? await model.db.writer.read { db in try Queries.commits(db, filter: filter, limit: 200) }) ?? []
        }
    }
}
