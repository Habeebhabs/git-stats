import Foundation
import GRDB

/// User-driven writes (tasks, tickets, manual links).
public enum Mutations {
    // MARK: Tasks

    @discardableResult
    public static func addTask(_ input: String, repoId: Int64? = nil, commitId: Int64? = nil, db: Database, now: Date = Date()) throws -> WorkTask? {
        let parsed = TaskInputParser.parse(input, now: now)
        guard !parsed.title.isEmpty else { return nil }
        let minOrder = try Double.fetchOne(db, sql: "SELECT MIN(sortOrder) FROM task") ?? 0
        var task = WorkTask(title: parsed.title, sortOrder: minOrder - 1)
        task.tags = parsed.tags.isEmpty ? nil : parsed.tags.joined(separator: ",")
        task.dueDate = parsed.dueDate
        task.repoId = repoId
        task.commitId = commitId
        if let key = parsed.ticketKey { task.ticketId = try CommitIngest.ticketId(forKey: key, db: db) }
        try task.insert(db)
        return task
    }

    public static func setTaskStatus(id: Int64, status: TaskStatus, db: Database, now: Date = Date()) throws {
        try db.execute(sql: "UPDATE task SET status = ?, completedAt = ? WHERE id = ?",
                       arguments: [status, status == .done ? now : nil, id])
    }

    /// Moves `id` to sit before `beforeId` (or to the end when nil).
    public static func moveTask(id: Int64, before beforeId: Int64?, db: Database) throws {
        let ordered = try Int64.fetchAll(db, sql: "SELECT id FROM task ORDER BY status = 'done', sortOrder, createdAt")
        var ids = ordered.filter { $0 != id }
        if let beforeId, let idx = ids.firstIndex(of: beforeId) { ids.insert(id, at: idx) } else { ids.append(id) }
        for (i, taskId) in ids.enumerated() {
            try db.execute(sql: "UPDATE task SET sortOrder = ? WHERE id = ?", arguments: [Double(i), taskId])
        }
    }

    public static func setTaskTicket(id: Int64, key: String?, db: Database) throws {
        let ticketId = try key?.nonEmpty.map { try CommitIngest.ticketId(forKey: $0.uppercased(), db: db) }
        try db.execute(sql: "UPDATE task SET ticketId = ? WHERE id = ?", arguments: [ticketId, id])
    }

    // MARK: Tickets

    public static func setTicketStatus(id: Int64, status: TicketStatus, db: Database, now: Date = Date()) throws {
        try db.execute(sql: "UPDATE ticket SET status = ?, doneAt = ? WHERE id = ?",
                       arguments: [status, status == .done ? now : nil, id])
    }

    public static func linkTicket(commitId: Int64, key: String, db: Database) throws {
        let ticketId = try CommitIngest.ticketId(forKey: key, db: db)
        try db.execute(sql: "INSERT OR REPLACE INTO commitTicket (commitId, ticketId, source) VALUES (?, ?, 'manual')",
                       arguments: [commitId, ticketId])
    }

    public static func unlinkTicket(commitId: Int64, ticketId: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM commitTicket WHERE commitId = ? AND ticketId = ?", arguments: [commitId, ticketId])
        try CommitIngest.pruneOrphanTickets(db: db)
    }

    // MARK: Repos & identities

    /// Adds a repo with the next palette color. Returns nil if it's already added.
    @discardableResult
    public static func addRepo(path: String, db: Database) throws -> Repo? {
        if try Repo.filter(Column("path") == path).fetchCount(db) > 0 { return nil }
        let count = try Repo.fetchCount(db)
        var repo = Repo(path: path, name: (path as NSString).lastPathComponent, color: Repo.palette[count % Repo.palette.count])
        try repo.insert(db)
        return repo
    }

    @discardableResult
    public static func addIdentity(email: String, name: String? = nil, db: Database) throws -> Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.contains("@") || !e.isEmpty else { return false }
        if try Identity.filter(sql: "email = ? COLLATE NOCASE", arguments: [e]).fetchCount(db) > 0 { return false }
        var identity = Identity(email: e, name: name)
        try identity.insert(db)
        return true
    }

    public static func periodNote(key: String, db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT text FROM periodNote WHERE key = ?", arguments: [key]) ?? ""
    }

    public static func savePeriodNote(key: String, text: String, db: Database) throws {
        try db.execute(sql: "INSERT INTO periodNote (key, text) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET text = excluded.text",
                       arguments: [key, text])
    }
}
