import Foundation
import GRDB

public struct CommitRow: Decodable, FetchableRecord, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var repoId: Int64
    public var sha: String
    public var shortSha: String
    public var authorEmail: String
    public var authorDate: Date
    public var subject: String
    public var body: String?
    public var branchHint: String?
    public var additions: Int
    public var deletions: Int
    public var statAdditions: Int
    public var statDeletions: Int
    public var filesChanged: Int
    public var isMerge: Bool
    public var repoName: String
    public var repoColor: String
    public var repoPath: String
    public var ticketKeys: String?

    public var tickets: [String] {
        (ticketKeys ?? "").split(separator: ",").map(String.init).sorted()
    }

    public var branchName: String? { branchHint.map(GitRef.shortName) }
}

public struct CommitFilter: Hashable, Sendable {
    public var interval: DateInterval?
    public var repoIds: Set<Int64> = []
    public var ticketKey: String?
    public var noTicket = false
    public var search = ""
    public var includeMerges = true

    public init(interval: DateInterval? = nil) { self.interval = interval }
}

public struct TicketSummary: Decodable, FetchableRecord, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var key: String
    public var title: String?
    public var status: TicketStatus
    public var notes: String?
    public var doneAt: Date?
    public var commitCount: Int
    public var additions: Int
    public var deletions: Int
    public var firstActivity: Date?
    public var lastActivity: Date?
    public var taskCount: Int
    public var firstSubject: String?

    public var displayTitle: String { title?.nonEmpty ?? firstSubject ?? "Untitled" }
}

public struct TaskRow: FetchableRecord, Identifiable, Hashable, Sendable {
    public var task: WorkTask
    public var ticketKey: String?
    public var ticketCommitCount: Int
    public var ticketLastCommit: Date?
    public var repoName: String?

    public var id: Int64 { task.id ?? 0 }

    public init(row: Row) throws {
        task = try WorkTask(row: row)
        ticketKey = row["ticketKey"]
        ticketCommitCount = row["ticketCommitCount"] ?? 0
        ticketLastCommit = row["ticketLastCommit"]
        repoName = row["repoName"]
    }
}

public struct LinkedTicket: Hashable, Sendable {
    public var ticket: Ticket
    public var source: String
}

public enum Queries {
    private static let commitSelect = """
        SELECT c.id, c.repoId, c.sha, c.shortSha, c.authorEmail, c.authorDate, c.subject, c.body, c.branchHint,
               c.additions, c.deletions, c.statAdditions, c.statDeletions, c.filesChanged, c.isMerge,
               r.name AS repoName, r.color AS repoColor, r.path AS repoPath,
               (SELECT group_concat(t.key, ',') FROM commitTicket ct JOIN ticket t ON t.id = ct.ticketId WHERE ct.commitId = c.id) AS ticketKeys
        FROM gitCommit c JOIN repo r ON r.id = c.repoId
        """

    // MARK: Commits

    public static func commits(_ db: Database, filter: CommitFilter, limit: Int = 100, offset: Int = 0) throws -> [CommitRow] {
        var clauses = ["c.isReachable = 1", "r.isActive = 1"]
        var args: [any DatabaseValueConvertible] = []
        if let interval = filter.interval {
            clauses.append("c.authorDate >= ? AND c.authorDate < ?")
            args += [interval.start, interval.end]
        }
        if !filter.repoIds.isEmpty {
            clauses.append("c.repoId IN (\(databaseQuestionMarks(count: filter.repoIds.count)))")
            args += filter.repoIds.sorted().map { $0 as any DatabaseValueConvertible }
        }
        if !filter.includeMerges { clauses.append("c.isMerge = 0") }
        if let key = filter.ticketKey {
            clauses.append("EXISTS (SELECT 1 FROM commitTicket ct JOIN ticket t ON t.id = ct.ticketId WHERE ct.commitId = c.id AND t.key = ?)")
            args.append(key)
        }
        if filter.noTicket { clauses.append("NOT EXISTS (SELECT 1 FROM commitTicket ct WHERE ct.commitId = c.id)") }
        let q = filter.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            clauses.append("(c.subject LIKE ? OR c.body LIKE ? OR c.sha LIKE ? OR EXISTS (SELECT 1 FROM commitTicket ct JOIN ticket t ON t.id = ct.ticketId WHERE ct.commitId = c.id AND t.key LIKE ?))")
            args += ["%\(q)%", "%\(q)%", "\(q.lowercased())%", "%\(q)%"]
        }
        args += [limit, offset]
        let sql = commitSelect + " WHERE " + clauses.joined(separator: " AND ") + " ORDER BY c.authorDate DESC, c.id DESC LIMIT ? OFFSET ?"
        return try CommitRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func commit(_ db: Database, id: Int64) throws -> CommitRow? {
        try CommitRow.fetchOne(db, sql: commitSelect + " WHERE c.id = ?", arguments: [id])
    }

