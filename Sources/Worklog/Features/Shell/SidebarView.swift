import SwiftUI
import WorklogCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var renaming: Repo?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Native traffic lights sit here.
            Color.clear.frame(height: 14)
            Logo().padding(.horizontal, 6)

            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { s in
                    SidebarNavItem(key: s.key, label: s.label, count: count(for: s),
                                   selected: model.section == s && (model.detail == nil || s == .commits)) {
                        model.section = s
                    }
                }
            }

            if model.detail != nil, let ctx = model.sameTicket {
                SameTicketSection(context: ctx, currentId: model.detail?.current)
            } else {
                repositories
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 16)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg)
        .alert("Rename repo", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if var r = renaming, let n = newName.nonEmpty { r.name = n; model.updateRepo(r) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func count(for s: AppSection) -> String? {
        switch s {
        case .commits: Fmt.thousands(model.navCommitCount)
        case .tickets: model.navTicketCount > 0 ? Fmt.thousands(model.navTicketCount) : nil
        case .tasks: model.navOpenTasks > 0 ? String(model.navOpenTasks) : nil
        default: nil
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("repositories").padding(.horizontal, 10).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.repos) { repo in
                        RepoRow(repo: repo, commitCount: model.repoCounts[repo.id ?? -1] ?? 0,
                                selected: model.section == .commits && model.commitsRepoFilter == repo.id) {
                            model.showCommits(repo: repo.id)
                        }
                        .contextMenu { repoMenu(repo) }
                        .help(repo.lastError ?? repo.path)
                    }
                }
            }
            .scrollIndicators(.never)
            if model.repos.isEmpty {
                Text("No repos yet").font(Theme.monoSmall).foregroundStyle(Theme.textMuted).padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder
    private func repoMenu(_ repo: Repo) -> some View {
        Button("Show commits") { model.showCommits(repo: repo.id) }
        Button("Rename…") { newName = repo.name; renaming = repo }
        Menu("Color") {
            ForEach(Repo.palette, id: \.self) { hex in
                Button(hex == repo.color ? "● \(colorName(hex))" : colorName(hex)) {
                    var r = repo; r.color = hex; model.updateRepo(r)
                }
            }
        }
        Button(repo.isActive ? "Pause tracking" : "Resume tracking") {
            var r = repo; r.isActive.toggle(); model.updateRepo(r)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)]) }
        Divider()
        Button("Remove repo", role: .destructive) { model.removeRepo(repo) }
    }

    private func colorName(_ hex: String) -> String {
        ["#5EE89B": "green", "#F2C46D": "amber", "#B9A4FF": "purple", "#6BA6FF": "blue", "#F28B82": "red", "#7DCFE0": "cyan"][hex] ?? hex
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 6) {
                    StatusDot(color: model.syncingNames.isEmpty ? Theme.textMuted : Theme.accent, size: 6)
                    Text(model.syncStatus)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help("Refresh (⌘R)")
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .help("Settings (⌘,)")
                }
                .padding(.horizontal, 6)
            }
            Button { model.pickRepos() } label: {
                Text("+ add repo")
                    .font(Theme.monoMedium)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(AddRepoStyle())
        }
    }
}

private struct AddRepoStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(base: Theme.surface, radius: 10) { configuration.label }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct SameTicketSection: View {
    @Environment(AppModel.self) private var model
    let context: SameTicketContext
    let currentId: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("same ticket · \(context.key)").padding(.bottom, 4)
            ForEach(context.items.prefix(6), id: \.self) { item in
                Button {
                    if let nav = model.detail, nav.ids.contains(item.id) {
                        model.openCommit(item.id, context: nav.ids)
                    } else {
                        model.openCommit(item.id, context: context.items.map(\.id))
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(item.sha).font(Theme.monoSmall).foregroundStyle(Theme.sha)
                        Text(item.subject)
                            .font(.plexSans(12))
                            .foregroundStyle(item.id == currentId ? Theme.textPrimary : Theme.textBody)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
