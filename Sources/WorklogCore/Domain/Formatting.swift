import Foundation

/// Number and date formatting per the UI spec: thousands separators, compact tiles, U+2212 minus.
public enum Fmt {
    public static let minus = "\u{2212}"

    public static func thousands(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// 12400 → `12.4k`, 950 → `950`, 1_200_000 → `1.2M`
    public static func compact(_ n: Int) -> String {
        let v = abs(n)
        func trim(_ d: Double) -> String {
            let s = String(format: "%.1f", d)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        let body: String
        if v >= 1_000_000 { body = trim(Double(v) / 1_000_000) + "M" }
        else if v >= 10_000 { body = trim(Double(v) / 1_000) + "k" }
        else if v >= 1_000 { body = trim(Double(v) / 1_000) + "k" }
        else { body = String(v) }
        return n < 0 ? minus + body : body
    }

    public static func plus(_ n: Int, compact: Bool = false) -> String { "+" + (compact ? self.compact(n) : thousands(n)) }
    public static func minus(_ n: Int, compact: Bool = false) -> String { minus + (compact ? self.compact(n) : thousands(n)) }

    /// `▲ 18% vs prev`
    public static func delta(_ current: Int, _ previous: Int) -> (text: String, isUp: Bool) {
        guard previous > 0 else { return current > 0 ? ("▲ new vs prev", true) : ("— vs prev", false) }
        let pct = Int((Double(current - previous) / Double(previous) * 100).rounded())
        if pct == 0 { return ("— same as prev", false) }
        return pct > 0 ? ("▲ \(pct)% vs prev", true) : ("▼ \(abs(pct))% vs prev", false)
    }

    /// `▲ 6 vs prev`
    public static func countDelta(_ current: Int, _ previous: Int) -> (text: String, isUp: Bool) {
        let d = current - previous
        if d == 0 { return ("— same as prev", false) }
        return d > 0 ? ("▲ \(d) vs prev", true) : ("▼ \(abs(d)) vs prev", false)
    }

    /// `just now`, `5m ago`, `2h ago`, `1d ago`, then `Oct 21` after 7 days.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d ago" }
        let sameYear = Calendar.worklog.component(.year, from: date) == Calendar.worklog.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// `Oct 27, 2026 · 19:42`
    public static func detailDate(_ date: Date) -> String {
        let d = date.formatted(.dateTime.month(.abbreviated).day().year())
        let t = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return "\(d) · \(t)"
    }

    public static func greeting(now: Date = Date()) -> String {
        switch Calendar.worklog.component(.hour, from: now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}
