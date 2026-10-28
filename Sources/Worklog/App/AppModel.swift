import AppKit
import GRDB
import SwiftUI
import WorklogCore

enum AppSection: Int, CaseIterable, Identifiable {
    case overview = 1, commits, tickets, tasks, reports

    var id: Int { rawValue }
    var key: String { String(rawValue) }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .commits: "Commits"
        case .tickets: "Tickets"
        case .tasks: "Tasks"
        case .reports: "Reports"
        }
    }
}

enum DiffMode: String { case unified, split }

/// Commit Detail with its list context for ↑/↓.
struct CommitNav: Equatable {
    var ids: [Int64]
    var index: Int
    var current: Int64 { ids[index] }
}

struct SameTicketContext: Equatable {
    struct Item: Hashable { let id: Int64; let sha: String; let subject: String }
    var key: String
    var items: [Item]
}

/// A key press the Commit Detail view reacts to (`[`, `]`).
struct DetailKey: Equatable {
    let key: String
    let seq: Int
}

@MainActor @Observable
final class AppModel {
    let db: AppDatabase
    let git = GitClient()
    let engine: SyncEngine
    let palette = PaletteModel()

    // Navigation
    var section: AppSection = .overview { didSet { detail = nil } }
    var range: RangePreset = .quarter
    var detail: CommitNav?
    var sameTicket: SameTicketContext?
    var sidebarVisible = true
    var showOnboarding = false
    var diffMode: DiffMode = .unified
    var detailKey: DetailKey?
    var commitsRepoFilter: Int64?
    var commitsTicketFilter: String?
    var selectedTicketId: Int64?
    var taskFocusTrigger = 0
    var toast: String?

    // Data for the shell
    var revision = 0
    var repos: [Repo] = []
    var repoCounts: [Int64: Int] = [:]
    var identities: [Identity] = []
    var settings = AppSettings()
    var navCommitCount = 0
    var navTicketCount = 0
    var navOpenTasks = 0
    var syncingNames: [Int64: String] = [:]
    var lastSyncAt: Date?
    var gitVersion: String?
    var dbError: String?

    @ObservationIgnored private var watcher: RepoWatcher?
    @ObservationIgnored private var observer: AnyDatabaseCancellable?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var keySeq = 0
    @ObservationIgnored private var diffCache: [Int64: String] = [:]
    @ObservationIgnored private var diffOrder: [Int64] = []
    @ObservationIgnored weak var mainWindow: NSWindow?

    init() {
        let database: AppDatabase
        do {
            database = try AppDatabase.onDisk()
        } catch {
            database = try! AppDatabase.inMemory()
            dbError = "Couldn't open the database: \(error.localizedDescription). Running in memory."
        }
        db = database
        engine = SyncEngine(db: database)
        palette.model = self
    }

    var interval: DateInterval { range.interval() }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        observer = DatabaseRegionObservation(tracking: .fullDatabase).start(
            in: db.writer,
            onError: { _ in },
            onChange: { [weak self] _ in
                Task { @MainActor in self?.databaseChanged() }
            }
        )
        watcher = RepoWatcher { [weak self] repoId in
            Task { @MainActor in await self?.engine.sync(repoId: repoId) }
        }
        let engine = self.engine
        let handler: @Sendable (SyncEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        Task { await engine.setEventHandler(handler) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }

        Task {
            gitVersion = await git.version()
            await reloadShell()
            if !settings.onboarded && repos.isEmpty { showOnboarding = true }
            refresh()
            DebugSnapshots.runIfRequested(self)
        }
    }

    private func databaseChanged() {
        revision += 1
        Task { await reloadShell() }
    }

    func reloadShell() async {
        let interval = self.interval
        struct Shell: Sendable {
            var repos: [Repo], identities: [Identity], settings: AppSettings, counts: [Int64: Int]
            var commits: Int, tickets: Int, openTasks: Int
        }
        guard let shell = try? await db.writer.read({ db in
            Shell(
                repos: try Repo.order(Column("addedAt")).fetchAll(db),
                identities: try Identity.order(Column("email")).fetchAll(db),
                settings: try AppSettings.load(db),
                counts: try Queries.repoCommitCounts(db, interval: interval),
                commits: try Queries.facts(db, interval: interval).filter { !$0.isMerge }.count,
                tickets: try Ticket.fetchCount(db),
                openTasks: try WorkTask.filter(Column("status") != TaskStatus.done.rawValue).fetchCount(db)
            )
        }) else { return }
        repos = shell.repos
        identities = shell.identities
        settings = shell.settings
        repoCounts = shell.counts
        navCommitCount = shell.commits
        navTicketCount = shell.tickets
        navOpenTasks = shell.openTasks
        var watched: [Int64: String] = [:]
        for r in repos where r.isActive { if let id = r.id, let dir = r.gitDir { watched[id] = dir } }
        watcher?.update(watched)
    }

    private func handle(_ event: SyncEvent) {
        switch event {
        case let .started(id, name): syncingNames[id] = name
        case let .finished(id, _): syncingNames[id] = nil; lastSyncAt = Date()
        case let .failed(id, _): syncingNames[id] = nil; lastSyncAt = Date()
        }
    }

