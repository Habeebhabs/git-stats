import Foundation
import Testing
@testable import WorklogCore

@Suite struct LogParserTests {
    func record(_ sha: String, subject: String, body: String = "", parents: String = "p1", source: String = "refs/heads/main", numstat: String = "") -> String {
        "\u{1e}\(sha)\u{1f}\(sha.prefix(7))\u{1f}me@x.com\u{1f}Me\u{1f}2026-10-27T19:42:11+05:30\u{1f}2026-10-27T19:42:11+05:30\u{1f}\(parents)\u{1f}\(source)\u{1f}\(subject)\u{1f}\(body)\u{1f}\n\n\(numstat)"
    }

    @Test func parsesMultipleRecordsWithBodiesAndNumstat() {
        let out = record("a41f9c2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", subject: "Add ledger v2", body: "Line one\n\nLine two\n", numstat: "10\t2\tsrc/a.kt\n-\t-\tlogo.png\n")
            + record("b7e1d40bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", subject: "Empty body", parents: "p1 p2")
        let commits = LogParser.parse(Data(out.utf8))
        #expect(commits.count == 2)
        let a = commits[0]
        #expect(a.subject == "Add ledger v2")
        #expect(a.body == "Line one\n\nLine two")
        #expect(a.files.count == 2)
        #expect(a.additions == 10 && a.deletions == 2)
        #expect(a.files[1].isBinary)
        #expect(a.source == "refs/heads/main")
        #expect(a.authorDate == ISO8601DateFormatter().date(from: "2026-10-27T14:12:11Z"))
        #expect(commits[1].isMerge)
        #expect(commits[1].body.isEmpty)
        #expect(commits[1].files.isEmpty)
    }

    @Test func resolvesRenames() {
        #expect(LogParser.resolveRename("src/{a => b}/c.kt") == ("src/b/c.kt", "src/a/c.kt"))
        #expect(LogParser.resolveRename("{ => lib}/x.swift") == ("lib/x.swift", "x.swift"))
        #expect(LogParser.resolveRename("old.txt => new.txt") == ("new.txt", "old.txt"))
        #expect(LogParser.resolveRename("plain.txt") == ("plain.txt", nil))
    }
}

@Suite struct DiffParserTests {
    let sample = """
    diff --git a/src/Ledger.kt b/src/Ledger.kt
    index 1111111..2222222 100644
    --- a/src/Ledger.kt
    +++ b/src/Ledger.kt
    @@ -42,4 +42,5 @@ class LedgerRepository(
         private val db: Database,
    -    private val clock: Clock
    +    private val clock: Clock,
    +    private val flags: Flags
     ) {
    diff --git a/new.sql b/new.sql
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.sql
    @@ -0,0 +1,2 @@
    +CREATE TABLE x;
    +-- comment line starting with dashes
    \\ No newline at end of file
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/old name.txt b/new name.txt
    similarity index 100%
    rename from old name.txt
    rename to new name.txt
    diff --git a/img.png b/img.png
    Binary files a/img.png and b/img.png differ

    """

    @Test func parsesFileKindsAndLineNumbers() {
        let files = UnifiedDiffParser.parse(sample)
        #expect(files.map(\.status) == [.modified, .added, .deleted, .renamed, .binary])
        let m = files[0]
        #expect(m.newPath == "src/Ledger.kt")
        #expect(m.hunks.count == 1)
        let lines = m.hunks[0].lines
        #expect(lines.count == 5)
        #expect(lines[0] == DiffLine(kind: .context, text: "    private val db: Database,", oldNo: 42, newNo: 42))
        #expect(lines[1].kind == .deletion && lines[1].oldNo == 43)
        #expect(lines[2].kind == .addition && lines[2].newNo == 43)
        #expect(lines[3].newNo == 44)
        #expect(lines[4].oldNo == 44 && lines[4].newNo == 45)
        #expect(m.additions == 2 && m.deletions == 1)
        #expect(m.firstChangedLine == 43)

        let added = files[1]
        #expect(added.newPath == "new.sql")
        #expect(added.hunks[0].lines.map(\.kind) == [.addition, .addition, .noNewline])
        #expect(added.hunks[0].lines[1].text == "-- comment line starting with dashes")

        #expect(files[2].newPath == "gone.txt")
        #expect(files[3].oldPath == "old name.txt" && files[3].newPath == "new name.txt")
        #expect(files[4].newPath == "img.png")
    }

    @Test func splitRowsPairDeletionsWithAdditions() {
        let hunk = UnifiedDiffParser.parse(sample)[0].hunks[0]
        let rows = SplitDiff.rows(for: hunk)
        #expect(rows.count == 4)
        #expect(rows[1].left?.kind == .deletion && rows[1].right?.kind == .addition)
        #expect(rows[2].left == nil && rows[2].right?.kind == .addition)
    }
}

