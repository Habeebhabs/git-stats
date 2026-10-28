import Foundation
import GRDB

public struct Repo: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "repo"
    public var id: Int64?
    public var path: String
    public var name: String
    public var color: String
    public var defaultBranch: String?
    public var gitDir: String?
    public var isActive: Bool
    public var isShallow: Bool
    public var addedAt: Date
    public var lastSyncedAt: Date?
    public var lastError: String?

    public init(path: String, name: String, color: String) {
        self.path = path
        self.name = name
        self.color = color
        self.isActive = true
        self.isShallow = false
        self.addedAt = Date()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let palette = ["#5EE89B", "#F2C46D", "#B9A4FF", "#6BA6FF", "#F28B82", "#7DCFE0"]
}

public struct Identity: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "identity"
    public var id: Int64?
    public var email: String
    public var name: String?

    public init(email: String, name: String? = nil) {
        self.email = email
        self.name = name
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct RefCursor: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "refCursor"
    public var repoId: Int64
    public var refName: String
    public var lastSha: String
    public var updatedAt: Date
}

public struct Commit: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "gitCommit"
    public var id: Int64?
    public var repoId: Int64
    public var sha: String
    public var shortSha: String
    public var authorEmail: String
    public var authorDate: Date
    public var commitDate: Date
    public var subject: String
    public var body: String?
    public var branchHint: String?
    public var additions: Int
    public var deletions: Int
    /// Additions/deletions after path exclusions (lockfiles, generated code). Used for stats.
    public var statAdditions: Int
    public var statDeletions: Int
    public var filesChanged: Int
    public var isMerge: Bool
    public var isReachable: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct CommitFile: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "commitFile"
    public var commitId: Int64
    public var path: String
    public var oldPath: String?
    public var additions: Int?
    public var deletions: Int?
}

public enum TicketStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case active, review, done

    public var label: String {
        switch self {
        case .active: "active"
        case .review: "review"
        case .done: "done"
        }
    }
}

public struct Ticket: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "ticket"
    public var id: Int64?
    public var key: String
    public var title: String?
    public var status: TicketStatus
    public var notes: String?
    public var createdAt: Date
    public var doneAt: Date?

    public init(key: String) {
        self.key = key
        self.status = .active
        self.createdAt = Date()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct CommitTicket: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "commitTicket"
    public var commitId: Int64
    public var ticketId: Int64
    public var source: String   // subject | body | branch | manual
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pending
    case inProgress = "in_progress"
    case done

    public var label: String {
        switch self {
        case .pending: "pending"
        case .inProgress: "in progress"
        case .done: "done"
        }
    }

    public var next: TaskStatus {
        switch self {
        case .pending: .inProgress
        case .inProgress: .done
        case .done: .pending
        }
    }
}

public struct WorkTask: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "task"
    public var id: Int64?
    public var title: String
    public var notes: String?
    public var status: TaskStatus
    public var ticketId: Int64?
    public var repoId: Int64?
    public var commitId: Int64?
    public var tags: String?
    public var dueDate: Date?
    public var createdAt: Date
    public var completedAt: Date?
    public var sortOrder: Double

    public init(title: String, status: TaskStatus = .pending, sortOrder: Double = 0) {
        self.title = title
        self.status = status
        self.createdAt = Date()
        self.sortOrder = sortOrder
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct PeriodNote: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "periodNote"
    public var key: String     // e.g. 2026-Q3, or 2026-07-01..2026-09-30
    public var text: String
}