    public static func files(_ db: Database, commitId: Int64) throws -> [CommitFile] {
        try CommitFile.filter(Column("commitId") == commitId).order(Column("path")).fetchAll(db)
    }

    public static func linkedTickets(_ db: Database, commitId: Int64) throws -> [LinkedTicket] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.*, ct.source AS linkSource FROM commitTicket ct JOIN ticket t ON t.id = ct.ticketId
            WHERE ct.commitId = ? ORDER BY t.key
            """, arguments: [commitId])
        return try rows.map { LinkedTicket(ticket: try Ticket(row: $0), source: $0["linkSource"]) }
    }

    // MARK: Stats

    public static func facts(_ db: Database, interval: DateInterval, repoIds: Set<Int64> = []) throws -> [CommitFact] {
        var sql = """
            SELECT c.id, c.repoId, c.authorDate, c.statAdditions, c.statDeletions, c.filesChanged, c.isMerge, c.subject
            FROM gitCommit c JOIN repo r ON r.id = c.repoId
            WHERE c.isReachable = 1 AND r.isActive = 1 AND c.authorDate >= ? AND c.authorDate < ?
            """
        var args: [any DatabaseValueConvertible] = [interval.start, interval.end]
        if !repoIds.isEmpty {
            sql += " AND c.repoId IN (\(databaseQuestionMarks(count: repoIds.count)))"
            args += repoIds.sorted().map { $0 as any DatabaseValueConvertible }
        }
        return try CommitFact.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    /// Distinct local days with commits since a date (for streaks).
    public static func activeDays(_ db: Database, since: Date, calendar: Calendar = .worklog) throws -> Set<Date> {
        let dates = try Date.fetchAll(db, sql: """
            SELECT c.authorDate FROM gitCommit c JOIN repo r ON r.id = c.repoId
            WHERE c.isReachable = 1 AND c.isMerge = 0 AND r.isActive = 1 AND c.authorDate >= ?
            """, arguments: [since])
        return Set(dates.map { calendar.startOfDay(for: $0) })
    }

    public static func ticketsDone(_ db: Database, interval: DateInterval) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ticket WHERE status = 'done' AND doneAt >= ? AND doneAt < ?",
                         arguments: [interval.start, interval.end]) ?? 0
    }

    public static func repoCommitCounts(_ db: Database, interval: DateInterval?) throws -> [Int64: Int] {
        var sql = "SELECT repoId, COUNT(*) AS n FROM gitCommit WHERE isReachable = 1 AND isMerge = 0"
        var args: [any DatabaseValueConvertible] = []
        if let interval {
            sql += " AND authorDate >= ? AND authorDate < ?"
            args += [interval.start, interval.end]
        }
        sql += " GROUP BY repoId"
        var out: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) { out[row["repoId"]] = row["n"] }
        return out
    }

    // MARK: Tickets

    /// With an interval, only tickets touched (or closed) in it, with stats for that interval.
    public static func ticketSummaries(_ db: Database, interval: DateInterval? = nil, repoIds: Set<Int64> = []) throws -> [TicketSummary] {
        var join = "c.id = ct.commitId AND c.isReachable = 1 AND c.isMerge = 0 AND c.repoId IN (SELECT id FROM repo WHERE isActive = 1)"
        var args: [any DatabaseValueConvertible] = []
        if let interval {
            join += " AND c.authorDate >= ? AND c.authorDate < ?"
            args += [interval.start, interval.end]
        }
        if !repoIds.isEmpty {
            join += " AND c.repoId IN (\(databaseQuestionMarks(count: repoIds.count)))"
            args += repoIds.sorted().map { $0 as any DatabaseValueConvertible }
        }
        var sql = """
            SELECT t.id, t.key, t.title, t.status, t.notes, t.doneAt,
                   COUNT(c.id) AS commitCount,
                   COALESCE(SUM(c.statAdditions), 0) AS additions,
                   COALESCE(SUM(c.statDeletions), 0) AS deletions,
                   MIN(c.authorDate) AS firstActivity, MAX(c.authorDate) AS lastActivity,
                   (SELECT COUNT(*) FROM task k WHERE k.ticketId = t.id) AS taskCount,
                   (SELECT c2.subject FROM commitTicket ct2 JOIN gitCommit c2 ON c2.id = ct2.commitId
                     WHERE ct2.ticketId = t.id AND c2.isMerge = 0 ORDER BY c2.authorDate ASC LIMIT 1) AS firstSubject
            FROM ticket t
            LEFT JOIN commitTicket ct ON ct.ticketId = t.id
            LEFT JOIN gitCommit c ON \(join)
            GROUP BY t.id
            """
        if let interval {
            sql += " HAVING commitCount > 0 OR (t.doneAt >= ? AND t.doneAt < ?)"
            args += [interval.start, interval.end]
        } else if !repoIds.isEmpty {
            sql += " HAVING commitCount > 0"
        }
        sql += " ORDER BY lastActivity IS NULL, lastActivity DESC, t.createdAt DESC"
        return try TicketSummary.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }

    public static func noTicketCount(_ db: Database, interval: DateInterval? = nil) throws -> Int {
        var sql = """
            SELECT COUNT(*) FROM gitCommit c JOIN repo r ON r.id = c.repoId
            WHERE c.isReachable = 1 AND c.isMerge = 0 AND r.isActive = 1
              AND NOT EXISTS (SELECT 1 FROM commitTicket ct WHERE ct.commitId = c.id)
            """
        var args: [any DatabaseValueConvertible] = []
        if let interval {
            sql += " AND c.authorDate >= ? AND c.authorDate < ?"
            args += [interval.start, interval.end]
        }
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
    }

    // MARK: Tasks

    public static func tasks(_ db: Database) throws -> [TaskRow] {
        try TaskRow.fetchAll(db, sql: """
            SELECT k.*, t.key AS ticketKey, r.name AS repoName,
                   (SELECT COUNT(*) FROM commitTicket ct JOIN gitCommit c ON c.id = ct.commitId
                     WHERE ct.ticketId = k.ticketId AND c.isReachable = 1 AND c.isMerge = 0) AS ticketCommitCount,
                   (SELECT MAX(c.authorDate) FROM commitTicket ct JOIN gitCommit c ON c.id = ct.commitId
                     WHERE ct.ticketId = k.ticketId AND c.isReachable = 1) AS ticketLastCommit
            FROM task k
            LEFT JOIN ticket t ON t.id = k.ticketId
            LEFT JOIN repo r ON r.id = k.repoId
            ORDER BY k.status = 'done', k.sortOrder, k.createdAt
            """)
    }

    // MARK: Search (command palette)

    public static func searchCommits(_ db: Database, text: String, limit: Int = 8) throws -> [CommitRow] {
        var f = CommitFilter()
        f.search = text
        return try commits(db, filter: f, limit: limit)
    }

    public static func searchTickets(_ db: Database, text: String, limit: Int = 6) throws -> [Ticket] {
        try Ticket.fetchAll(db, sql: "SELECT * FROM ticket WHERE key LIKE ? OR title LIKE ? ORDER BY createdAt DESC LIMIT ?",
                            arguments: ["%\(text)%", "%\(text)%", limit])
    }

    public static func searchTasks(_ db: Database, text: String, limit: Int = 6) throws -> [WorkTask] {
        try WorkTask.fetchAll(db, sql: "SELECT * FROM task WHERE title LIKE ? OR notes LIKE ? ORDER BY status = 'done', createdAt DESC LIMIT ?",
                              arguments: ["%\(text)%", "%\(text)%", limit])
    }
}

extension String {
    public var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