@Suite struct TicketExtractorTests {
    @Test func findsTicketsInSubjectBodyAndBranch() {
        let x = TicketExtractor()
        let found = x.extract(subject: "PAY-218: ledger v2 (also MOB-9)", body: "Refs ADM-37. Uses UTF-8 and ISO-8601", branch: "feat/PAY-300-thing", repoName: "api")
        #expect(found == [
            ExtractedTicket(key: "PAY-218", source: "subject"),
            ExtractedTicket(key: "MOB-9", source: "subject"),
            ExtractedTicket(key: "ADM-37", source: "body"),
            ExtractedTicket(key: "PAY-300", source: "branch"),
        ])
    }

    @Test func allowlistRestrictsPrefixes() {
        let x = TicketExtractor(allowlist: ["PAY"])
        #expect(x.keys(in: "PAY-1 MOB-2 SHA-256") == ["PAY-1"])
    }

    @Test func githubIssuesAreScopedToRepo() {
        let x = TicketExtractor(githubIssues: true)
        let found = x.extract(subject: "Fix crash (#123)", body: nil, branch: nil, repoName: "mobile")
        #expect(found.map(\.key) == ["mobile#123"])
    }
}

@Suite struct TaskInputParserTests {
    // Wednesday, Oct 28 2026
    let now = ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z")!

    @Test func parsesTicketTagsAndDue() {
        let p = TaskInputParser.parse("Review release notes PAY-221 #review due:fri", now: now)
        #expect(p.title == "Review release notes")
        #expect(p.ticketKey == "PAY-221")
        #expect(p.tags == ["review"])
        let cal = Calendar.worklog
        #expect(cal.component(.weekday, from: p.dueDate!) == 6)
        #expect(cal.dateComponents([.day], from: cal.startOfDay(for: now), to: p.dueDate!).day == 2)
    }

    @Test func plainTitle() {
        let p = TaskInputParser.parse("Prepare Q3 demo notes", now: now)
        #expect(p == ParsedTaskInput(title: "Prepare Q3 demo notes", ticketKey: nil, tags: [], dueDate: nil))
    }

    @Test func isoDueAndTrailingDash() {
        let p = TaskInputParser.parse("Fix flaky test — PAY-204 due:2026-11-04", now: now)
        #expect(p.title == "Fix flaky test")
        #expect(p.ticketKey == "PAY-204")
        #expect(Calendar.worklog.component(.day, from: p.dueDate!) == 4)
    }
}

@Suite struct MiscTests {
    @Test func globs() {
        let ex = PathExclusion(globs: ["*.lock", "package-lock.json", "vendor/**", "apps/**/gen/*.kt"])
        #expect(ex.isExcluded("Gemfile.lock"))
        #expect(ex.isExcluded("web/package-lock.json"))
        #expect(ex.isExcluded("vendor/a/b.go"))
        #expect(ex.isExcluded("apps/android/x/gen/R.kt"))
        #expect(!ex.isExcluded("src/vendor.go"))
        #expect(!ex.isExcluded("src/lock.swift"))
    }

    @Test func numberFormatting() {
        #expect(Fmt.compact(12_400) == "12.4k")
        #expect(Fmt.compact(950) == "950")
        #expect(Fmt.compact(1_000) == "1k")
        #expect(Fmt.thousands(12_410) == "12,410")
        #expect(Fmt.minus(5_100, compact: true) == "\u{2212}5.1k")
        #expect(Fmt.delta(118, 100).text == "▲ 18% vs prev")
    }

    @Test func conventionalTypes() {
        #expect(StatsCalculator.conventionalType("feat(api)!: x") == "feat")
        #expect(StatsCalculator.conventionalType("Fix: y") == "fix")
        #expect(StatsCalculator.conventionalType("Merge branch x") == nil)
    }

    @Test func reportTitles() {
        let cal = Calendar.worklog
        func d(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 1))! }
        #expect(ReportBuilder.title(for: DateInterval(start: d(2026, 7), end: d(2026, 10))) == "Q3 2026")
        #expect(ReportBuilder.title(for: DateInterval(start: d(2026, 1), end: d(2026, 7))) == "H1 2026")
        #expect(ReportBuilder.title(for: DateInterval(start: d(2026, 1), end: d(2027, 1))) == "2026")
    }
}

@Suite struct StreakTests {
    let cal = Calendar.worklog
    func day(_ s: String) -> Date { cal.startOfDay(for: ISO8601DateFormatter().date(from: s + "T12:00:00Z")!) }

    @Test func weekendsDoNotBreakStreaks() {
        // Thu, Fri, (weekend), Mon, Tue ; now = Tue evening
        let days: Set<Date> = [day("2026-10-22"), day("2026-10-23"), day("2026-10-26"), day("2026-10-27")]
        let r = StatsCalculator.streaks(activeDays: days, through: day("2026-10-27").addingTimeInterval(3600 * 8), countWeekends: false, calendar: cal)
        #expect(r.current == 4)
        #expect(r.longest == 4)
        let counted = StatsCalculator.streaks(activeDays: days, through: day("2026-10-27"), countWeekends: true, calendar: cal)
        #expect(counted.current == 2)
        #expect(counted.longest == 2)
    }

    @Test func todayWithoutCommitsKeepsStreakAlive() {
        let days: Set<Date> = [day("2026-10-26"), day("2026-10-27")]
        let r = StatsCalculator.streaks(activeDays: days, through: day("2026-10-28"), countWeekends: false, calendar: cal)
        #expect(r.current == 2)
    }

    @Test func workingDaysSkipWeekends() {
        let interval = DateInterval(start: day("2026-10-19"), end: day("2026-10-26")) // Mon..Sun
        #expect(StatsCalculator.workingDays(in: interval, through: day("2026-10-30"), countWeekends: false, calendar: cal) == 5)
        #expect(StatsCalculator.workingDays(in: interval, through: day("2026-10-30"), countWeekends: true, calendar: cal) == 7)
    }
}
