import Foundation
import GRDB

public enum ReportSection: String, CaseIterable, Sendable, Identifiable {
    case summary, tickets, completedTasks, pendingTasks, notes

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .summary: "summary stats"
        case .tickets: "tickets & commits"
        case .completedTasks: "completed tasks"
        case .pendingTasks: "pending tasks"
        case .notes: "notes"
        }
    }
}

public enum ReportGrouping: String, CaseIterable, Sendable, Identifiable {
    case projectTicket, ticket, month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .projectTicket: "project → ticket"
        case .ticket: "ticket"
        case .month: "month"
        }
    }
}

public struct ReportCommit: Hashable, Sendable {
    public var id: Int64
    public var repoId: Int64
    public var subject: String
    public var date: Date
    public var additions: Int
    public var deletions: Int
    public var ticketIds: [Int64]
}

public struct ReportData: Sendable {
    public var title: String
    public var interval: DateInterval
    public var repos: [Int64: Repo]
    public var commits: [ReportCommit]
    public var tickets: [Int64: Ticket]
    public var completedTasks: [TaskRow]
    public var pendingTasks: [TaskRow]
    public var ticketsDone: Int
    public var activeDays: Int
    public var workingDays: Int
    public var notes: String
}

public enum ReportBuilder {
    /// Loads everything a report needs. Merges are excluded.
    public static func load(_ db: Database, interval: DateInterval, repoIds: Set<Int64>, notes: String,
                            countWeekends: Bool, now: Date = Date()) throws -> ReportData {
        let repos = try Repo.fetchAll(db)
        let selected = repoIds.isEmpty ? Set(repos.compactMap(\.id)) : repoIds
        let facts = try Queries.facts(db, interval: interval, repoIds: selected).filter { !$0.isMerge }
        var links: [Int64: [Int64]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT ct.commitId, ct.ticketId FROM commitTicket ct JOIN gitCommit c ON c.id = ct.commitId
            WHERE c.authorDate >= ? AND c.authorDate < ?
            """, arguments: [interval.start, interval.end]) {
            links[row["commitId"], default: []].append(row["ticketId"])
        }
        let commits = facts.map {
            ReportCommit(id: $0.id, repoId: $0.repoId, subject: $0.subject, date: $0.authorDate,
                         additions: $0.statAdditions, deletions: $0.statDeletions, ticketIds: links[$0.id] ?? [])
        }
        let tickets = Dictionary(uniqueKeysWithValues: try Ticket.fetchAll(db).compactMap { t in t.id.map { ($0, t) } })
        let tasks = try Queries.tasks(db).filter { row in
            guard let repoId = row.task.repoId else { return true }
            return selected.contains(repoId)
        }
        let completed = tasks.filter { $0.task.status == .done && ($0.task.completedAt.map(interval.contains) ?? false) }
        let pending = tasks.filter { $0.task.status != .done }
        let summary = StatsCalculator.summarize(facts: facts, interval: interval, unit: .week, countWeekends: countWeekends, now: now)
        return ReportData(
            title: title(for: interval),
            interval: interval,
            repos: Dictionary(uniqueKeysWithValues: repos.compactMap { r in r.id.map { ($0, r) } }),
            commits: commits,
            tickets: tickets,
            completedTasks: completed,
            pendingTasks: pending,
            ticketsDone: try Queries.ticketsDone(db, interval: interval),
            activeDays: summary.activeDays,
            workingDays: summary.workingDays,
            notes: notes
        )
    }

    /// `Q3 2026`, `H1 2026`, `2026`, or the date span.
    public static func title(for interval: DateInterval, calendar: Calendar = .worklog) -> String {
        let s = calendar.dateComponents([.year, .month, .day], from: interval.start)
        let months = calendar.dateComponents([.month], from: interval.start, to: interval.end).month ?? 0
        let isMonthStart = s.day == 1 && calendar.startOfDay(for: interval.start) == interval.start
        let endIsMonthStart = calendar.component(.day, from: interval.end) == 1 && calendar.startOfDay(for: interval.end) == interval.end
        if isMonthStart && endIsMonthStart, let y = s.year, let m = s.month {
            if months == 3 && (m - 1) % 3 == 0 { return "Q\((m - 1) / 3 + 1) \(y)" }
            if months == 6 && (m == 1 || m == 7) { return "H\(m == 1 ? 1 : 2) \(y)" }
            if months == 12 && m == 1 { return "\(y)" }
            if months == 1 { return interval.start.formatted(.dateTime.month(.wide).year()) }
        }
        return interval.label
    }

    public static func markdown(_ data: ReportData, sections: Set<ReportSection>, grouping: ReportGrouping) -> String {
        var out: [String] = []
        out.append("# Work summary — \(data.title) (\(data.interval.label))")
        out.append("")

        if sections.contains(.summary) {
            let adds = data.commits.reduce(0) { $0 + $1.additions }
            let dels = data.commits.reduce(0) { $0 + $1.deletions }
            let touched = Set(data.commits.flatMap(\.ticketIds)).count
            out.append("**\(Fmt.thousands(data.commits.count)) commits · \(data.ticketsDone) tickets done · \(touched) tickets touched · +\(Fmt.compact(adds)) / \(Fmt.minus)\(Fmt.compact(dels)) lines · \(data.activeDays) of \(data.workingDays) days active**")
            out.append("")
            if data.repos.count > 1 {
                var perRepo: [Int64: Int] = [:]
                for c in data.commits { perRepo[c.repoId, default: 0] += 1 }
                let total = max(data.commits.count, 1)
                let split = perRepo.sorted { $0.value > $1.value }.compactMap { id, n -> String? in
                    guard let repo = data.repos[id] else { return nil }
                    return "\(repo.name) \(Int((Double(n) / Double(total) * 100).rounded()))%"
                }
                if !split.isEmpty {
                    out.append("Project split: " + split.joined(separator: " · "))
                    out.append("")
                }
            }
        }

        if sections.contains(.tickets) {
            switch grouping {
            case .projectTicket:
                let byRepo = Dictionary(grouping: data.commits, by: \.repoId)
                for (repoId, commits) in byRepo.sorted(by: { $0.value.count > $1.value.count }) {
                    out.append("## \(data.repos[repoId]?.name ?? "Unknown repo")")
                    out += ticketBlocks(commits, data: data, level: "###")
                }
            case .ticket:
                out.append("## Tickets")
                out += ticketBlocks(data.commits, data: data, level: "###")
            case .month:
                let cal = Calendar.worklog
                let byMonth = Dictionary(grouping: data.commits) { cal.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
                for (month, commits) in byMonth.sorted(by: { $0.key < $1.key }) {
                    out.append("## \(month.formatted(.dateTime.month(.wide).year()))")
                    out += ticketBlocks(commits, data: data, level: "###")
                }
            }
        }

        if sections.contains(.completedTasks) {
            out.append("## Completed tasks")
            out += taskLines(data.completedTasks)
            out.append("")
        }
        if sections.contains(.pendingTasks) {
            out.append("## Pending tasks")
            out += taskLines(data.pendingTasks)
            out.append("")
        }
        if sections.contains(.notes) {
            out.append("## Notes")
            out.append(data.notes.nonEmpty ?? "_No notes for this period._")
            out.append("")
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    private static func ticketBlocks(_ commits: [ReportCommit], data: ReportData, level: String) -> [String] {
        var out: [String] = []
        var byTicket: [Int64: [ReportCommit]] = [:]
        var none: [ReportCommit] = []
        for c in commits {
            if c.ticketIds.isEmpty { none.append(c) }
            for t in c.ticketIds { byTicket[t, default: []].append(c) }
        }
        for (ticketId, list) in byTicket.sorted(by: { $0.value.count > $1.value.count }) {
            guard let ticket = data.tickets[ticketId] else { continue }
            let title = ticket.title?.nonEmpty ?? list.min(by: { $0.date < $1.date })?.subject ?? ""
            let status: String = switch ticket.status {
            case .done: "done"
            case .review: "in review"
            case .active: "in progress"
            }
            out.append("\(level) \(ticket.key) — \(title) (\(status))")
            out += commitLines(list)
            out.append("")
        }
        if !none.isEmpty {
            out.append("\(level) Other work (no ticket)")
            out += commitLines(none)
            out.append("")
        }
        return out
    }

    private static func commitLines(_ list: [ReportCommit]) -> [String] {
        let adds = list.reduce(0) { $0 + $1.additions }
        let dels = list.reduce(0) { $0 + $1.deletions }
        let key = list.sorted { ($0.additions + $0.deletions) > ($1.additions + $1.deletions) }.prefix(3).map(\.subject)
        return [
            "- \(list.count) commit\(list.count == 1 ? "" : "s") · +\(Fmt.thousands(adds)) / \(Fmt.minus)\(Fmt.thousands(dels))",
            "- Key commits: " + key.joined(separator: "; "),
        ]
    }

    private static func taskLines(_ tasks: [TaskRow]) -> [String] {
        if tasks.isEmpty { return ["_None._"] }
        return tasks.map { row in
            var line = "- \(row.task.title)"
            if let key = row.ticketKey { line += " (\(key))" }
            if row.task.status == .inProgress { line += " — in progress" }
            return line
        }
    }
}
