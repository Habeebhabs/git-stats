# Worklog

A small native macOS app that keeps a running log of **your own** git commits across all your local repos, groups them by ticket, tracks your tasks, and turns any period into a review-ready report.

Local-first and read-only: it only runs `git` read commands on your repos, and everything is stored in `~/Library/Application Support/Worklog/worklog.sqlite`.

## Run

Requires macOS 14+ and Xcode (or the Command Line Tools) with Swift 6.

```bash
scripts/build-app.sh --open
```

That builds `build/Worklog.app`. Copy it to `/Applications` if you want to keep it. On first launch, add your commit emails and repos (or scan a folder for repos).

## What it does

- **Overview:** commits, tickets closed, lines changed, active days and streak, compared with the previous period; activity chart and project split; tasks; commit timeline; tickets.
- **Commits:** every commit grouped by day, with filters for repo, range, text, ticket and merges.
- **Commit detail:** message, metadata, changed files, and a unified or split diff. Also copy SHA, open in editor, link tickets, and create a task.
- **Tickets:** keys like `PAY-218` are picked up from commit subjects, bodies and branch names. Each ticket has an editable title, status and notes, plus its commits and tasks.
- **Tasks:** quick add with `Review notes PAY-221 #review due:fri`, list or board view, drag to reorder, and undo delete.
- **Reports:** pick a period, projects, sections and grouping, with a live Markdown preview. Export to `.md` or PDF, or copy to the clipboard.
- **Live:** picks up new commits about 2 s after you commit, check out or pull (via FSEvents), and also syncs on wake and with ⌘R.

Keys: `1`–`5` switch screens, ⌘K opens the command palette, ⌘N adds a new task, ⌘E opens reports. In commit detail, `↑`/`↓` move between commits, `u`/`s` switch the diff view, `[`/`]` move between files, and `esc` goes back.

## Develop

```bash
swift test
```

See `CLAUDE.md` for the code layout and `plan.md` for the original spec.

Fonts: IBM Plex Sans and Mono, bundled under the SIL Open Font License (`Sources/Worklog/Resources/Fonts/OFL-LICENSE.txt`).
