import Foundation

public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable { case context, addition, deletion, noNewline }
    public let kind: Kind
    public let text: String
    public let oldNo: Int?
    public let newNo: Int?

    public init(kind: Kind, text: String, oldNo: Int?, newNo: Int?) {
        self.kind = kind
        self.text = text
        self.oldNo = oldNo
        self.newNo = newNo
    }
}

public struct Hunk: Sendable, Equatable, Hashable {
    public let header: String
    public let oldStart: Int
    public let newStart: Int
    public var lines: [DiffLine]
}

public struct FileDiff: Sendable, Equatable, Hashable, Identifiable {
    public enum Status: String, Sendable, Equatable, Hashable { case added, deleted, modified, renamed, binary }
    public var oldPath: String?
    public var newPath: String
    public var status: Status
    public var hunks: [Hunk]

    public var id: String { newPath }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count + 1 } }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
    /// First changed new-side line, for "open in editor".
    public var firstChangedLine: Int {
        for hunk in hunks {
            if let line = hunk.lines.first(where: { $0.kind == .addition }) ?? hunk.lines.first(where: { $0.kind == .deletion }) {
                return line.newNo ?? line.oldNo ?? hunk.newStart
            }
        }
        return hunks.first?.newStart ?? 1
    }
}

/// Turns `git show --patch` / `git diff` output into structured file diffs.
public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldNo = 0, newNo = 0
        var oldLeft = 0, newLeft = 0

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                flushFile()
                let (a, b) = pathsFromDiffGit(line)
                current = FileDiff(oldPath: a, newPath: b ?? a ?? "", status: .modified, hunks: [])
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(line) {
                    oldNo = parsed.oldStart
                    newNo = parsed.newStart
                    oldLeft = parsed.oldCount
                    newLeft = parsed.newCount
                    hunk = Hunk(header: line, oldStart: parsed.oldStart, newStart: parsed.newStart, lines: [])
                }
                continue
            }

            if hunk != nil, oldLeft > 0 || newLeft > 0 || line.hasPrefix("\\") {
                if line.hasPrefix("+") {
                    hunk!.lines.append(DiffLine(kind: .addition, text: String(line.dropFirst()), oldNo: nil, newNo: newNo))
                    newNo += 1
                    newLeft -= 1
                } else if line.hasPrefix("-") {
                    hunk!.lines.append(DiffLine(kind: .deletion, text: String(line.dropFirst()), oldNo: oldNo, newNo: nil))
                    oldNo += 1
                    oldLeft -= 1
                } else if line.hasPrefix("\\") {
                    hunk!.lines.append(DiffLine(kind: .noNewline, text: String(line.dropFirst(2)), oldNo: nil, newNo: nil))
                } else if line.hasPrefix(" ") || (line.isEmpty && oldLeft > 0 && newLeft > 0) {
                    hunk!.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNo: oldNo, newNo: newNo))
                    oldNo += 1
                    newNo += 1
                    oldLeft -= 1
                    newLeft -= 1
                }
                continue
            }

            // File header lines
            if line.hasPrefix("new file mode") {
                current!.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current!.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current!.oldPath = String(line.dropFirst("rename from ".count))
                current!.status = .renamed
            } else if line.hasPrefix("rename to ") {
                current!.newPath = String(line.dropFirst("rename to ".count))
                current!.status = .renamed
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current!.status = .binary
            } else if line.hasPrefix("--- ") {
                let p = stripPrefix(String(line.dropFirst(4)))
                if p != "/dev/null" { current!.oldPath = p }
            } else if line.hasPrefix("+++ ") {
                let p = stripPrefix(String(line.dropFirst(4)))
                if p != "/dev/null" { current!.newPath = p }
            }
        }
        flushFile()
        // A deleted file's display path is its old path.
        return files.map { f in
            var f = f
            if f.status == .deleted, let old = f.oldPath, f.newPath.isEmpty { f.newPath = old }
            return f
        }
    }

    static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // @@ -42,14 +42,19 @@ context  (a missing count means 1)
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",")
            guard let start = nums.first.flatMap({ Int($0) }) else { return nil }
            let count = nums.count > 1 ? Int(nums[1]) ?? 1 : 1
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    static func pathsFromDiffGit(_ line: String) -> (String?, String?) {
        let rest = String(line.dropFirst("diff --git ".count))
        if let range = rest.range(of: " b/", options: .backwards) {
            let a = stripPrefix(String(rest[..<range.lowerBound]))
            let b = String(rest[range.upperBound...])
            return (a, b)
        }
        return (nil, nil)
    }

    static func stripPrefix(_ raw: String) -> String {
        var p = raw
        if p.hasPrefix("\""), p.hasSuffix("\""), p.count >= 2 { p = String(p.dropFirst().dropLast()) }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
        // git appends a tab after paths containing spaces
        if let tab = p.firstIndex(of: "\t") { p = String(p[..<tab]) }
        return p
    }
}

/// One row of the split (side-by-side) view.
public struct SplitRow: Sendable, Hashable {
    public var left: DiffLine?
    public var right: DiffLine?
}

public enum SplitDiff {
    /// Context on both sides; a run of deletions is paired with the following run of additions.
    public static func rows(for hunk: Hunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var dels: [DiffLine] = []
        var adds: [DiffLine] = []

        func flush() {
            for i in 0..<max(dels.count, adds.count) {
                rows.append(SplitRow(left: i < dels.count ? dels[i] : nil, right: i < adds.count ? adds[i] : nil))
            }
            dels.removeAll()
            adds.removeAll()
        }

        for line in hunk.lines {
            switch line.kind {
            case .deletion:
                if !adds.isEmpty { flush() }
                dels.append(line)
            case .addition:
                adds.append(line)
            case .context:
                flush()
                rows.append(SplitRow(left: line, right: line))
            case .noNewline:
                break
            }
        }
        flush()
        return rows
    }
}
