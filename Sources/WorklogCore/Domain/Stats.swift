import Foundation
import GRDB

/// The slice of a commit that stats need.
public struct CommitFact: Codable, FetchableRecord, Hashable, Sendable {
    public var id: Int64
    public var repoId: Int64
    public var authorDate: Date
    public var statAdditions: Int
    public var statDeletions: Int
    public var filesChanged: Int
    public var isMerge: Bool
    public var subject: String

    public init(id: Int64, repoId: Int64, authorDate: Date, statAdditions: Int, statDeletions: Int, filesChanged: Int, isMerge: Bool, subject: String) {
        self.id = id
        self.repoId = repoId
        self.authorDate = authorDate
        self.statAdditions = statAdditions
        self.statDeletions = statDeletions
        self.filesChanged = filesChanged
        self.isMerge = isMerge
        self.subject = subject
    }
}

public enum BucketUnit: Sendable {
    case day, week, month

    public static func forPreset(_ preset: RangePreset) -> BucketUnit {
        switch preset {
        case .week: .day
        case .month, .quarter: .week
        case .year: .month
        }
    }

    public var chartTitle: String {
        switch self {
        case .day: "Daily commits"
        case .week: "Weekly commits"
        case .month: "Monthly commits"
        }
    }
}

public struct ChartBucket: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let label: String      // `35` (ISO week), `Tue`, `Mar`
    public let peakLabel: String  // `W35`, `Tue`, `Mar`
    public let count: Int
}

public struct NamedCount: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int
}

public struct StatsSummary: Sendable, Equatable {
    public var commits = 0
    public var additions = 0
    public var deletions = 0
    public var filesChanged = 0
    public var activeDays = 0
    public var workingDays = 0
    public var currentStreak = 0
    public var longestStreak = 0
    public var buckets: [ChartBucket] = []
    public var busiestWeekday: String?
    public var busiestHour: Int?
    public var perRepo: [Int64: Int] = [:]
    public var types: [NamedCount] = []
    public var dayCounts: [Date: Int] = [:]

    public init() {}

    public var peak: ChartBucket? { buckets.max { $0.count < $1.count } }
}

