import GRDB
import SwiftUI
import WorklogCore

private enum CommitRange: String, CaseIterable {
    case wk, mo, qtr, yr, all

    var preset: RangePreset? { RangePreset(rawValue: rawValue) }
}

struct CommitsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var range: CommitRange = .all
    @State private var includeMerges = false
    @State private var rows: [CommitRow] = []
    @State private var exhausted = false
    @State private var loading = false

    private let pageSize = 100

    private var filter: CommitFilter {
        var f = CommitFilter(interval: range.preset?.interval())
        if let repo = model.commitsRepoFilter { f.repoIds = [repo] }
        if let key = model.commitsTicketFilter {
            if key == "∅" { f.noTicket = true } else { f.ticketKey = key }
        }
        f.search = search
        f.includeMerges = includeMerges
        return f
    }

    var body: some View {
        Screen(spacing: 16) {
            HStack(spacing: 12) {
                MonoSearchInput(placeholder: "Filter by subject, sha or ticket…", text: $search)
                MonoSegmentedControl(options: CommitRange.allCases.map { ($0.rawValue, $0) }, selection: $range)
                repoMenu
                Toggle(isOn: $includeMerges) { Text("merges").font(Theme.monoMedium).foregroundStyle(Theme.textSecondary) }
                    .toggleStyle(.checkbox)
                    .tint(Theme.accent)
            }
            if let key = model.commitsTicketFilter {
                HStack(spacing: 8) {
                    Text("ticket").font(Theme.monoMeta).foregroundStyle(Theme.textMuted)
                    TicketChip(key: key == "∅" ? "no ticket" : key)
                    Button("clear") { model.commitsTicketFilter = nil }.buttonStyle(LinkButtonStyle())
                }
            }
        } content: {
            if rows.isEmpty && !loading {
                Card {
                    EmptyState(message: model.repos.isEmpty ? "no repos yet" : "no commits in this range") {
                        if model.repos.isEmpty {
                            Button("Add repo") { model.pickRepos() }.buttonStyle(PrimaryButtonStyle())
                        } else if range != .all || !search.isEmpty || model.commitsRepoFilter != nil {
                            Button("show all") {
                                range = .all; search = ""; model.commitsRepoFilter = nil; model.commitsTicketFilter = nil
                            }
                            .buttonStyle(SecondaryMonoButtonStyle())
                        }
                    }
                }
            }
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            SectionLabel(group.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            Text("\(group.rows.count) commit\(group.rows.count == 1 ? "" : "s")")
                                .font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                        }
                        Card(padding: EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12), spacing: 0) {
                            ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                                CommitListRow(commit: row) { model.openCommit(row.id, context: rows.map(\.id)) }
                                    .overlay(alignment: .top) {
                                        if i > 0 { Rectangle().fill(Theme.divider).frame(height: 1) }
                                    }
                                    .onAppear { if row.id == rows.last?.id { loadMore() } }
                            }
                        }
                    }
                }
                if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            }
        }
        .task(id: "\(model.revision)-\(filter.hashValue)") { await reload() }
    }

    private var repoMenu: some View {
        Menu {
            Button("All repos") { model.commitsRepoFilter = nil }
            Divider()
            ForEach(model.repos) { r in
                Button(r.name) { model.commitsRepoFilter = r.id }
            }
        } label: {
            Text(model.repos.first { $0.id == model.commitsRepoFilter }?.name ?? "all repos")
                .font(Theme.monoMedium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlBorder, lineWidth: 1))
    }

    private var groups: [(day: Date, rows: [CommitRow])] {
        let cal = Calendar.worklog
        var out: [(day: Date, rows: [CommitRow])] = []
        for row in rows {
            let day = cal.startOfDay(for: row.authorDate)
            if out.last?.day == day { out[out.count - 1].rows.append(row) } else { out.append((day, [row])) }
        }
        return out
    }

    private func reload() async {
        let f = filter
        let limit = max(rows.count, pageSize)
        loading = true
        let result = try? await model.db.writer.read { db in try Queries.commits(db, filter: f, limit: limit) }
        rows = result ?? []
        exhausted = rows.count < limit
        loading = false
    }

    private func loadMore() {
        guard !exhausted, !loading else { return }
        let f = filter
        let offset = rows.count
        loading = true
        Task {
            let more = (try? await model.db.writer.read { db in try Queries.commits(db, filter: f, limit: pageSize, offset: offset) }) ?? []
            rows += more
            exhausted = more.count < pageSize
            loading = false
        }
    }
}

struct CommitListRow: View {
    let commit: CommitRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HoverBackground(radius: 6) {
                HStack(spacing: 12) {
                    Text(commit.shortSha).font(Theme.monoSmall).foregroundStyle(Theme.sha).frame(width: 62, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(commit.subject).font(Theme.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            if commit.isMerge { Text("merge").font(Theme.monoSmall).foregroundStyle(Theme.textMuted) }
                        }
                        HStack(spacing: 10) {
                            HStack(spacing: 5) {
                                StatusDot(color: Color(hexString: commit.repoColor), size: 6)
                                Text(commit.repoName)
                            }
                            if let branch = commit.branchName { Text(branch).lineLimit(1) }
                            Text("\(commit.filesChanged) file\(commit.filesChanged == 1 ? "" : "s")")
                        }
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    ForEach(commit.tickets.prefix(2), id: \.self) { TicketChip(key: $0) }
                    LineCounts(additions: commit.additions, deletions: commit.deletions)
                        .frame(minWidth: 90, alignment: .trailing)
                    Text(commit.authorDate.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 52)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(commit.subject), \(commit.repoName), \(commit.shortSha)")
    }
}
