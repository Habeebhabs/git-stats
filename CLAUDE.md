# Worklog (git-stats)

Native macOS app (SwiftUI, macOS 14+) that tracks my own git commits across local repos, groups them by ticket, manages tasks, and exports performance-review reports.

- The original spec is in `plan.md` (UI spec in Appendix A). Treat it as guidance; the notes below record where the implementation intentionally differs.
- Design mockups are in `design-reference/`. Read them as markup for exact styles; they don't run standalone.
- Keep the app local-first and read-only on repos (see plan §1 Principles).

## Layout

Swift package (no `.xcodeproj`; open `Package.swift` in Xcode if you want the IDE):

- `Sources/WorklogCore/` — no UI. `Git/` (GitRunner = the only place that spawns git; LogParser; UnifiedDiffParser), `Data/` (GRDB schema, records, queries, mutations, settings), `Sync/` (SyncEngine actor, RepoWatcher/FSEvents, TicketExtractor, CommitIngest), `Domain/` (stats, date ranges, task input parser, report builder, formatting).
- `Sources/Worklog/` — SwiftUI app. `App/` (AppModel = all app state + actions, key handling), `Theme/` (Design D tokens, font registration), `Shared/` (components), `Features/<Screen>/`.
- `Tests/WorklogCoreTests/` — parsers, stats, tickets, reports, and SyncEngine integration tests against throwaway git repos.

## Commands

```bash
swift test                    # all core tests
swift build                   # debug build
scripts/build-app.sh --open   # release build → build/Worklog.app (ad-hoc signed) and launch
```

Dev aids: `WORKLOG_DATA_DIR=<dir>` uses a separate database; adding `WORKLOG_SNAPSHOT_DIR=<dir>` renders every screen to PNG and quits (handy for visual checks without clicking).

## Deviations from plan.md

- SwiftPM package + bundling script instead of an Xcode project.
- Incremental sync runs one `git log --stdin` per repo: moved refs, excluding old tips (`^cursor`). Default-branch refs are scanned first, then feature branches excluding the default branch, so branch-name tickets (`feat/PAY-218-…`) only come from real feature work. A non-ancestor tip or deleted ref triggers a reachability refresh (rewritten commits hidden, kept).
- Overview chart buckets follow the range: days (wk), weeks (mo/qtr), months (yr).
- Merges are excluded from stats by default (setting).
- Report ticket title falls back to the ticket's first commit subject.
- Not built yet: global quick-add hotkey, scheduled `git fetch`, menu bar extra, auto-complete task suggestions, CSV export, light theme, signing/notarization.