    var syncStatus: String {
        if let name = syncingNames.values.sorted().first { return "syncing \(name)…" }
        guard let last = lastSyncAt else { return repos.isEmpty ? "no repos yet" : "not synced" }
        return Date().timeIntervalSince(last) < 60 ? "synced just now" : "synced \(Fmt.relative(last))"
    }

    func refresh() {
        let engine = self.engine
        Task { await engine.syncAll() }
    }

    func setRange(_ r: RangePreset) {
        range = r
        Task { await reloadShell() }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if palette.isOpen {
            switch event.keyCode {
            case 126: palette.move(-1); return true
            case 125: palette.move(1); return true
            case 36, 76: palette.performSelected(); return true
            case 53: palette.close(); return true
            default: return false
            }
        }
        guard let window = mainWindow, event.window === window, !showOnboarding else { return false }
        if window.firstResponder is NSTextView {
            if event.keyCode == 53 { window.makeFirstResponder(nil); return true }
            return false
        }
        guard mods.isEmpty else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        if let n = Int(chars), let s = AppSection(rawValue: n) {
            section = s
            return true
        }
        if detail != nil {
            switch (event.keyCode, chars) {
            case (53, _): detail = nil; return true
            case (126, _): stepCommit(-1); return true
            case (125, _): stepCommit(1); return true
            case (_, "u"): diffMode = .unified; return true
            case (_, "s"): diffMode = .split; return true
            case (_, "["), (_, "]"):
                keySeq += 1
                detailKey = DetailKey(key: chars, seq: keySeq)
                return true
            default: break
            }
        }
        return false
    }

    // MARK: Navigation

    func openCommit(_ id: Int64, context: [Int64]) {
        let ids = context.contains(id) ? context : [id]
        detail = CommitNav(ids: ids, index: ids.firstIndex(of: id) ?? 0)
    }

    func stepCommit(_ delta: Int) {
        guard var nav = detail else { return }
        let next = nav.index + delta
        guard nav.ids.indices.contains(next) else { return }
        nav.index = next
        detail = nav
    }

    func openTicket(_ id: Int64) {
        section = .tickets
        selectedTicketId = id
    }

    func showCommits(repo: Int64? = nil, ticket: String? = nil) {
        commitsRepoFilter = repo
        commitsTicketFilter = ticket
        section = .commits
    }

