import ServiceManagement
import SwiftUI
import WorklogCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var allowlist = ""
    @State private var globs = ""
    @State private var newEmail = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var suggestions: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Logo()
                group("repositories") {
                    ForEach(model.repos) { repo in RepoSettingsRow(repo: repo) }
                    if model.repos.isEmpty { muted("No repos yet.") }
                    HStack {
                        Button("+ add repo") { model.pickRepos() }.buttonStyle(SecondaryMonoButtonStyle())
                        Button("scan a folder for repos…") { scanFolder() }.buttonStyle(SecondaryMonoButtonStyle())
                    }
                    labeled("initial scan window") {
                        Picker("", selection: $draft.scanWindowMonths) {
                            Text("3 months").tag(3); Text("6 months").tag(6); Text("12 months").tag(12)
                            Text("24 months").tag(24); Text("all history").tag(0)
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }

                group("identities") {
                    muted("Commits by these emails count as yours.")
                    ForEach(model.identities) { identity in
                        HStack {
                            Text(identity.email).font(Theme.monoMeta).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button("remove") { model.removeIdentity(identity) }.buttonStyle(LinkButtonStyle())
                        }
                        .frame(minHeight: 28)
                        .rowDivider()
                    }
                    EmailSuggestions(emails: suggestions) { model.addIdentity($0) }
                    HStack {
                        field("you@company.com", text: $newEmail).onSubmit(addEmail)
                        Button("add") { addEmail() }.buttonStyle(SecondaryMonoButtonStyle())
                    }
                }

                group("tickets") {
                    labeled("pattern") { field(AppSettings.defaultTicketPattern, text: $draft.ticketPattern) }
                    labeled("prefix allowlist") { field("PAY, MOB, ADM (empty = any, minus UTF/ISO/SHA…)", text: $allowlist) }
                    Toggle("Also treat GitHub-style #123 as <repo>#123", isOn: $draft.githubIssueRefs).toggleStyle(.checkbox)
                }

                group("stats") {
                    Toggle("Count weekends in active days and streaks", isOn: $draft.countWeekends).toggleStyle(.checkbox)
                    Toggle("Include merge commits in stats", isOn: $draft.includeMergesInStats).toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 6) {
                        muted("Excluded from line counts (one glob per line):")
                        TextEditor(text: $globs)
                            .font(Theme.monoMeta)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 110)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 1))
                    }
                }

                group("editor") {
                    labeled("open in") {
                        Picker("", selection: $draft.editor) {
                            ForEach(EditorPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    if draft.editor == .custom {
                        labeled("command") { field("subl {file}:{line}", text: $draft.customEditorCommand) }
                    } else {
                        muted(draft.editor.template)
                    }
                }

                group("app") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                    if let loginError { Text(loginError).font(Theme.monoSmall).foregroundStyle(Theme.deletion) }
                    muted("Data: ~/Library/Application Support/Worklog/worklog.sqlite · git: \(model.gitVersion ?? "not found")")
                }

                HStack {
                    Spacer()
                    Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 680)
        .background(Theme.bg)
        .onAppear(perform: loadDraft)
        .task(id: model.identities.count) { suggestions = await model.suggestedEmails() }
    }

    private func loadDraft() {
        draft = model.settings
        allowlist = draft.ticketAllowlist.joined(separator: ", ")
        globs = draft.excludedGlobs.joined(separator: "\n")
    }

    private func save() {
        var s = draft
        s.ticketAllowlist = allowlist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        s.excludedGlobs = globs.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if s.ticketPattern.nonEmpty == nil || (try? NSRegularExpression(pattern: s.ticketPattern)) == nil {
            s.ticketPattern = AppSettings.defaultTicketPattern
        }
        model.saveSettings(s)
        model.flash("settings saved")
    }

    private func addEmail() {
        guard let e = newEmail.nonEmpty else { return }
        model.addIdentity(e)
        newEmail = ""
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let found = RepoDiscovery.findRepos(under: url)
        Task { await model.addRepos(found) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Launch at login needs the bundled app (scripts/build-app.sh): \(error.localizedDescription)"
        }
    }

    // MARK: Building blocks

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        }
        .font(Theme.body)
        .foregroundStyle(Theme.textPrimary)
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.monoMeta).foregroundStyle(Theme.textMuted).frame(width: 140, alignment: .leading)
            content()
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
            .textFieldStyle(.plain)
            .font(Theme.monoMeta)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 1))
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
    }
}

private struct RepoSettingsRow: View {
    @Environment(AppModel.self) private var model
    let repo: Repo
    @State private var name = ""
    @State private var branch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Repo.palette, id: \.self) { hex in
                        Button(hex) { var r = repo; r.color = hex; model.updateRepo(r) }
                    }
                } label: {
                    Circle().fill(Color(hexString: repo.color)).frame(width: 12, height: 12)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.bodyMedium)
                    .onSubmit { if let n = name.nonEmpty { var r = repo; r.name = n; model.updateRepo(r) } }
                TextField("", text: $branch, prompt: Text("default branch").foregroundStyle(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(Theme.monoMeta)
                    .frame(width: 110)
                    .onSubmit { var r = repo; r.defaultBranch = branch.nonEmpty; model.updateRepo(r) }
                Toggle("active", isOn: Binding(get: { repo.isActive }, set: { var r = repo; r.isActive = $0; model.updateRepo(r) }))
                    .toggleStyle(.checkbox)
                    .font(Theme.monoSmall)
                Button("remove") { model.removeRepo(repo) }.buttonStyle(LinkButtonStyle())
            }
            HStack(spacing: 8) {
                Text(repo.path).lineLimit(1).truncationMode(.middle)
                if repo.isShallow { Text("· shallow clone, history may be incomplete").foregroundStyle(Theme.sha) }
                if let err = repo.lastError { Text("· \(err)").foregroundStyle(Theme.deletion).lineLimit(1) }
            }
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 6)
        .rowDivider()
        .onAppear { name = repo.name; branch = repo.defaultBranch ?? "" }
    }
}
