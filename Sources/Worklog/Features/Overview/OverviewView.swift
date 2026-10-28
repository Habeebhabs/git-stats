import GRDB
import SwiftUI
import WorklogCore

struct OverviewData: Sendable {
    var summary = StatsSummary()
    var prevCommits = 0
    var ticketsDone = 0
    var prevTicketsDone = 0
    var recent: [CommitRow] = []
    var tickets: [TicketSummary] = []
    var tasks: [TaskRow] = []
    var unit = BucketUnit.week

    var statusCounts: (done: Int, review: Int, active: Int) {
        (tickets.filter { $0.status == .done }.count,
         tickets.filter { $0.status == .review }.count,
         tickets.filter { $0.status == .active }.count)
    }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var data = OverviewData()

    var body: some View {
        Screen {
            HStack(spacing: 12) {
                CommandSearchField { model.palette.open() }
                    .frame(minWidth: 320)
                MonoSegmentedControl(
                    options: RangePreset.allCases.map { ($0.rawValue, $0) },
                    selection: Binding(get: { model.range }, set: { model.setRange($0) })
                )
                Button("Export report") { model.section = .reports }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Fmt.greeting()) — here's your \(model.range.word)")
                    .font(Theme.pageTitle).tracking(-0.24)
                    .foregroundStyle(Theme.textPrimary)
                Text("author: me · \(model.repos.filter(\.isActive).count) repos")
                    .font(Theme.monoMeta).foregroundStyle(Theme.textMuted)
            }

            if model.repos.isEmpty {
                Card {
                    EmptyState(message: "no repos yet — add one to see your commits") {
                        Button("Add repo") { model.pickRepos() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            } else {
                statTiles
                FlexRow {
                    chartCard.flex(3, min: 440)
                    tasksCard.flex(2, min: 320)
                }
                FlexRow {
                    historyCard.flex(3, min: 440)
                    ticketsCard.flex(2, min: 320)
                }
            }
        }
        .task(id: "\(model.revision)-\(model.range.rawValue)") { await load() }
    }

    private func load() async {
        let preset = model.range
        let interval = preset.interval()
        let settings = model.settings
        let streakSince = Calendar.worklog.date(byAdding: .day, value: -400, to: Date())!
        let result = try? await model.db.writer.read { db -> OverviewData in
            var d = OverviewData()
            d.unit = BucketUnit.forPreset(preset)
            let facts = try Queries.facts(db, interval: interval)
            let streakDays = try Queries.activeDays(db, since: streakSince)
            d.summary = StatsCalculator.summarize(facts: facts, interval: interval, unit: d.unit,
                                                  includeMerges: settings.includeMergesInStats,
                                                  countWeekends: settings.countWeekends, streakDays: streakDays)
            let prev = interval.previous
            d.prevCommits = try Queries.facts(db, interval: prev).filter { settings.includeMergesInStats || !$0.isMerge }.count
            d.ticketsDone = try Queries.ticketsDone(db, interval: interval)
            d.prevTicketsDone = try Queries.ticketsDone(db, interval: prev)
            var filter = CommitFilter()
            filter.includeMerges = false
            d.recent = try Queries.commits(db, filter: filter, limit: 8)
            d.tickets = try Queries.ticketSummaries(db, interval: interval)
            d.tasks = try Queries.tasks(db)
            return d
        }
        if let result { data = result }
    }

    // MARK: Tiles

    private var statTiles: some View {
        let s = data.summary
        let commitsDelta = Fmt.delta(s.commits, data.prevCommits)
        let ticketsDelta = Fmt.countDelta(data.ticketsDone, data.prevTicketsDone)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: 4), spacing: 12) {
            StatTile(label: "commits", value: Fmt.thousands(s.commits), note: commitsDelta.text, noteIsUp: commitsDelta.isUp)
            StatTile(label: "tickets closed", value: String(data.ticketsDone), note: ticketsDelta.text, noteIsUp: ticketsDelta.isUp)
            StatTile(label: "lines", value: Fmt.plus(s.additions, compact: true), note: "\(Fmt.minus(s.deletions, compact: true)) removed")
            StatTile(label: "active days", value: "\(s.activeDays)/\(s.workingDays)",
                     note: "streak · \(s.currentStreak) day\(s.currentStreak == 1 ? "" : "s")")
        }
    }

    // MARK: Cards

    private var chartCard: some View {
        Card(spacing: 14) {
            let peak = data.summary.peak
            CardHeader(title: data.unit.chartTitle,
                       meta: peak.map { $0.count > 0 ? "// peak \($0.peakLabel) · \($0.count)" : "// no commits yet" })
            WeeklyBarChart(buckets: data.summary.buckets)
            if !data.summary.perRepo.isEmpty {
                ProjectSplitBar(perRepo: data.summary.perRepo, repos: model.repos)
            }
        }
    }

    private var tasksCard: some View {
        let open = data.tasks.filter { $0.task.status != .done }
        let shown = Array((open + data.tasks.filter { $0.task.status == .done }).prefix(6))
        return Card(spacing: 10) {
            CardHeader(title: "Tasks", meta: "\(open.count) open") {
                Button("all →") { model.section = .tasks }.buttonStyle(LinkButtonStyle())
            }
            TaskInput(onSubmit: { model.addTask($0) })
            VStack(spacing: 0) {
                ForEach(shown) { row in
                    TaskRowView(row: row) { model.toggleTask(row.task) }
                }
                if shown.isEmpty {
                    Text("Nothing on your list.").font(Theme.monoSmall).foregroundStyle(Theme.textMuted).padding(.vertical, 12)
                }
            }
        }
    }

    private var historyCard: some View {
        Card(spacing: 0) {
            CardHeader(title: "Commit history") {
                Button("git log →") { model.showCommits() }.buttonStyle(LinkButtonStyle())
            }
            .padding(.bottom, 10)
            let ids = data.recent.map(\.id)
            ForEach(Array(data.recent.enumerated()), id: \.element.id) { i, c in
                GitGraphRow(commit: c, isFirst: i == 0, isLast: i == data.recent.count - 1) {
                    model.openCommit(c.id, context: ids)
                }
            }
            if data.recent.isEmpty {
                EmptyState("no commits yet — waiting for the first scan")
            }
        }
    }

    private var ticketsCard: some View {
        let c = data.statusCounts
        return Card(spacing: 4) {
            CardHeader(title: "Tickets", meta: "\(c.done) done · \(c.review) review · \(c.active) active") {
                Button("all →") { model.section = .tickets }.buttonStyle(LinkButtonStyle())
            }
            .padding(.bottom, 8)
            ForEach(data.tickets.prefix(5)) { t in
                TicketRowView(ticket: t) { model.openTicket(t.id) }
            }
            if data.tickets.isEmpty {
                EmptyState("no tickets in this \(model.range.word)")
            }
        }
    }
}

/// Thin stacked bar: share of commits per repo.
struct ProjectSplitBar: View {
    let perRepo: [Int64: Int]
    let repos: [Repo]

    var body: some View {
        let total = max(perRepo.values.reduce(0, +), 1)
        let parts = perRepo.sorted { $0.value > $1.value }.compactMap { id, n -> (Repo, Int)? in
            repos.first { $0.id == id }.map { ($0, n) }
        }
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0.id) { repo, n in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hexString: repo.color))
                            .frame(width: max(2, (geo.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(n) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0.id) { repo, n in
                    HStack(spacing: 6) {
                        StatusDot(color: Color(hexString: repo.color), size: 6)
                        Text("\(repo.name) \(Int((Double(n) / Double(total) * 100).rounded()))%")
                            .font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