    func newTask() {
        section = .tasks
        taskFocusTrigger += 1
    }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }

    // MARK: Repos & identities

    /// Adds repos (resolving to their top level), picks up each repo's local `user.email`, then scans.
    @discardableResult
    func addRepos(_ urls: [URL]) async -> Int {
        var tops: [String] = []
        var emails: [String] = []
        for url in urls {
            guard let top = await git.topLevel(url.path) else { continue }
            tops.append(top)
            if let email = await git.configEmail(repo: top) { emails.append(email) }
        }
        if identities.isEmpty, let global = await git.configEmail() { emails.insert(global, at: 0) }
        let globalName = await git.configName()
        let newEmails = emails, newTops = tops
        let result = try? await db.writer.write { db -> (added: [Int64], newIdentity: Bool) in
            var added: [Int64] = []
            var newIdentity = false
            for e in newEmails where try Mutations.addIdentity(email: e, name: globalName, db: db) { newIdentity = true }
            for path in newTops {
                if let repo = try Mutations.addRepo(path: path, db: db), let id = repo.id { added.append(id) }
            }
            return (added, newIdentity)
        }
        guard let result else { return 0 }
        let engine = self.engine
        if result.newIdentity {
            Task { await engine.rescanAll() }
        } else {
            for id in result.added { Task { await engine.sync(repoId: id) } }
        }
        if !result.added.isEmpty { flash("added \(result.added.count) repo\(result.added.count == 1 ? "" : "s")") }
        return result.added.count
    }

    func pickRepos() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add repo"
        panel.message = "Choose one or more git repositories"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addRepos(urls) }
    }

    func updateRepo(_ repo: Repo) {
        Task {
            _ = try? await db.writer.write { db in try repo.update(db) }
            refresh()
        }
    }

    func removeRepo(_ repo: Repo) {
        Task {
            _ = try? await db.writer.write { db in
                _ = try repo.delete(db)
                try CommitIngest.pruneOrphanTickets(db: db)
            }
        }
    }

    func addIdentity(_ email: String) {
        Task {
            let added = (try? await db.writer.write { db in try Mutations.addIdentity(email: email, db: db) }) ?? false
            if added { await engine.rescanAll() }
        }
    }

    /// Emails that commit in the added repos but aren't identities yet.
    func suggestedEmails() async -> [String] {
        let known = Set(identities.map { $0.email.lowercased() })
        var totals: [String: Int] = [:]
        for repo in repos where repo.isActive {
            for (email, n) in await git.recentAuthorEmails(repo.path) where !known.contains(email) {
                totals[email, default: 0] += n
            }
        }
        return totals.sorted { $0.value > $1.value }.prefix(6).map(\.key)
    }

    func removeIdentity(_ identity: Identity) {
        Task {
            _ = try? await db.writer.write { db in try identity.delete(db) }
            await engine.rescanAll()
        }
    }

    /// Saves settings and re-derives whatever the change affects.
    func saveSettings(_ new: AppSettings) {
        let old = settings
        settings = new
        Task {
            _ = try? await db.writer.write { db in
                try new.save(db)
                if new.ticketPattern != old.ticketPattern || new.ticketAllowlist != old.ticketAllowlist || new.githubIssueRefs != old.githubIssueRefs {
                    try CommitIngest.reprocessTickets(extractor: new.ticketExtractor(), db: db)
                }
                if new.excludedGlobs != old.excludedGlobs {
                    try CommitIngest.recomputeLineStats(exclusion: new.pathExclusion(), db: db)
                }
            }
            if new.scanWindowMonths != old.scanWindowMonths { await engine.rescanAll() }
        }
    }

    func finishOnboarding() {
        var s = settings
        s.onboarded = true
        saveSettings(s)
        showOnboarding = false
        Task { await engine.rescanAll() }
    }

    // MARK: Tasks

    func addTask(_ text: String, repoId: Int64? = nil, commitId: Int64? = nil) {
        Task {
            _ = try? await db.writer.write { db in try Mutations.addTask(text, repoId: repoId, commitId: commitId, db: db) }
        }
    }

    func setTaskStatus(_ id: Int64, _ status: TaskStatus) {
        Task { _ = try? await db.writer.write { db in try Mutations.setTaskStatus(id: id, status: status, db: db) } }
    }

    func toggleTask(_ task: WorkTask) {
        guard let id = task.id else { return }
        setTaskStatus(id, task.status == .done ? .pending : .done)
    }

    func saveTask(_ task: WorkTask) {
        Task { _ = try? await db.writer.write { db in try task.update(db) } }
    }

    func setTaskTicket(_ id: Int64, key: String?) {
        Task { _ = try? await db.writer.write { db in try Mutations.setTaskTicket(id: id, key: key, db: db) } }
    }

    func moveTask(_ id: Int64, before: Int64?) {
        Task { _ = try? await db.writer.write { db in try Mutations.moveTask(id: id, before: before, db: db) } }
    }

    /// Deletes with undo (⌘Z).
    func deleteTask(_ task: WorkTask, undoManager: UndoManager?) {
        Task {
            _ = try? await db.writer.write { db in try task.delete(db) }
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let restored = task
                Task { _ = try? await model.db.writer.write { db in var t = restored; try t.insert(db) } }
            }
        }
        undoManager?.setActionName("Delete Task")
        flash("task deleted · ⌘Z to undo")
    }

    // MARK: Tickets

    func setTicketStatus(_ id: Int64, _ status: TicketStatus) {
        Task { _ = try? await db.writer.write { db in try Mutations.setTicketStatus(id: id, status: status, db: db) } }
    }

    func saveTicket(id: Int64, title: String, notes: String) {
        Task {
            _ = try? await db.writer.write { db in
                try db.execute(sql: "UPDATE ticket SET title = ?, notes = ? WHERE id = ?",
                               arguments: [title.nonEmpty, notes.nonEmpty, id])
            }
        }
    }

    func linkTicket(commitId: Int64, key: String) {
        let k = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard !k.isEmpty else { return }
        Task { _ = try? await db.writer.write { db in try Mutations.linkTicket(commitId: commitId, key: k, db: db) } }
    }

    func unlinkTicket(commitId: Int64, ticketId: Int64) {
        Task { _ = try? await db.writer.write { db in try Mutations.unlinkTicket(commitId: commitId, ticketId: ticketId, db: db) } }
    }

    // MARK: Diffs & editor

    /// Patch text for a commit, cached (LRU, 50 commits).
    func patch(for commit: CommitRow) async throws -> String {
        if let cached = diffCache[commit.id] {
            diffOrder.removeAll { $0 == commit.id }
            diffOrder.append(commit.id)
            return cached
        }
        let text = try await git.patch(repo: commit.repoPath, sha: commit.sha, isMerge: commit.isMerge)
        diffCache[commit.id] = text
        diffOrder.append(commit.id)
        if diffOrder.count > 50 { diffCache[diffOrder.removeFirst()] = nil }
        return text
    }

    func openInEditor(repoPath: String, file: String, line: Int) {
        let full = (repoPath as NSString).appendingPathComponent(file)
        let template = settings.editorTemplate
        guard !template.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: full))
            return
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = template
            .replacingOccurrences(of: "{file}", with: quote(full))
            .replacingOccurrences(of: "{line}", with: String(line))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        process.terminationHandler = { p in
            if p.terminationStatus != 0 {
                Task { @MainActor in NSWorkspace.shared.open(URL(fileURLWithPath: full)) }
            }
        }
        do { try process.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: full)) }
    }

    func copy(_ text: String, message: String = "copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(message)
    }
}