public enum StatsCalculator {
    /// Saturday/Sunday by weekday number (the ISO calendar's `isDateInWeekend` depends on locale data).
    public static func isWeekend(_ date: Date, _ calendar: Calendar) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return wd == 1 || wd == 7
    }

    public static func summarize(
        facts: [CommitFact],
        interval: DateInterval,
        unit: BucketUnit,
        includeMerges: Bool = false,
        countWeekends: Bool = false,
        streakDays: Set<Date>? = nil,
        now: Date = Date(),
        calendar: Calendar = .worklog
    ) -> StatsSummary {
        let counted = facts.filter { (includeMerges || !$0.isMerge) && interval.contains($0.authorDate) }
        var s = StatsSummary()
        s.commits = counted.count
        s.additions = counted.reduce(0) { $0 + $1.statAdditions }
        s.deletions = counted.reduce(0) { $0 + $1.statDeletions }
        s.filesChanged = counted.reduce(0) { $0 + $1.filesChanged }

        var weekdayCounts: [Int: Int] = [:]
        var hourCounts: [Int: Int] = [:]
        var typeCounts: [String: Int] = [:]
        for f in counted {
            s.dayCounts[calendar.startOfDay(for: f.authorDate), default: 0] += 1
            s.perRepo[f.repoId, default: 0] += 1
            weekdayCounts[calendar.component(.weekday, from: f.authorDate), default: 0] += 1
            hourCounts[calendar.component(.hour, from: f.authorDate), default: 0] += 1
            if let type = conventionalType(f.subject) { typeCounts[type, default: 0] += 1 }
        }
        if let wd = weekdayCounts.max(by: { $0.value < $1.value })?.key {
            s.busiestWeekday = calendar.weekdaySymbols[wd - 1]
        }
        s.busiestHour = hourCounts.max(by: { $0.value < $1.value })?.key
        s.types = typeCounts.map { NamedCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }

        let activeSet = Set(s.dayCounts.keys)
        s.activeDays = activeSet.filter { countWeekends || !isWeekend($0, calendar) }.count
        s.workingDays = workingDays(in: interval, through: now, countWeekends: countWeekends, calendar: calendar)
        let streak = streaks(activeDays: streakDays ?? activeSet, through: now, countWeekends: countWeekends, calendar: calendar)
        s.currentStreak = streak.current
        s.longestStreak = streak.longest
        s.buckets = buckets(for: counted, interval: interval, unit: unit, now: now, calendar: calendar)
        return s
    }

    /// Days in the interval up to today, weekdays only unless `countWeekends`.
    public static func workingDays(in interval: DateInterval, through now: Date, countWeekends: Bool, calendar: Calendar = .worklog) -> Int {
        let endLimit = min(interval.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? interval.end)
        var day = calendar.startOfDay(for: interval.start)
        var n = 0
        while day < endLimit {
            if countWeekends || !isWeekend(day, calendar) { n += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return n
    }

    /// Current streak ends today (or yesterday, if nothing yet today). Weekends are skipped unless counted.
    public static func streaks(activeDays: Set<Date>, through now: Date, countWeekends: Bool, calendar: Calendar = .worklog) -> (current: Int, longest: Int) {
        let days = Set(activeDays.map { calendar.startOfDay(for: $0) })
        guard let first = days.min() else { return (0, 0) }
        func counts(_ d: Date) -> Bool { countWeekends || !isWeekend(d, calendar) }

        var longest = 0, run = 0
        var day = first
        let today = calendar.startOfDay(for: now)
        while day <= today {
            if counts(day) {
                if days.contains(day) { run += 1; longest = max(longest, run) } else if day != today { run = 0 }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        var current = 0
        day = today
        if !days.contains(today) { day = calendar.date(byAdding: .day, value: -1, to: today)! }
        while day >= first {
            if counts(day) {
                if days.contains(day) { current += 1 } else { break }
            }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return (current, longest)
    }

    public static func buckets(for facts: [CommitFact], interval: DateInterval, unit: BucketUnit, now: Date, calendar: Calendar = .worklog) -> [ChartBucket] {
        let component: Calendar.Component = switch unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        func bucketStart(_ d: Date) -> Date { calendar.dateInterval(of: component, for: d)?.start ?? d }
        var counts: [Date: Int] = [:]
        for f in facts { counts[bucketStart(f.authorDate), default: 0] += 1 }

        var result: [ChartBucket] = []
        var cursor = bucketStart(interval.start)
        let last = min(interval.end, now)
        let dayFormat = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        let monthFormat = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated)
        while cursor < interval.end && cursor <= last {
            let label: String, peak: String
            switch unit {
            case .day:
                label = cursor.formatted(dayFormat); peak = label
            case .week:
                let w = calendar.component(.weekOfYear, from: cursor)
                label = String(w); peak = "W\(w)"
            case .month:
                label = cursor.formatted(monthFormat); peak = label
            }
            result.append(ChartBucket(start: cursor, label: label, peakLabel: peak, count: counts[cursor] ?? 0))
            cursor = calendar.date(byAdding: component, value: 1, to: cursor)!
        }
        return result
    }

    private static let conventionalTypes: Set<String> = ["feat", "fix", "refactor", "test", "docs", "chore", "perf", "build", "ci", "style", "revert"]

    /// `feat(api)!: …` → `feat`
    public static func conventionalType(_ subject: String) -> String? {
        guard let colon = subject.firstIndex(of: ":") else { return nil }
        var head = subject[..<colon].lowercased()
        if head.hasSuffix("!") { head.removeLast() }
        if let paren = head.firstIndex(of: "(") { head = String(head[..<paren]) }
        return conventionalTypes.contains(head) ? head : nil
    }
}
