import Foundation

/// Overview range switcher: current period to date.
public enum RangePreset: String, CaseIterable, Sendable, Codable {
    case week = "wk", month = "mo", quarter = "qtr", year = "yr"

    public var word: String {
        switch self {
        case .week: "week"
        case .month: "month"
        case .quarter: "quarter"
        case .year: "year"
        }
    }

    public func interval(now: Date = Date(), calendar: Calendar = .worklog) -> DateInterval {
        let start: Date
        switch self {
        case .week: start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        case .month: start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        case .quarter: start = Calendar.quarterStart(for: now, calendar: calendar)
        case .year: start = calendar.dateInterval(of: .year, for: now)?.start ?? now
        }
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return DateInterval(start: start, end: max(end, start))
    }
}

/// Report builder ranges: whole periods.
public enum ReportPreset: String, CaseIterable, Sendable, Identifiable {
    case thisQuarter, lastQuarter, firstHalf, secondHalf, thisYear, lastYear, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisQuarter: "this quarter"
        case .lastQuarter: "last quarter"
        case .firstHalf: "H1"
        case .secondHalf: "H2"
        case .thisYear: "this year"
        case .lastYear: "last year"
        case .custom: "custom"
        }
    }

    public func interval(now: Date = Date(), calendar: Calendar = .worklog) -> DateInterval? {
        let year = calendar.component(.year, from: now)
        func date(_ y: Int, _ m: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: 1))! }
        switch self {
        case .thisQuarter:
            let s = Calendar.quarterStart(for: now, calendar: calendar)
            return DateInterval(start: s, end: calendar.date(byAdding: .month, value: 3, to: s)!)
        case .lastQuarter:
            let s = calendar.date(byAdding: .month, value: -3, to: Calendar.quarterStart(for: now, calendar: calendar))!
            return DateInterval(start: s, end: calendar.date(byAdding: .month, value: 3, to: s)!)
        case .firstHalf: return DateInterval(start: date(year, 1), end: date(year, 7))
        case .secondHalf: return DateInterval(start: date(year, 7), end: date(year + 1, 1))
        case .thisYear: return DateInterval(start: date(year, 1), end: date(year + 1, 1))
        case .lastYear: return DateInterval(start: date(year - 1, 1), end: date(year, 1))
        case .custom: return nil
        }
    }
}

public extension Calendar {
    /// Gregorian, ISO weeks (Monday first), local time zone.
    static var worklog: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        c.locale = .current
        return c
    }

    static func quarterStart(for date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let month = ((comps.month! - 1) / 3) * 3 + 1
        return calendar.date(from: DateComponents(year: comps.year, month: month, day: 1))!
    }
}

public extension DateInterval {
    /// The equal-length period immediately before this one.
    var previous: DateInterval { DateInterval(start: start.addingTimeInterval(-duration), duration: duration) }

    /// `Jul 1 – Sep 30, 2026` (end is exclusive, so the last shown day is end − 1s).
    var label: String {
        let last = end.addingTimeInterval(-1)
        let sameYear = Calendar.worklog.component(.year, from: start) == Calendar.worklog.component(.year, from: last)
        let a = (sameYear ? start.formatted(.dateTime.month(.abbreviated).day()) : start.formatted(.dateTime.month(.abbreviated).day().year()))
        let b = last.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(a) – \(b)"
    }

    /// Stable key for period notes, e.g. `2026-07-01..2026-09-30`.
    var noteKey: String {
        let f = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        return "\(start.formatted(f))..\(end.addingTimeInterval(-1).formatted(f))"
    }
}
