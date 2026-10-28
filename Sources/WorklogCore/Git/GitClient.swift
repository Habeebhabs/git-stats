import Foundation

/// Typed git operations on top of `GitRunner`.
public struct GitClient: Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    // MARK: Environment

    public func version() async -> String? {
        guard let r = try? await runner.run(["--version"]), r.succeeded else { return nil }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func configEmail(repo: String? = nil) async -> String? {
        let args = repo == nil ? ["config", "--global", "--get", "user.email"] : ["config", "--get", "user.email"]
        guard let r = try? await runner.run(args, repo: repo), r.succeeded else { return nil }
        let email = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    public func configName(repo: String? = nil) async -> String? {
        let args = repo == nil ? ["config", "--global", "--get", "user.name"] : ["config", "--get", "user.name"]
        guard let r = try? await runner.run(args, repo: repo), r.succeeded else { return nil }
        let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Author emails of recent commits on all refs, most frequent first (identity suggestions).
    public func recentAuthorEmails(_ repo: String, limit: Int = 500) async -> [(email: String, count: Int)] {
        guard let r = try? await runner.run(["log", "--all", "-\(limit)", "--format=%ae"], repo: repo), r.succeeded else { return [] }
        var counts: [String: Int] = [:]
        for line in r.output.split(separator: "\n") { counts[line.lowercased(), default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    // MARK: Repo info

    public func topLevel(_ path: String) async -> String? {
        guard let r = try? await runner.run(["rev-parse", "--show-toplevel"], repo: path), r.succeeded else { return nil }
        let top = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    /// The shared git dir (handles worktrees), absolute.
    public func commonGitDir(_ repo: String) async -> String? {
        guard let r = try? await runner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], repo: repo), r.succeeded else { return nil }
        let dir = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    public func isShallow(_ repo: String) async -> Bool {
        guard let r = try? await runner.run(["rev-parse", "--is-shallow-repository"], repo: repo) else { return false }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func defaultBranch(_ repo: String, refs: [GitRef]) async -> String? {
        if let r = try? await runner.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo: repo), r.succeeded {
            let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/") { return String(name.dropFirst("origin/".count)) }
        }
        let locals = Set(refs.filter { $0.name.hasPrefix("refs/heads/") }.map(\.shortName))
        for candidate in ["main", "master", "develop", "trunk"] where locals.contains(candidate) { return candidate }
        if let r = try? await runner.run(["symbolic-ref", "--short", "HEAD"], repo: repo), r.succeeded {
            let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return locals.sorted().first
    }

    /// Local branches and remote-tracking branches (excluding `*/HEAD`).
    public func refs(_ repo: String) async throws -> [GitRef] {
        let r = try await runner.run(["for-each-ref", "--format=%(refname)%09%(objectname)", "refs/heads", "refs/remotes"], repo: repo)
        guard r.succeeded else { throw GitError(r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t")
            guard cols.count == 2 else { return nil }
            let name = String(cols[0])
            if name.hasPrefix("refs/remotes/") && name.hasSuffix("/HEAD") { return nil }
            return GitRef(name: name, sha: String(cols[1]))
        }
    }

    public func isAncestor(_ ancestor: String, of descendant: String, repo: String) async -> Bool {
        guard let r = try? await runner.run(["merge-base", "--is-ancestor", ancestor, descendant], repo: repo) else { return false }
        return r.status == 0
    }

    /// Of the given SHAs, the ones that still exist as commits.
    public func existingCommits(_ shas: [String], repo: String) async -> Set<String> {
        guard !shas.isEmpty else { return [] }
        let input = Data(shas.map { "\($0)^{commit}" }.joined(separator: "\n").appending("\n").utf8)
        guard let r = try? await runner.run(["cat-file", "--batch-check=%(objectname) %(objecttype)"], repo: repo, stdin: input) else { return [] }
        var found = Set<String>()
        for line in r.output.split(separator: "\n") {
            let cols = line.split(separator: " ")
            if cols.count == 2, cols[1] == "commit" { found.insert(String(cols[0])) }
        }
        return found
    }

    // MARK: Log

    /// Commits reachable from `include` but not from `exclude`, filtered by author.
    public func log(repo: String, include: [String], exclude: [String], since: Date?, authors: [String]) async throws -> [LoggedCommit] {
        guard !include.isEmpty, !authors.isEmpty else { return [] }
        var args = ["log", "--stdin", "--source", "--numstat", "-M", "--format=\(LogParser.format)", "--regexp-ignore-case"]
        args += authors.map { "--author=\(Self.escapeRegex($0))" }
        if let since { args.append("--since=\(since.ISO8601Format())") }
        let revs = include + exclude.map { "^\($0)" }
        let input = Data((revs.joined(separator: "\n") + "\n").utf8)
        let r = try await runner.run(args, repo: repo, stdin: input)
        guard r.succeeded else { throw GitError(r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let wanted = Set(authors.map { $0.lowercased() })
        return LogParser.parse(r.stdout).filter { wanted.contains($0.authorEmail.lowercased()) }
    }

    /// SHAs of my commits reachable from `refs` since a date (used after a rewrite).
    public func reachableShas(repo: String, refs: [String], since: Date?, authors: [String]) async throws -> Set<String> {
        guard !refs.isEmpty, !authors.isEmpty else { return [] }
        var args = ["log", "--stdin", "--format=%H%x1f%ae", "--regexp-ignore-case"]
        args += authors.map { "--author=\(Self.escapeRegex($0))" }
        if let since { args.append("--since=\(since.ISO8601Format())") }
        let r = try await runner.run(args, repo: repo, stdin: Data((refs.joined(separator: "\n") + "\n").utf8))
        guard r.succeeded else { throw GitError(r.errorOutput) }
        let wanted = Set(authors.map { $0.lowercased() })
        var shas = Set<String>()
        for line in r.output.split(separator: "\n") {
            let cols = line.split(separator: "\u{1f}")
            if cols.count == 2, wanted.contains(cols[1].lowercased()) { shas.insert(String(cols[0])) }
        }
        return shas
    }

    // MARK: Diff

    /// Full patch for a commit; merges are diffed against their first parent.
    public func patch(repo: String, sha: String, isMerge: Bool) async throws -> String {
        let args: [String] = isMerge
            ? ["diff", "--find-renames", "-U3", "--no-color", "--no-ext-diff", "\(sha)^1", sha]
            : ["show", "--format=", "--patch", "--find-renames", "-U3", "--no-color", "--no-ext-diff", sha]
        let r = try await runner.run(args, repo: repo)
        guard r.succeeded else { throw GitError(r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.output
    }

    public func fetch(repo: String) async throws {
        let r = try await runner.run(["fetch", "--all", "--prune", "--quiet"], repo: repo)
        guard r.succeeded else { throw GitError(r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func escapeRegex(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\.^$*[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// Finds git working trees under a folder.
public enum RepoDiscovery {
    public static func findRepos(under root: URL, maxDepth: Int = 3) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        func visit(_ url: URL, depth: Int) {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                found.append(url)
                return
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ["node_modules", "Pods", "build", "DerivedData", ".build"].contains(child.lastPathComponent) { continue }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found.sorted { $0.path < $1.path }
    }
}
