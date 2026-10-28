import Foundation
import GRDB

public enum EditorPreset: String, CaseIterable, Codable, Sendable {
    case vscode, xcode, androidStudio, custom

    public var label: String {
        switch self {
        case .vscode: "VS Code"
        case .xcode: "Xcode"
        case .androidStudio: "Android Studio"
        case .custom: "Custom"
        }
    }

    /// `{file}` and `{line}` are substituted (shell-quoted).
    public var template: String {
        switch self {
        case .vscode: "code -g {file}:{line}"
        case .xcode: "xed -l {line} {file}"
        case .androidStudio: "studio --line {line} {file}"
        case .custom: ""
        }
    }
}

public struct AppSettings: Equatable, Sendable {
    public static let defaultTicketPattern = #"\b([A-Z][A-Z0-9]{1,9}-\d{1,6})\b"#
    public static let defaultDenylist = ["UTF", "ISO", "SHA", "RFC", "HTTP", "TLS", "CVE", "MD", "AES", "RSA", "X"]
    public static let defaultExcludedGlobs = [
        "*.lock", "package-lock.json", "Podfile.lock", "gradle.lockfile", "pnpm-lock.yaml", "Package.resolved",
        "node_modules/**", "vendor/**", "Pods/**", "dist/**", "*.min.js", "*.generated.*",
    ]

    public var scanWindowMonths = 12          // 0 = all history
    public var ticketPattern = AppSettings.defaultTicketPattern
    public var ticketAllowlist: [String] = []
    public var githubIssueRefs = false
    public var excludedGlobs = AppSettings.defaultExcludedGlobs
    public var includeMergesInStats = false
    public var countWeekends = false
    public var editor = EditorPreset.vscode
    public var customEditorCommand = ""
    public var onboarded = false

    public init() {}

    public var editorTemplate: String { editor == .custom ? customEditorCommand : editor.template }

    public func scanStart(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        scanWindowMonths <= 0 ? nil : calendar.date(byAdding: .month, value: -scanWindowMonths, to: now)
    }

    public func ticketExtractor() -> TicketExtractor {
        TicketExtractor(pattern: ticketPattern, allowlist: ticketAllowlist, denylist: Self.defaultDenylist, githubIssues: githubIssueRefs)
    }

    public func pathExclusion() -> PathExclusion { PathExclusion(globs: excludedGlobs) }

    // MARK: Persistence (key/value table)

    public static func load(_ db: Database) throws -> AppSettings {
        var s = AppSettings()
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM setting")
        var map: [String: String] = [:]
        for row in rows { map[row["key"]] = row["value"] }
        if let v = map["scanWindowMonths"].flatMap(Int.init) { s.scanWindowMonths = v }
        if let v = map["ticketPattern"], !v.isEmpty { s.ticketPattern = v }
        if let v = map["ticketAllowlist"] { s.ticketAllowlist = splitList(v) }
        if let v = map["githubIssueRefs"] { s.githubIssueRefs = v == "1" }
        if let v = map["excludedGlobs"] { s.excludedGlobs = splitList(v, separator: "\n") }
        if let v = map["includeMergesInStats"] { s.includeMergesInStats = v == "1" }
        if let v = map["countWeekends"] { s.countWeekends = v == "1" }
        if let v = map["editor"].flatMap(EditorPreset.init(rawValue:)) { s.editor = v }
        if let v = map["customEditorCommand"] { s.customEditorCommand = v }
        if let v = map["onboarded"] { s.onboarded = v == "1" }
        return s
    }

    public func save(_ db: Database) throws {
        let values: [String: String] = [
            "scanWindowMonths": String(scanWindowMonths),
            "ticketPattern": ticketPattern,
            "ticketAllowlist": ticketAllowlist.joined(separator: ","),
            "githubIssueRefs": githubIssueRefs ? "1" : "0",
            "excludedGlobs": excludedGlobs.joined(separator: "\n"),
            "includeMergesInStats": includeMergesInStats ? "1" : "0",
            "countWeekends": countWeekends ? "1" : "0",
            "editor": editor.rawValue,
            "customEditorCommand": customEditorCommand,
            "onboarded": onboarded ? "1" : "0",
        ]
        for (key, value) in values {
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    static func splitList(_ s: String, separator: Character = ",") -> [String] {
        s.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Glob-based path exclusion for line stats. `*` matches within a path segment, `**` across segments.
/// Patterns without a `/` match the file name anywhere.
public struct PathExclusion {
    private let matchers: [(basenameOnly: Bool, regex: NSRegularExpression)]

    public init(globs: [String]) {
        matchers = globs.compactMap { glob in
            let trimmed = glob.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let regex = try? NSRegularExpression(pattern: Self.regex(for: trimmed)) else { return nil }
            return (!trimmed.contains("/"), regex)
        }
    }

    public func isExcluded(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return matchers.contains { m in
            let subject = m.basenameOnly ? name : path
            return m.regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }
    }

    static func regex(for glob: String) -> String {
        var out = "^"
        var chars = Array(glob)
        if chars.first == "/" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    // `**/` → any number of directories; trailing `**` → anything
                    if i + 2 < chars.count, chars[i + 2] == "/" { out += "(?:.*/)?"; i += 3; continue }
                    out += ".*"; i += 2; continue
                }
                out += "[^/]*"
            } else if c == "?" {
                out += "[^/]"
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out + "$"
    }
}

// NSRegularExpression is immutable and thread-safe once built.
extension PathExclusion: @unchecked Sendable {}
