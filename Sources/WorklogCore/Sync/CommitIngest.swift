import Foundation
import GRDB

/// Database writes for scanned commits. All functions expect to run inside a write transaction.
public enum CommitIngest {
    /// Inserts new commits (with files and ticket links) and marks already-known ones reachable.
    @discardableResult
    public static func ingest(_ commits: [LoggedCommit], repo: Repo,
                              extractor: TicketExtractor, exclusion: PathExclusion, db: Database) throws -> Int {
        guard let repoId = repo.id else { return 0 }
        var inserted = 0
        for c in commits {
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM gitCommit WHERE repoId = ? AND sha = ?", arguments: [repoId, c.sha]) {
                try db.execute(sql: "UPDATE gitCommit SET isReachable = 1 WHERE id = ?", arguments: [existing])
                continue
            }
            let counted = c.files.filter { !exclusion.isExcluded($0.path) }
            var record = Commit(
                id: nil, repoId: repoId, sha: c.sha, shortSha: c.shortSha, authorEmail: c.authorEmail,
                authorDate: c.authorDate, commitDate: c.commitDate, subject: c.subject,
                body: c.body.isEmpty ? nil : c.body,
                branchHint: c.source,
                additions: c.additions, deletions: c.deletions,
                statAdditions: counted.reduce(0) { $0 + ($1.additions ?? 0) },
                statDeletions: counted.reduce(0) { $0 + ($1.deletions ?? 0) },
                filesChanged: c.files.count, isMerge: c.isMerge, isReachable: true
            )
            try record.insert(db)
            guard let commitId = record.id else { continue }
            for f in c.files {
                try CommitFile(commitId: commitId, path: f.path, oldPath: f.oldPath, additions: f.additions, deletions: f.deletions)
                    .insert(db, onConflict: .ignore)
            }
            let branch = ticketBranch(ref: c.source, defaultBranch: repo.defaultBranch)
            let tickets = extractor.extract(subject: c.subject, body: c.body, branch: branch, repoName: repo.name)
            try link(commitId: commitId, tickets: tickets, db: db)
            inserted += 1
        }
        return inserted
    }

    /// The branch name to search for tickets, or nil for the default branch (its name carries no ticket).
    static func ticketBranch(ref: String?, defaultBranch: String?) -> String? {
        guard let ref else { return nil }
        let name = GitRef.branchName(ref)
        return name == defaultBranch ? nil : name
    }

    public static func link(commitId: Int64, tickets: [ExtractedTicket], db: Database) throws {
        for t in tickets {
            let ticketId = try ticketId(forKey: t.key, db: db)
            try db.execute(sql: "INSERT OR IGNORE INTO commitTicket (commitId, ticketId, source) VALUES (?, ?, ?)",
                           arguments: [commitId, ticketId, t.source])
        }
    }

    public static func ticketId(forKey key: String, db: Database) throws -> Int64 {
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM ticket WHERE key = ?", arguments: [key]) { return id }
        var ticket = Ticket(key: key)
        try ticket.insert(db)
        return ticket.id!
    }

    /// After a rebase/force-push/branch deletion: commits in the window that are no longer reachable are hidden (kept).
    public static func updateReachability(repoId: Int64, reachable: Set<String>, since: Date?, db: Database) throws {
        let rows: [Row]
        if let since {
            rows = try Row.fetchAll(db, sql: "SELECT id, sha, isReachable FROM gitCommit WHERE repoId = ? AND authorDate >= ?", arguments: [repoId, since])
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT id, sha, isReachable FROM gitCommit WHERE repoId = ?", arguments: [repoId])
        }
        for row in rows {
            let sha: String = row["sha"]
            let now = reachable.contains(sha)
            let was: Bool = row["isReachable"]
            if now != was {
                try db.execute(sql: "UPDATE gitCommit SET isReachable = ? WHERE id = ?", arguments: [now, row["id"] as Int64])
            }
        }
    }

    /// Re-runs ticket extraction for every commit (keeps manual links). Used when the pattern/allowlist changes.
    public static func reprocessTickets(extractor: TicketExtractor, db: Database) throws {
        try db.execute(sql: "DELETE FROM commitTicket WHERE source != 'manual'")
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.subject, c.body, c.branchHint, r.name AS repoName, r.defaultBranch
            FROM gitCommit c JOIN repo r ON r.id = c.repoId
            """)
        for row in rows {
            let branch = ticketBranch(ref: row["branchHint"], defaultBranch: row["defaultBranch"])
            let tickets = extractor.extract(subject: row["subject"], body: row["body"], branch: branch, repoName: row["repoName"])
            try link(commitId: row["id"], tickets: tickets, db: db)
        }
        try pruneOrphanTickets(db: db)
    }

    /// Tickets that nothing refers to and the user never edited.
    public static func pruneOrphanTickets(db: Database) throws {
        try db.execute(sql: """
            DELETE FROM ticket
            WHERE title IS NULL AND notes IS NULL AND status = 'active'
              AND NOT EXISTS (SELECT 1 FROM commitTicket ct WHERE ct.ticketId = ticket.id)
              AND NOT EXISTS (SELECT 1 FROM task k WHERE k.ticketId = ticket.id)
            """)
    }

    /// Recomputes `statAdditions/statDeletions` from per-file stats after the exclusion list changes.
    public static func recomputeLineStats(exclusion: PathExclusion, db: Database) throws {
        var totals: [Int64: (Int, Int)] = [:]
        let rows = try Row.fetchAll(db, sql: "SELECT commitId, path, additions, deletions FROM commitFile")
        for row in rows {
            let id: Int64 = row["commitId"]
            var t = totals[id] ?? (0, 0)
            if !exclusion.isExcluded(row["path"]) {
                t.0 += (row["additions"] as Int?) ?? 0
                t.1 += (row["deletions"] as Int?) ?? 0
            }
            totals[id] = t
        }
        try db.execute(sql: "UPDATE gitCommit SET statAdditions = 0, statDeletions = 0")
        for (id, t) in totals {
            try db.execute(sql: "UPDATE gitCommit SET statAdditions = ?, statDeletions = ? WHERE id = ?", arguments: [t.0, t.1, id])
        }
    }
}
