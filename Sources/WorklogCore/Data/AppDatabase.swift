import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// `~/Library/Application Support/Worklog/worklog.sqlite` (or `$WORKLOG_DATA_DIR/worklog.sqlite`)
    public static func onDisk() throws -> AppDatabase {
        let fm = FileManager.default
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["WORKLOG_DATA_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Worklog", isDirectory: true)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("worklog.sqlite").path, configuration: config)
        return try AppDatabase(pool)
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "repo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("defaultBranch", .text)
                t.column("gitDir", .text)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("isShallow", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .datetime).notNull()
                t.column("lastSyncedAt", .datetime)
                t.column("lastError", .text)
            }
            try db.create(table: "identity") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email", .text).notNull().unique().collate(.nocase)
                t.column("name", .text)
            }
            try db.create(table: "refCursor") { t in
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade)
                t.column("refName", .text).notNull()
                t.column("lastSha", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["repoId", "refName"])
            }
            try db.create(table: "gitCommit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("repoId", .integer).notNull().references("repo", onDelete: .cascade)
                t.column("sha", .text).notNull()
                t.column("shortSha", .text).notNull()
                t.column("authorEmail", .text).notNull()
                t.column("authorDate", .datetime).notNull()
                t.column("commitDate", .datetime).notNull()
                t.column("subject", .text).notNull()
                t.column("body", .text)
                t.column("branchHint", .text)
                t.column("additions", .integer).notNull().defaults(to: 0)
                t.column("deletions", .integer).notNull().defaults(to: 0)
                t.column("statAdditions", .integer).notNull().defaults(to: 0)
                t.column("statDeletions", .integer).notNull().defaults(to: 0)
                t.column("filesChanged", .integer).notNull().defaults(to: 0)
                t.column("isMerge", .boolean).notNull().defaults(to: false)
                t.column("isReachable", .boolean).notNull().defaults(to: true)
                t.uniqueKey(["repoId", "sha"])
            }
            try db.create(index: "idx_commit_date", on: "gitCommit", columns: ["authorDate"])
            try db.create(index: "idx_commit_repo_date", on: "gitCommit", columns: ["repoId", "authorDate"])
            try db.create(table: "commitFile") { t in
                t.column("commitId", .integer).notNull().references("gitCommit", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("oldPath", .text)
                t.column("additions", .integer)
                t.column("deletions", .integer)
                t.primaryKey(["commitId", "path"])
            }
            try db.create(table: "ticket") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("key", .text).notNull().unique()
                t.column("title", .text)
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("notes", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("doneAt", .datetime)
            }
            try db.create(table: "commitTicket") { t in
                t.column("commitId", .integer).notNull().references("gitCommit", onDelete: .cascade)
                t.column("ticketId", .integer).notNull().references("ticket", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.primaryKey(["commitId", "ticketId"])
            }
            try db.create(index: "idx_commitTicket_ticket", on: "commitTicket", columns: ["ticketId"])
            try db.create(table: "task") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("ticketId", .integer).references("ticket", onDelete: .setNull)
                t.column("repoId", .integer).references("repo", onDelete: .setNull)
                t.column("commitId", .integer).references("gitCommit", onDelete: .setNull)
                t.column("tags", .text)
                t.column("dueDate", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("sortOrder", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "periodNote") { t in
                t.primaryKey("key", .text)
                t.column("text", .text).notNull()
            }
        }
        return m
    }
}
