import Foundation

public struct GitRef: Sendable, Hashable {
    public let name: String   // refs/heads/main, refs/remotes/origin/main
    public let sha: String

    public init(name: String, sha: String) {
        self.name = name
        self.sha = sha
    }

    /// `main`, `origin/feature-x`
    public var shortName: String { GitRef.shortName(name) }

    public static func shortName(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        if ref.hasPrefix("refs/remotes/") { return String(ref.dropFirst("refs/remotes/".count)) }
        return ref
    }

    /// Branch name without the remote, for ticket extraction: `origin/feat/PAY-1` → `feat/PAY-1`.
    public static func branchName(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        if ref.hasPrefix("refs/remotes/") {
            let rest = ref.dropFirst("refs/remotes/".count)
            if let slash = rest.firstIndex(of: "/") { return String(rest[rest.index(after: slash)...]) }
            return String(rest)
        }
        return ref
    }
}

public struct NumstatEntry: Sendable, Equatable {
    public var path: String
    public var oldPath: String?
    public var additions: Int?   // nil for binary
    public var deletions: Int?

    public init(path: String, oldPath: String? = nil, additions: Int?, deletions: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.additions = additions
        self.deletions = deletions
    }

    public var isBinary: Bool { additions == nil }
}

public struct LoggedCommit: Sendable, Equatable {
    public var sha: String
    public var shortSha: String
    public var authorEmail: String
    public var authorName: String
    public var authorDate: Date
    public var commitDate: Date
    public var parents: [String]
    public var source: String?     // ref the commit was reached from (--source)
    public var subject: String
    public var body: String
    public var files: [NumstatEntry]

    public var isMerge: Bool { parents.count > 1 }
    public var additions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    public var deletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
}
