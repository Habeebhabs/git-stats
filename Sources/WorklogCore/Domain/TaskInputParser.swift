import Foundation

public struct ParsedTaskInput: Equatable, Sendable {
    public var title: String
    public var ticketKey: String?
    public var tags: [String]
    public var dueDate: Date?
}

/// `Review release notes PAY-221 #review due:fri` → title, ticket, tags, due date.
public enum TaskInputParser {
    private static let ticketRegex = try! NSRegularExpression(pattern: #"^[A-Z][A-Z0-9]{1,9}-\d{1,6}$"#)

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .worklog) -> ParsedTaskInput {
        var words: [String] = []
        var tags: [String] = []
        var due: Date?
        for token in input.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("#"), token.count > 1, !token.dropFirst().allSatisfy(\.isNumber) {
                tags.append(String(token.dropFirst()).lowercased())
            } else if token.lowercased().hasPrefix("due:"), let d = parseDue(String(token.dropFirst(4)), now: now, calendar: calendar) {
                due = d
            } else {
                words.append(token)
            }
        }
        var ticket: String?
        if let i = words.lastIndex(where: isTicketKey) {
            ticket = words.remove(at: i)
        }
        var title = words.joined(separator: " ")
        // "Fix flaky test — PAY-204" / "Fix flaky test: PAY-204"
        while let last = title.last, "—–-:·,".contains(last) || last == " " { title.removeLast() }
        if title.isEmpty { title = ticket ?? input.trimmingCharacters(in: .whitespaces) }
        return ParsedTaskInput(title: title, ticketKey: ticket, tags: tags, dueDate: due)
    }

    public static func isTicketKey(_ s: String) -> Bool {
        ticketRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `today`, `tomorrow`, weekday names (next occurrence, today counts), `2026-11-04`.
    public static func parseDue(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let s = raw.lowercased()
        let today = calendar.startOfDay(for: now)
        if s == "today" { return today }
        if s == "tomorrow" || s == "tmr" { return calendar.date(byAdding: .day, value: 1, to: today) }
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if let idx = names.firstIndex(where: { s.hasPrefix($0) }), s.count >= 3 {
            let target = idx + 1  // Calendar weekday: 1 = Sunday
            let current = calendar.component(.weekday, from: today)
            let ahead = (target - current + 7) % 7
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3 {
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        return nil
    }
}
