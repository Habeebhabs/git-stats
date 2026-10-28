import Foundation

/// Parses `git log --format=LogParser.format --numstat` output.
public enum LogParser {
    /// Records start with \x1e; fields are separated by \x1f; numstat lines follow the last separator.
    public static let format = "%x1e%H%x1f%h%x1f%ae%x1f%an%x1f%aI%x1f%cI%x1f%P%x1f%S%x1f%s%x1f%b%x1f"
    private static let fieldCount = 10

    public static func parse(_ data: Data) -> [LoggedCommit] {
        var commits: [LoggedCommit] = []
        for chunk in data.split(separator: 0x1e, omittingEmptySubsequences: true) {
            let text = String(decoding: chunk, as: UTF8.self)
            if let commit = parseRecord(text) { commits.append(commit) }
        }
        return commits
    }

    static func parseRecord(_ text: String) -> LoggedCommit? {
        let parts = text.split(separator: "\u{1f}", maxSplits: fieldCount, omittingEmptySubsequences: false)
        guard parts.count >= fieldCount else { return nil }
        let sha = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.count >= 7,
              let authorDate = parseDate(String(parts[4])),
              let commitDate = parseDate(String(parts[5])) else { return nil }
        let source = String(parts[7])
        let tail = parts.count > fieldCount ? String(parts[fieldCount]) : ""
        return LoggedCommit(
            sha: sha,
            shortSha: String(parts[1]),
            authorEmail: String(parts[2]),
            authorName: String(parts[3]),
            authorDate: authorDate,
            commitDate: commitDate,
            parents: parts[6].split(separator: " ").map(String.init),
            source: source.isEmpty ? nil : source,
            subject: String(parts[8]),
            body: parts[9].trimmingCharacters(in: .whitespacesAndNewlines),
            files: parseNumstat(tail)
        )
    }

    public static func parseNumstat(_ text: String) -> [NumstatEntry] {
        var entries: [NumstatEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            let (path, oldPath) = resolveRename(String(cols[2]))
            entries.append(NumstatEntry(path: path, oldPath: oldPath, additions: Int(cols[0]), deletions: Int(cols[1])))
        }
        return entries
    }

    /// `src/{a => b}/c.kt` → (`src/b/c.kt`, `src/a/c.kt`); `old => new` → (`new`, `old`).
    public static func resolveRename(_ raw: String) -> (path: String, oldPath: String?) {
        guard raw.contains(" => ") else { return (raw, nil) }
        if let open = raw.firstIndex(of: "{"), let close = raw[open...].firstIndex(of: "}") {
            let prefix = String(raw[..<open])
            let suffix = String(raw[raw.index(after: close)...])
            let inner = raw[raw.index(after: open)..<close]
            let sides = inner.components(separatedBy: " => ")
            if sides.count == 2 {
                let old = clean(prefix + sides[0] + suffix)
                let new = clean(prefix + sides[1] + suffix)
                return (new, old)
            }
        }
        let sides = raw.components(separatedBy: " => ")
        return (sides.last ?? raw, sides.first)
    }

    private static func clean(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(trimmed) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }
}
