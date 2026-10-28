import SwiftUI
import WorklogCore

/// First launch: git check → identity → repos → scan.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var detected: [URL] = []
    @State private var chosen: Set<URL> = []
    @State private var scanning = false
    @State private var suggestions: [String] = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 20) {
                Logo()
                Text("Track your own commits across all your repos.")
                    .font(Theme.pageTitle).tracking(-0.24).foregroundStyle(Theme.textPrimary)

                step(1, "git") {
                    if let v = model.gitVersion {
                        Text("✓ \(v)").font(Theme.monoMeta).foregroundStyle(Theme.accent)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("git wasn't found. Install the Xcode Command Line Tools, then reopen Worklog.")
                                .font(Theme.body).foregroundStyle(Theme.textBody)
                            Button("Install Command Line Tools") { installCLT() }.buttonStyle(SecondaryMonoButtonStyle())
                        }
                    }
                }

                step(2, "you") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.identities) { i in
                            Text("✓ \(i.email)").font(Theme.monoMeta).foregroundStyle(Theme.accent)
                        }
                        EmailSuggestions(emails: suggestions) { model.addIdentity($0) }
                        HStack {
                            TextField("", text: $email, prompt: Text("another email you commit with").foregroundStyle(Theme.textMuted))
                                .textFieldStyle(.plain)
                                .font(Theme.monoMeta)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 1))
                                .onSubmit(addEmail)
                            Button("add") { addEmail() }.buttonStyle(SecondaryMonoButtonStyle())
                        }
                    }
                }

                step(3, "repos") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.repos) { r in
                            HStack(spacing: 8) {
                                StatusDot(color: Color(hexString: r.color))
                                Text(r.name).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                Text(r.path).font(Theme.monoSmall).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if !detected.isEmpty {
                            SectionLabel("found \(detected.count) repos").padding(.top, 4)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(detected, id: \.self) { url in
                                        CheckRow(label: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), isOn: chosen.contains(url)) {
                                            if chosen.contains(url) { chosen.remove(url) } else { chosen.insert(url) }
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 160)
                            Button("add \(chosen.count) selected") {
                                let urls = Array(chosen)
                                detected = []; chosen = []
                                Task { await model.addRepos(urls) }
                            }
                            .buttonStyle(SecondaryMonoButtonStyle())
                            .disabled(chosen.isEmpty)
                        }
                        HStack {
                            Button("+ add repo") { model.pickRepos() }.buttonStyle(SecondaryMonoButtonStyle())
                            Button(scanning ? "scanning…" : "scan a folder for repos") { scanFolder() }
                                .buttonStyle(SecondaryMonoButtonStyle())
                                .disabled(scanning)
                        }
                    }
                }

                HStack {
                    Text(model.syncStatus).font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("later") { model.showOnboarding = false }.buttonStyle(LinkButtonStyle())
                    Button("Start tracking") { model.finishOnboarding() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.repos.isEmpty || model.identities.isEmpty)
                }
            }
            .padding(28)
            .frame(width: 620)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 30)
        }
        .task { await detectIdentity() }
        .task(id: "\(model.repos.count)-\(model.identities.count)") { suggestions = await model.suggestedEmails() }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(Theme.monoMedium).foregroundStyle(Theme.accent).frame(width: 14)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title)
                content()
            }
        }
    }

    private func detectIdentity() async {
        guard model.identities.isEmpty, let global = await model.git.configEmail() else { return }
        let name = await model.git.configName()
        _ = try? await model.db.writer.write { db in try Mutations.addIdentity(email: global, name: name, db: db) }
    }

    private func addEmail() {
        guard let e = email.nonEmpty else { return }
        model.addIdentity(e)
        email = ""
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.message = "Worklog looks up to 3 levels deep for git repos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanning = true
        Task.detached {
            let found = RepoDiscovery.findRepos(under: url)
            await MainActor.run {
                let existing = Set(model.repos.map(\.path))
                detected = found.filter { !existing.contains($0.path) }
                chosen = Set(detected)
                scanning = false
            }
        }
    }

    private func installCLT() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }
}

/// "found in your repos: a@b · c@d" — click to add as an identity.
struct EmailSuggestions: View {
    let emails: [String]
    let add: (String) -> Void

    var body: some View {
        if !emails.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("found in your repos — click the ones that are you:").font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                WrapLayout(spacing: 6) {
                    ForEach(emails, id: \.self) { email in
                        Button("+ " + email) { add(email) }.buttonStyle(SecondaryMonoButtonStyle(height: 28))
                    }
                }
            }
        }
    }
}
