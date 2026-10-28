import Foundation

public struct ExtractedTicket: Equatable, Sendable {
    public let key: String
    public let source: String   // subject | body | branch
}

/// Finds ticket keys like `PAY-218` in commit subjects, bodies and branch names.
public final class TicketExtractor: @unchecked Sendable {
    private let regex: NSRegularExpression?
    private let allowlist: Set<String>
    private let denylist: Set<String>
    private let githubIssues: Bool
    private static let issueRegex = try! NSRegularExpression(pattern: #"(?<![\w&/])#(\d{1,6})\b"#)

    public init(pattern: String = AppSettings.defaultTicketPattern, allowlist: [String] = [], denylist: [String] = AppSettings.defaultDenylist, githubIssues: Bool = false) {
        self.regex = try? NSRegularExpression(pattern: pattern)
        self.allowlist = Set(allowlist.map { $0.uppercased() })
        self.denylist = Set(denylist.map { $0.uppercased() })
        self.githubIssues = githubIssues
    }

    public func extract(subject: String, body: String?, branch: String?, repoName: String) -> [ExtractedTicket] {
        var seen = Set<String>()
        var result: [ExtractedTicket] = []
        let sources: [(String, String?)] = [("subject", subject), ("body", body), ("branch", branch)]
        for (source, text) in sources {
            guard let text, !text.isEmpty else { continue }
            for key in keys(in: text) where seen.insert(key).inserted {
                result.append(ExtractedTicket(key: key, source: source))
            }
            if githubIssues, source != "branch" {
                for number in issueNumbers(in: text) {
                    let key = "\(repoName)#\(number)"
                    if seen.insert(key).inserted { result.append(ExtractedTicket(key: key, source: source)) }
                }
            }
        }
        return result
    }

    public func keys(in text: String) -> [String] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let r = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard let swiftRange = Range(r, in: text) else { return nil }
            let key = String(text[swiftRange])
            return isAllowed(key) ? key : nil
        }
    }

    public func isAllowed(_ key: String) -> Bool {
        let prefix = key.split(separator: "-").first.map { String($0).uppercased() } ?? key
        if !allowlist.isEmpty { return allowlist.contains(prefix) }
        return !denylist.contains(prefix)
    }

    private func issueNumbers(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return Self.issueRegex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
