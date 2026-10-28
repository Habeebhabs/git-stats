import Foundation
import GRDB
import Testing
@testable import WorklogCore

/// A throwaway git repo with scripted commits.
final class TempRepo: @unchecked Sendable {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("worklog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "me@example.com")
        try git("config", "user.name", "Me")
        try git("config", "commit.gpgsign", "false")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func git(_ args: String..., env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        var e = ProcessInfo.processInfo.environment
        e.merge(env) { $1 }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitError("git \(args.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ message: String, file: String = "file.txt", content: String? = nil, daysAgo: Int = 1,
                email: String = "me@example.com") throws {
        let fileURL = url.appendingPathComponent(file)
        let text = (content ?? message) + "\n"
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try h.close()
        } else {
            try Data(text.utf8).write(to: fileURL)
        }
        try git("add", "-A")
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-daysAgo) * 86_400))
        try git("commit", "-q", "-m", message, env: [
            "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
            "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_EMAIL": email,
        ])
    }
}

@Suite(.serialized) struct SyncEngineTests {
    func setup(_ repo: TempRepo, emails: [String] = ["me@example.com"]) async throws -> (AppDatabase, SyncEngine, Int64) {
        let db = try AppDatabase.inMemory()
        let id = try await db.writer.write { db -> Int64 in
            for e in emails { try Mutations.addIdentity(email: e, db: db) }
            return try Mutations.addRepo(path: repo.path, db: db)!.id!
        }
        return (db, SyncEngine(db: db), id)
    }

    func reachable(_ db: AppDatabase) async throws -> [CommitRow] {
        try await db.writer.read { try Queries.commits($0, filter: CommitFilter(), limit: 1000) }
    }

    @Test func initialScanFiltersAuthorsAndExtractsTickets() async throws {
        let repo = try TempRepo()
        try repo.commit("Initial commit", daysAgo: 10)
        try repo.commit("Someone else's work", daysAgo: 9, email: "other@example.com")
        try repo.commit("feat: PAY-1 ledger", daysAgo: 8)
        try repo.git("checkout", "-q", "-b", "feat/PAY-218-ledger-v2")
        try repo.commit("Add backfill job", file: "job.kt", daysAgo: 5)
        try repo.commit("Update package-lock", file: "package-lock.json", content: String(repeating: "x\n", count: 50), daysAgo: 4)
        try repo.git("checkout", "-q", "main")

        let (db, engine, repoId) = try await setup(repo)
        await engine.sync(repoId: repoId)

        let rows = try await reachable(db)
        #expect(rows.map(\.subject) == ["Update package-lock", "Add backfill job", "feat: PAY-1 ledger", "Initial commit"])
        let byTitle = Dictionary(uniqueKeysWithValues: rows.map { ($0.subject, $0) })
        #expect(byTitle["Add backfill job"]?.tickets == ["PAY-218"])
        #expect(byTitle["feat: PAY-1 ledger"]?.tickets == ["PAY-1"])
        #expect(byTitle["Initial commit"]?.tickets == [])  // on main: no branch ticket
        // lockfile counted in raw lines but excluded from stats
        #expect(byTitle["Update package-lock"]!.additions == 51)
        #expect(byTitle["Update package-lock"]!.statAdditions == 0)

        let repoRow = try await db.writer.read { try Repo.fetchOne($0, key: repoId) }
        #expect(repoRow?.defaultBranch == "main")
        #expect(repoRow?.lastError == nil)
        #expect(repoRow?.gitDir?.hasSuffix(".git") == true)
    }

    @Test func incrementalSyncAddsOnlyNewCommits() async throws {
        let repo = try TempRepo()
        try repo.commit("one", daysAgo: 3)
        let (db, engine, repoId) = try await setup(repo)
        await engine.sync(repoId: repoId)
        #expect(try await reachable(db).count == 1)

        try repo.commit("two", daysAgo: 0)
        await engine.sync(repoId: repoId)
        let rows = try await reachable(db)
        #expect(rows.map(\.subject) == ["two", "one"])

        // No changes → nothing happens
        await engine.sync(repoId: repoId)
        #expect(try await reachable(db).count == 2)
    }

    @Test func rebaseHidesRewrittenCommitsWithoutDuplicates() async throws {
        let repo = try TempRepo()
        try repo.commit("base", daysAgo: 3)
        try repo.commit("PAY-9 work in progress", daysAgo: 2)
        let (db, engine, repoId) = try await setup(repo)
        await engine.sync(repoId: repoId)
        let before = try await reachable(db)
        #expect(before.count == 2)

        try repo.git("commit", "-q", "--amend", "-m", "PAY-9 finished work")
        await engine.sync(repoId: repoId)
        let after = try await reachable(db)
        #expect(after.map(\.subject).sorted() == ["PAY-9 finished work", "base"])
        let total = try await db.writer.read { try Commit.fetchCount($0) }
        #expect(total == 3)  // old one kept, hidden
    }

