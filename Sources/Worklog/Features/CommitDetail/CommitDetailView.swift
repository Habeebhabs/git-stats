import GRDB
import SwiftUI
import WorklogCore

struct CommitDetailView: View {
    @Environment(AppModel.self) private var model
    let nav: CommitNav

    @State private var commit: CommitRow?
    @State private var numstat: [CommitFile] = []
    @State private var linked: [LinkedTicket] = []
    @State private var diffs: [FileDiff] = []
    @State private var diffState: DiffLoadState = .loading
    @State private var selectedPath: String?
    @State private var forced: Set<String> = []
    @State private var ticketDraft = ""
    @State private var addingTicket = false

    enum DiffLoadState: Equatable { case loading, ready, tooLarge(Int), failed(String) }

    private static let maxPatchBytes = 2_000_000
    private static let maxFileLines = 3_000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            breadcrumb
            if let commit {
                headerCard(commit)
                FlexRow {
                    fileList.flex(1, min: 250)
                    diffCard(commit).flex(4, min: 560)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .padding(.top, Theme.mainPadding.top)
        .padding(.horizontal, Theme.mainPadding.leading)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(nav.current)-\(model.revision)") { await loadMeta() }
        .task(id: nav.current) { await loadDiff() }
        .onChange(of: model.detailKey) { _, key in
            guard let key else { return }
            stepFile(key.key == "]" ? 1 : -1)
        }
        .onDisappear { model.sameTicket = nil }
    }

    // MARK: Loading

    private func loadMeta() async {
        let id = nav.current
        struct Meta: Sendable {
            var commit: CommitRow?
            var files: [CommitFile]
            var linked: [LinkedTicket]
            var same: SameTicketContext?
        }
        guard let meta = try? await model.db.writer.read({ db -> Meta in
            let c = try Queries.commit(db, id: id)
            let linked = try Queries.linkedTickets(db, commitId: id)
            var same: SameTicketContext?
            if let key = linked.first?.ticket.key {
                var f = CommitFilter()
                f.ticketKey = key
                f.includeMerges = false
                let rows = try Queries.commits(db, filter: f, limit: 6)
                same = SameTicketContext(key: key, items: rows.map { .init(id: $0.id, sha: $0.shortSha, subject: $0.subject) })
            }
            return Meta(commit: c, files: try Queries.files(db, commitId: id), linked: linked, same: same)
        }) else { return }
        commit = meta.commit
        numstat = meta.files
        linked = meta.linked
        model.sameTicket = meta.same
    }

    private func loadDiff(force: Bool = false) async {
        let id = nav.current
        guard let c = try? await model.db.writer.read({ db in try Queries.commit(db, id: id) }) else { return }
        diffState = .loading
        do {
            let patch = try await model.patch(for: c)
            let size = patch.utf8.count
            if size > Self.maxPatchBytes && !force {
                diffState = .tooLarge(size)
                return
            }
            let parsed = await Task.detached { UnifiedDiffParser.parse(patch) }.value
            diffs = parsed
            if selectedPath == nil || !parsed.contains(where: { $0.newPath == selectedPath }) {
                selectedPath = parsed.first?.newPath
            }
            diffState = .ready
        } catch {
            diffState = .failed((error as? GitError)?.message ?? error.localizedDescription)
        }
    }

    private func stepFile(_ delta: Int) {
        guard let i = diffs.firstIndex(where: { $0.newPath == selectedPath }) else { return }
        let next = i + delta
        if diffs.indices.contains(next) { selectedPath = diffs[next].newPath }
    }

    private var selectedDiff: FileDiff? { diffs.first { $0.newPath == selectedPath } }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 12) {
            Button("← back") { model.detail = nil }
                .buttonStyle(SecondaryMonoButtonStyle(height: 32, background: .clear))
                .keyboardShortcut(.escape, modifiers: [])
            HStack(spacing: 6) {
                Button(model.section == .commits ? "commits" : model.section.label.lowercased()) { model.detail = nil }
                    .buttonStyle(.plain)
                Text("/")
                Text(commit?.repoName ?? "…")
                Text("/")
                Text(commit?.shortSha ?? "").foregroundStyle(Theme.sha)
            }
            .font(Theme.monoMeta)
            .foregroundStyle(Theme.textMuted)
            Spacer()
            if nav.ids.count > 1 {
                Text("\(nav.index + 1) of \(nav.ids.count)").font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
            }
            Button("↑") { model.stepCommit(-1) }
                .buttonStyle(IconButtonStyle())
                .disabled(nav.index == 0)
                .help("Previous commit (↑)")
                .accessibilityLabel("Previous commit")
            Button("↓") { model.stepCommit(1) }
                .buttonStyle(IconButtonStyle())
                .disabled(nav.index >= nav.ids.count - 1)
                .help("Next commit (↓)")
                .accessibilityLabel("Next commit")
        }
    }

    // MARK: Header

    private func headerCard(_ c: CommitRow) -> some View {
        Card(padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20), spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(c.subject)
                        .font(Theme.detailTitle).tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    if let body = c.body?.nonEmpty {
                        Text(body)
                            .font(Theme.body)
                            .lineSpacing(13 * 0.5)
                            .foregroundStyle(Theme.textBody)
                            .textSelection(.enabled)
                            .lineLimit(8)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button("copy sha") { model.copy(c.sha, message: "sha copied") }
                        .buttonStyle(SecondaryMonoButtonStyle())
                    Button("open in editor") {
                        if let d = selectedDiff ?? diffs.first {
                            model.openInEditor(repoPath: c.repoPath, file: d.newPath, line: d.firstChangedLine)
                        }
                    }
                    .buttonStyle(SecondaryMonoButtonStyle())
                    .disabled(diffs.isEmpty)
                    Menu {
                        Button("Create task from this commit") {
                            model.addTask("\(c.subject) \(c.tickets.first ?? "")", repoId: c.repoId, commitId: c.id)
                            model.flash("task created")
                        }
                        Button("Link to ticket…") { addingTicket = true }
                        Divider()
                        Button("Show all commits for this repo") { model.showCommits(repo: c.repoId) }
                    } label: {
                        Text("···").font(Theme.monoMedium)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 1))
                }
            }
            metaRow(c)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metaRow(_ c: CommitRow) -> some View {
        HStack(spacing: 18) {
            meta("sha") { Text(c.shortSha).foregroundStyle(Theme.sha).textSelection(.enabled) }
            meta("ticket") {
                HStack(spacing: 6) {
                    if linked.isEmpty && !addingTicket {
                        Text("—").foregroundStyle(Theme.textMuted)
                    }
                    ForEach(linked, id: \.ticket.id) { link in
                        HStack(spacing: 4) {
                            Button(link.ticket.key) { if let id = link.ticket.id { model.openTicket(id) } }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                            Button("×") { if let tid = link.ticket.id { model.unlinkTicket(commitId: c.id, ticketId: tid) } }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textMuted)
                                .help("Remove link (\(link.source))")
                        }
                    }
                    if addingTicket {
                        TextField("", text: $ticketDraft, prompt: Text("KEY-123").foregroundStyle(Theme.textMuted))
                            .textFieldStyle(.plain)
                            .frame(width: 90)
                            .foregroundStyle(Theme.textPrimary)
                            .onSubmit {
                                model.linkTicket(commitId: c.id, key: ticketDraft)
                                ticketDraft = ""
                                addingTicket = false
                            }
                    } else {
                        Button("+") { addingTicket = true }.buttonStyle(.plain).foregroundStyle(Theme.textMuted).help("Link a ticket")
                    }
                }
            }
            if let branch = c.branchName {
                meta("branch") { Text(branch).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
            Text(Fmt.detailDate(c.authorDate))
            HStack(spacing: 6) {
                Text("\(c.filesChanged) file\(c.filesChanged == 1 ? "" : "s") ·")
                LineCounts(additions: c.additions, deletions: c.deletions, font: Theme.monoMeta)
            }
            if c.isMerge { Text("merge · vs first parent") }
            Spacer(minLength: 0)
        }
        .font(Theme.monoMeta)
        .foregroundStyle(Theme.textMuted)
    }

    private func meta<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 6) {
            Text(label)
            value()
        }
    }

    // MARK: Files

    private var fileList: some View {
        Card(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10), spacing: 2) {
            SectionLabel("changed files").padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView {
                VStack(spacing: 2) {
                    if diffs.isEmpty {
                        ForEach(numstat, id: \.path) { f in
                            ChangedFileRow(path: f.path, additions: f.additions, deletions: f.deletions, selected: false) {}
                        }
                    } else {
                        ForEach(diffs) { d in
                            ChangedFileRow(path: d.newPath, additions: d.status == .binary ? nil : d.additions,
                                           deletions: d.status == .binary ? nil : d.deletions,
                                           selected: d.newPath == selectedPath) {
                                selectedPath = d.newPath
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Diff

    private func diffCard(_ c: CommitRow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(selectedDiff?.newPath ?? "")
                    .font(Theme.monoMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                if let d = selectedDiff {
                    switch d.status {
                    case .added: NewBadge()
                    case .deleted: Text("deleted").font(Theme.monoSmall).foregroundStyle(Theme.deletion)
                    case .renamed: Text("renamed from \(d.oldPath ?? "?")").font(Theme.monoSmall).foregroundStyle(Theme.textMuted).lineLimit(1)
                    case .binary, .modified: EmptyView()
                    }
                }
                Spacer(minLength: 8)
                MonoSegmentedControl(
                    options: [("unified", DiffMode.unified), ("split", DiffMode.split)],
                    selection: Binding(get: { model.diffMode }, set: { model.diffMode = $0 }),
                    height: 30,
                    background: Theme.bg
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            diffBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var diffBody: some View {
        switch diffState {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            EmptyState(message: "couldn't load diff") {
                Text(message).font(Theme.monoSmall).foregroundStyle(Theme.deletion).multilineTextAlignment(.center).padding(.horizontal)
            }
        case let .tooLarge(bytes):
            EmptyState(message: "large diff · \(Fmt.compact(bytes / 1000)) KB") {
                Button("load anyway") { Task { await loadDiff(force: true) } }.buttonStyle(SecondaryMonoButtonStyle())
            }
        case .ready:
            if let d = selectedDiff {
                if d.status == .binary {
                    EmptyState("binary file changed")
                } else if d.hunks.isEmpty {
                    EmptyState(d.status == .renamed ? "renamed without changes" : "no textual changes")
                } else if d.lineCount > Self.maxFileLines && !forced.contains(d.newPath) {
                    EmptyState(message: "large diff · \(Fmt.thousands(d.lineCount)) lines") {
                        Button("load anyway") { forced.insert(d.newPath) }.buttonStyle(SecondaryMonoButtonStyle())
                    }
                } else if model.diffMode == .unified {
                    UnifiedDiffView(diff: d).id(d.newPath)
                } else {
                    SplitDiffView(diff: d).id(d.newPath)
                }
            } else {
                EmptyState("no file changes")
            }
        }
    }
}

struct ChangedFileRow: View {
    let path: String
    let additions: Int?
    let deletions: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        Button(action: action) {
            HoverBackground(radius: 8, isSelected: selected, selected: Theme.fileSelectedBg) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(Theme.monoMedium)
                        .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(folder.isEmpty ? "/" : folder)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 4)
                        if let additions, let deletions {
                            LineCounts(additions: additions, deletions: deletions)
                        } else {
                            Text("bin").foregroundStyle(Theme.textMuted)
                        }
                    }
                    .font(Theme.monoSmall)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(path)
    }
}
