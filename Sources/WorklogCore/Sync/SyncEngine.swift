import Foundation
import GRDB

public enum SyncEvent: Sendable {
    case started(repoId: Int64, name: String)
    case finished(repoId: Int64, newCommits: Int)
    case failed(repoId: Int64, message: String)
}

/// Incremental, read-only scanning of repos into the database.
///
/// Per repo: list refs → find refs whose tip moved → one `git log <moved refs> ^<old tips>` (default branch first,
/// then feature branches excluding the default branch, so branch-name tickets only come from real feature work)
/// → upsert in one transaction → store new ref tips. A tip that isn't an ancestor of its new value (rebase,
/// force-push) or a deleted ref triggers a reachability refresh so rewritten commits are hidden, not duplicated.
public actor SyncEngine {
    public let db: AppDatabase
    public let git: GitClient
    private var running = Set<Int64>()
    private var dirty = Set<Int64>()
    private var handler: (@Sendable (SyncEvent) -> Void)?

    public init(db: AppDatabase, git: GitClient = GitClient()) {
        self.db = db
        self.git = git
    }

    public func setEventHandler(_ handler: @escaping @Sendable (SyncEvent) -> Void) {
        self.handler = handler
    }

    public var isSyncing: Bool { !running.isEmpty }

    public func syncAll() async {
        let ids = (try? await db.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM repo WHERE isActive = 1 ORDER BY id")
        }) ?? []
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for id in ids {
                if inFlight >= 4 { await group.next(); inFlight -= 1 }
                group.addTask { await self.sync(repoId: id) }
                inFlight += 1
            }
        }
    }

    /// Coalesces: a request while this repo is syncing makes it run once more afterwards.
    public func sync(repoId: Int64) async {
        if running.contains(repoId) { dirty.insert(repoId); return }
        running.insert(repoId)
        repeat {
            dirty.remove(repoId)
            await syncOnce(repoId)
        } while dirty.contains(repoId)
        running.remove(repoId)
    }

    /// Identities changed: forget cursors, drop commits by authors no longer listed, rescan everything.
    public func rescanAll() async {
        _ = try? await db.writer.write { db in
            try db.execute(sql: "DELETE FROM refCursor")
            let emails = try String.fetchAll(db, sql: "SELECT lower(email) FROM identity")
            if emails.isEmpty {
                try db.execute(sql: "DELETE FROM gitCommit")
            } else {
                let placeholders = databaseQuestionMarks(count: emails.count)
                try db.execute(sql: "DELETE FROM gitCommit WHERE lower(authorEmail) NOT IN (\(placeholders))", arguments: StatementArguments(emails))
            }
            try CommitIngest.pruneOrphanTickets(db: db)
        }
        await syncAll()
    }

    private struct Snapshot {
        var repo: Repo
        var settings: AppSettings
        var emails: [String]
        var cursors: [RefCursor]
    }

    private func syncOnce(_ repoId: Int64) async {
        guard let snap = try? await db.writer.read({ db -> Snapshot? in
            guard let repo = try Repo.fetchOne(db, key: repoId) else { return nil }
            return Snapshot(
                repo: repo,
                settings: try AppSettings.load(db),
                emails: try String.fetchAll(db, sql: "SELECT email FROM identity"),
                cursors: try RefCursor.filter(Column("repoId") == repoId).fetchAll(db)
            )
        }) else { return }
        var repo = snap.repo
        handler?(.started(repoId: repoId, name: repo.name))

        do {
            guard FileManager.default.fileExists(atPath: repo.path) else {
                throw GitError("Folder not found: \(repo.path)")
            }
            let path = repo.path
            let refs = try await git.refs(path)
            if repo.defaultBranch == nil { repo.defaultBranch = await git.defaultBranch(path, refs: refs) }
            if repo.gitDir == nil { repo.gitDir = await git.commonGitDir(path) }
            repo.isShallow = await git.isShallow(path)

            let cursorByRef = Dictionary(snap.cursors.map { ($0.refName, $0) }, uniquingKeysWith: { a, _ in a })
            let liveRefs = Set(refs.map(\.name))
            let moved = refs.filter { cursorByRef[$0.name]?.lastSha != $0.sha }
            let deleted = snap.cursors.filter { !liveRefs.contains($0.refName) }
            var newCommits = 0

            if !snap.emails.isEmpty, !moved.isEmpty || !deleted.isEmpty {
                var rewritten = !deleted.isEmpty
                for ref in moved {
                    guard let old = cursorByRef[ref.name] else { continue }
                    if await !git.isAncestor(old.lastSha, of: ref.sha, repo: path) { rewritten = true; break }
                }

                let since = snap.settings.scanStart()
                let oldTips = Array(await git.existingCommits(Array(Set(snap.cursors.map(\.lastSha))), repo: path))
                let isDefault: (GitRef) -> Bool = { ref in
                    guard let d = repo.defaultBranch else { return false }
                    return GitRef.branchName(ref.name) == d
                }
                let defaultRefs = refs.filter(isDefault)
                let movedDefault = moved.filter(isDefault)
                let movedOther = moved.filter { !isDefault($0) }

                let onDefault = try await git.log(repo: path, include: movedDefault.map(\.name), exclude: oldTips, since: since, authors: snap.emails)
                let logged = onDefault + (try await git.log(repo: path, include: movedOther.map(\.name), exclude: oldTips + defaultRefs.map(\.name), since: since, authors: snap.emails))

                let reachable = rewritten
                    ? try await git.reachableShas(repo: path, refs: refs.map(\.name), since: since, authors: snap.emails)
                    : nil
                let extractor = snap.settings.ticketExtractor()
                let exclusion = snap.settings.pathExclusion()
                let repoForIngest = repo
                newCommits = try await db.writer.write { db in
                    let n = try CommitIngest.ingest(logged, repo: repoForIngest, extractor: extractor, exclusion: exclusion, db: db)
                    if let reachable {
                        try CommitIngest.updateReachability(repoId: repoId, reachable: reachable, since: since, db: db)
                    }
                    try db.execute(sql: "DELETE FROM refCursor WHERE repoId = ?", arguments: [repoId])
                    let now = Date()
                    for ref in refs {
                        try RefCursor(repoId: repoId, refName: ref.name, lastSha: ref.sha, updatedAt: now).insert(db)
                    }
                    return n
                }
            }

            let finished = repo
            try await db.writer.write { db in
                try db.execute(sql: """
                    UPDATE repo SET lastSyncedAt = ?, lastError = NULL, defaultBranch = ?, gitDir = ?, isShallow = ? WHERE id = ?
                    """, arguments: [Date(), finished.defaultBranch, finished.gitDir, finished.isShallow, repoId])
            }
            handler?(.finished(repoId: repoId, newCommits: newCommits))
        } catch {
            let message = (error as? GitError)?.message ?? error.localizedDescription
            _ = try? await db.writer.write { db in
                try db.execute(sql: "UPDATE repo SET lastError = ? WHERE id = ?", arguments: [message, repoId])
            }
            handler?(.failed(repoId: repoId, message: message))
        }
    }
}