    @Test func deletedBranchHidesItsCommits() async throws {
        let repo = try TempRepo()
        try repo.commit("base", daysAgo: 3)
        try repo.git("checkout", "-q", "-b", "spike")
        try repo.commit("spike work", daysAgo: 2)
        try repo.git("checkout", "-q", "main")
        let (db, engine, repoId) = try await setup(repo)
        await engine.sync(repoId: repoId)
        #expect(try await reachable(db).count == 2)

        try repo.git("branch", "-q", "-D", "spike")
        await engine.sync(repoId: repoId)
        #expect(try await reachable(db).map(\.subject) == ["base"])
    }

    @Test func addingIdentityRescans() async throws {
        let repo = try TempRepo()
        try repo.commit("mine", daysAgo: 3)
        try repo.commit("from my work laptop", daysAgo: 2, email: "me@work.com")
        let (db, engine, repoId) = try await setup(repo)
        await engine.sync(repoId: repoId)
        #expect(try await reachable(db).count == 1)

        try await db.writer.write { try Mutations.addIdentity(email: "ME@work.com", db: $0) }
        await engine.rescanAll()
        #expect(try await reachable(db).count == 2)
    }

    @Test func diffLoadsAndParses() async throws {
        let repo = try TempRepo()
        try repo.commit("first", file: "a.txt", content: "hello", daysAgo: 2)
        try repo.commit("second", file: "a.txt", content: "world", daysAgo: 1)
        let sha = try repo.git("rev-parse", "HEAD")
        let patch = try await GitClient().patch(repo: repo.path, sha: sha, isMerge: false)
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 1)
        #expect(files[0].newPath == "a.txt")
        #expect(files[0].additions == 1)
        #expect(files[0].hunks[0].lines.last?.text == "world")
    }
}

@Suite struct StoreQueryTests {
    @Test func tasksTicketsAndReport() async throws {
        let db = try AppDatabase.inMemory()
        let now = Date()
        try await db.writer.write { db in
            var repo = try Mutations.addRepo(path: "/tmp/payments-api", db: db)!
            repo.defaultBranch = "main"
            try repo.update(db)
            let logged = [
                LoggedCommit(sha: String(repeating: "a", count: 40), shortSha: "aaaaaaa", authorEmail: "me@x.com", authorName: "Me",
                             authorDate: now.addingTimeInterval(-3600), commitDate: now, parents: ["p"], source: "refs/heads/main",
                             subject: "PAY-204 Exponential backoff", body: "", files: [NumstatEntry(path: "a.kt", additions: 60, deletions: 20)]),
                LoggedCommit(sha: String(repeating: "b", count: 40), shortSha: "bbbbbbb", authorEmail: "me@x.com", authorName: "Me",
                             authorDate: now.addingTimeInterval(-7200), commitDate: now, parents: ["p"], source: "refs/heads/main",
                             subject: "Tidy imports", body: "", files: [NumstatEntry(path: "b.kt", additions: 1, deletions: 1)]),
            ]
            try CommitIngest.ingest(logged, repo: repo, extractor: TicketExtractor(), exclusion: PathExclusion(globs: []), db: db)
            try Mutations.addTask("Fix flaky checkout test PAY-204 #bug", db: db)
            try Mutations.addTask("Prepare demo notes", db: db)
            let ticketId = try Int64.fetchOne(db, sql: "SELECT id FROM ticket WHERE key = 'PAY-204'")!
            try Mutations.setTicketStatus(id: ticketId, status: .done, db: db)
            let taskId = try Int64.fetchOne(db, sql: "SELECT id FROM task WHERE title LIKE 'Fix%'")!
            try Mutations.setTaskStatus(id: taskId, status: .done, db: db)
        }

        let tasks = try await db.writer.read { try Queries.tasks($0) }
        #expect(tasks.count == 2)
        #expect(tasks.first?.task.title == "Prepare demo notes")  // open tasks first
        let fix = tasks.first { $0.ticketKey == "PAY-204" }!
        #expect(fix.ticketCommitCount == 1)
        #expect(fix.task.tagList == ["bug"])

        let interval = RangePreset.week.interval(now: now)
        let tickets = try await db.writer.read { try Queries.ticketSummaries($0, interval: DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(60))) }
        #expect(tickets.map(\.key) == ["PAY-204"])
        #expect(tickets[0].additions == 60)
        #expect(tickets[0].displayTitle == "PAY-204 Exponential backoff")

        let reportInterval = DateInterval(start: now.addingTimeInterval(-86_400 * 2), end: now.addingTimeInterval(86_400))
        let data = try await db.writer.read {
            try ReportBuilder.load($0, interval: reportInterval, repoIds: [], notes: "Shipped retries.", countWeekends: true, now: now)
        }
        let md = ReportBuilder.markdown(data, sections: Set(ReportSection.allCases), grouping: .projectTicket)
        #expect(md.contains("**2 commits · 1 tickets done"))
        #expect(md.contains("## payments-api"))
        #expect(md.contains("### PAY-204 — PAY-204 Exponential backoff (done)"))
        #expect(md.contains("- 1 commit · +60 / \u{2212}20"))
        #expect(md.contains("### Other work (no ticket)"))
        #expect(md.contains("## Completed tasks\n- Fix flaky checkout test (PAY-204)"))
        #expect(md.contains("## Pending tasks\n- Prepare demo notes"))
        #expect(md.contains("Shipped retries."))
        _ = interval
    }
}
