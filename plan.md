# Worklog — Implementation Plan

A lightweight native macOS app that tracks **my own** git commits across all my repos, groups them by ticket, manages my tasks, and exports performance-review reports.

> Working name: **Worklog**. Rename freely.

---

## 1. Problem & Goals

**Problem:** I don't track my work as I go. At every performance review I have to dig through repos to find my commits and their tickets, then reconstruct what I did. Pending tasks live in a separate sheet.

**Goals (v1)**
1. See all my commits across multiple local repos in one place, filtered by date range and project.
2. Automatically group commits by ticket ID (e.g. `PAY-218`).
3. View any commit's details and full code diff (unified + split).
4. Manage tasks (pending / in progress / done), optionally linked to a ticket.
5. See stats: commits, lines changed, active days, streaks, weekly activity, project split.
6. Export a review-ready report (Markdown first, PDF next) for any date range.
7. Stay up to date automatically when I commit, with no manual refresh needed.

**Non-goals (v1)** — deliberately deferred
- Jira / Linear / GitHub / GitLab API integrations
- AI summaries
- Team or multi-user features, cloud sync, accounts
- Phone companion app

**Principles**
- Local-first and offline. Nothing leaves the machine.
- Read-only on repos. The app never writes to a git repo, except an optional `git fetch`.
- Fast: incremental scanning, everything off the main thread.
- Small: no Electron, minimal dependencies.

---

## 2. Chosen Design Direction

**Design D — "Terminal-inspired"** (from the design canvas)
- Dark charcoal background `#0F1210`, surfaces `#141815`, borders `#222823`
- Accent green `#5EE89B`; amber `#F2C46D` for SHAs; red `#F28B82` for deletions; muted text `#8E9C8F`
- **IBM Plex Sans** for UI text, **IBM Plex Mono** for numbers, ticket IDs, SHAs, labels and code
- Terminal touches: `~/worklog▌` logo, `// section` labels, number-key navigation (1–5), `❯` command search (⌘K), git-graph commit timeline
- Normal macOS ergonomics: real buttons, checkboxes, sidebar, rounded cards (10–12 px radius)

Bundle IBM Plex fonts in the app (OFL license). Define all colors and fonts as design tokens in one file (`Theme.swift`). Plan a light theme later, but don't block on it.

**The exact UI spec is in [Appendix A](#appendix-a--ui-spec-design-d)**: every color, font size, spacing value, component and screen layout. The original mockups are in `design-reference/overview.reference.html` and `design-reference/commit-detail.reference.html`. Their inline styles are the source of truth for any value the appendix doesn't cover. They're design files for an editor and won't run standalone, so read them as markup.

---

## 3. Tech Stack

| Concern | Choice | Why |
|---|---|---|
| Language / UI | Swift 6, SwiftUI | Native, light, fast |
| Min OS | macOS 14 (Sonoma) | `Observable`, modern SwiftUI APIs |
| Persistence | SQLite via **GRDB.swift** | Fast queries and aggregations, migrations, observation |
| Git access | Shell out to `/usr/bin/git` via `Process` | Simplest, matches git exactly; no libgit2 build pain |
| File watching | **FSEvents** (`FSEventStreamCreate`) | Instant updates on commit/checkout/pull |
| Charts | Swift Charts | Built in |
| Diff rendering | Custom parser + SwiftUI `LazyVStack` of monospace lines | Full control over the D look |
| Syntax highlighting | Later: Highlightr or a tree-sitter wrapper | Not needed for v1 |
| PDF export | `ImageRenderer` or a `WKWebView` print of HTML | Phase 2 |
| Tests | Swift Testing / XCTest | |

Dependencies: **GRDB** only for v1. Add a highlighter later if wanted.

**Sandboxing:** use a **non-sandboxed** app distributed outside the App Store, signed and notarized. This avoids security-scoped bookmark friction for arbitrary repo folders and for running `git`. If App Store distribution is ever wanted, switch to security-scoped bookmarks (see §15).

---

## 4. Architecture

```
┌──────────────────────── SwiftUI Views ────────────────────────┐
│ Overview · Commits · CommitDetail · Tickets · Tasks · Reports │
│ Settings · CommandPalette                                     │
└───────────────▲───────────────────────────────▲───────────────┘
                │ @Observable view models       │
┌───────────────┴──────────┐      ┌─────────────┴──────────────┐
│ Stores (read models)     │      │ TaskStore (CRUD)           │
│ CommitStore, StatsStore, │      │                            │
│ TicketStore              │      │                            │
└───────────────▲──────────┘      └─────────────▲──────────────┘
                │ GRDB ValueObservation         │
┌───────────────┴───────────────────────────────┴──────────────┐
│                  Database (GRDB, SQLite)                      │
└───────────────▲───────────────────────────────────────────────┘
                │ writes
┌───────────────┴──────────────┐   ┌────────────────────────────┐
│ SyncEngine (actor)           │◀──│ RepoWatcher (FSEvents)     │
│ - incremental scan per repo  │   │ - debounced change events  │
│ - rewrite detection          │   └────────────────────────────┘
│ - ticket extraction          │   ┌────────────────────────────┐
│                              │◀──│ Triggers: launch, wake,    │
└───────────────▲──────────────┘   │ ⌘R, fetch timer            │
                │                  └────────────────────────────┘
┌───────────────┴──────────────┐
│ GitClient (actor)            │
│ - runs git via Process       │
│ - parses log / numstat / diff│
└──────────────────────────────┘
```

**Layers**
- **GitClient** — the only place that runs `git`. Async functions that return typed values. Uses a concurrency limit (max 4 git processes at once).
- **SyncEngine** — orchestrates scans, writes to the DB, and holds per-repo sync state.
- **RepoWatcher** — FSEvents wrapper. Emits `repoChanged(repoID)` with a 1.5 s debounce.
- **Database** — GRDB `DatabasePool` with migrations.
- **Stores** — `@Observable` classes exposing query results to views. They observe the DB, so the UI updates automatically after a sync.
- **Views** — dumb views that render store state.

---

## 5. Data Model (SQLite)

```sql
-- Repositories the user added
CREATE TABLE repo (
  id            INTEGER PRIMARY KEY,
  path          TEXT NOT NULL UNIQUE,      -- absolute path to working tree
  name          TEXT NOT NULL,             -- display name, default = folder name
  color         TEXT NOT NULL,             -- hex, for project dots
  default_branch TEXT,                     -- e.g. main / develop (detected)
  is_active     INTEGER NOT NULL DEFAULT 1,
  added_at      DATETIME NOT NULL,
  last_synced_at DATETIME,
  last_fetch_at DATETIME
);

-- My author identities (emails / names) used to filter commits
CREATE TABLE identity (
  id     INTEGER PRIMARY KEY,
  email  TEXT NOT NULL UNIQUE COLLATE NOCASE,
  name   TEXT
);

-- Per-ref sync cursor for incremental scans
CREATE TABLE ref_cursor (
  repo_id   INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  ref_name  TEXT NOT NULL,                 -- refs/heads/main, refs/remotes/origin/main …
  last_sha  TEXT NOT NULL,
  updated_at DATETIME NOT NULL,
  PRIMARY KEY (repo_id, ref_name)
);

-- My commits (deduplicated per repo by sha)
CREATE TABLE commit (
  id            INTEGER PRIMARY KEY,
  repo_id       INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
  sha           TEXT NOT NULL,
  short_sha     TEXT NOT NULL,
  author_email  TEXT NOT NULL,
  author_date   DATETIME NOT NULL,         -- when written (use for stats)
  commit_date   DATETIME NOT NULL,
  subject       TEXT NOT NULL,
  body          TEXT,
  branch_hint   TEXT,                      -- first ref it was found on
  additions     INTEGER NOT NULL DEFAULT 0,
  deletions     INTEGER NOT NULL DEFAULT 0,
  files_changed INTEGER NOT NULL DEFAULT 0,
  is_merge      INTEGER NOT NULL DEFAULT 0,
  is_reachable  INTEGER NOT NULL DEFAULT 1, -- 0 after rewrite (kept for history)
  UNIQUE (repo_id, sha)
);
CREATE INDEX idx_commit_date ON commit(author_date);
CREATE INDEX idx_commit_repo_date ON commit(repo_id, author_date);

-- Per-file stats (from --numstat); the diff itself is fetched on demand
CREATE TABLE commit_file (
  commit_id  INTEGER NOT NULL REFERENCES commit(id) ON DELETE CASCADE,
  path       TEXT NOT NULL,
  old_path   TEXT,                         -- renames
  additions  INTEGER,                      -- NULL for binary
  deletions  INTEGER,
  PRIMARY KEY (commit_id, path)
);

-- Tickets discovered from commits/branches (or created from tasks)
CREATE TABLE ticket (
  id         INTEGER PRIMARY KEY,
  key        TEXT NOT NULL UNIQUE,         -- PAY-218
  title      TEXT,                         -- user-entered for now (API later)
  status     TEXT NOT NULL DEFAULT 'active', -- active | review | done (manual)
  notes      TEXT,
  first_seen DATETIME,
  last_seen  DATETIME
);

CREATE TABLE commit_ticket (
  commit_id INTEGER NOT NULL REFERENCES commit(id) ON DELETE CASCADE,
  ticket_id INTEGER NOT NULL REFERENCES ticket(id) ON DELETE CASCADE,
  source    TEXT NOT NULL,                 -- 'subject' | 'body' | 'branch' | 'manual'
  PRIMARY KEY (commit_id, ticket_id)
);

-- Tasks
CREATE TABLE task (
  id          INTEGER PRIMARY KEY,
  title       TEXT NOT NULL,
  notes       TEXT,
  status      TEXT NOT NULL DEFAULT 'pending', -- pending | in_progress | done
  ticket_id   INTEGER REFERENCES ticket(id) ON DELETE SET NULL,
  repo_id     INTEGER REFERENCES repo(id) ON DELETE SET NULL,
  tags        TEXT,                        -- comma-separated: bug,feature,review…
  due_date    DATE,
  created_at  DATETIME NOT NULL,
  completed_at DATETIME,
  sort_order  REAL NOT NULL DEFAULT 0
);

-- App settings (key/value)
CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

**Notes**
- Diffs are **not stored**. They're fetched with `git show` when a commit is opened, and cached in memory (LRU, ~50 commits).
- Store `author_date` in UTC and convert to the local time zone for display.
- DB location: `~/Library/Application Support/Worklog/worklog.sqlite`.

---

## 6. Git Integration

All commands run with `-C <repoPath>`, `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `--no-pager`, and `core.quotepath=off`.

### 6.1 Detect repo and default branch
```
git rev-parse --show-toplevel            # validate it's a repo
git symbolic-ref refs/remotes/origin/HEAD  # → origin/main (fallback: main, master, develop)
```

### 6.2 List refs to scan
```
git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes
```
Scan local branches plus `origin/*` remotes. This catches commits on feature branches that were later squash-merged.

### 6.3 Incremental log with stats
Use a record/field separator that never appears in commit text (`\x1e` for records, `\x1f` for fields):
```
git log <range> --no-merges? --author=<email1> --author=<email2> \
  --format='%x1e%H%x1f%h%x1f%ae%x1f%aI%x1f%cI%x1f%P%x1f%s%x1f%b%x1f' \
  --numstat
```
- `<range>`: `<last_sha>..<ref>` when a cursor exists, otherwise `<ref> --since=<initial window>`. The initial window is a setting (default: 12 months).
- Multiple `--author` flags are OR-ed.
- Keep merges, but flag them (`is_merge = parents > 1`) and exclude them from line stats by default.
- Parse `--numstat` lines: `adds<TAB>dels<TAB>path`. Binary files show `-` → NULL. Renames appear as `old => new` or `{a => b}/c`.

Large output: stream stdout line by line (`FileHandle.bytes.lines`) instead of buffering it all.

### 6.4 Rewrite detection
For each cursor before scanning:
```
git cat-file -e <last_sha>^{commit}            # still exists?
git merge-base --is-ancestor <last_sha> <ref>  # still in history?
```
If either fails (rebase or force-push):
1. Mark that repo's commits in the last 30 days as `is_reachable = 0`.
2. Rescan `<ref> --since=30.days`.
3. Upsert by `(repo_id, sha)` and set `is_reachable = 1` for every commit found.
4. Unreachable commits stay hidden but are kept, so a rebased commit that reappears with a new SHA doesn't lose its task link. Re-link by matching `(subject, author_date, ticket)`.

### 6.5 Commit detail and diff (on demand)
```
git show <sha> --format='%H%x1f%B' --stat=200 --patch --find-renames -U3 --no-color
git show <sha> -- <path>          # single file, for very large commits
```
Size guards: if a file's diff is over 3,000 lines or the commit is over 2 MB, show "Large diff — load anyway?". Binary files show "Binary file changed".

### 6.6 Optional remote fetch
```
git fetch --all --prune --quiet
```
Off by default. Options: off / every 30 min / every 2 h. It uses the user's existing credentials (SSH agent, keychain helper). On failure (auth, offline), show a quiet warning on that repo, never a modal.

---

## 7. Sync & Refresh Mechanism

**Triggers**
| Trigger | What happens |
|---|---|
| App launch | Sync all active repos |
| Mac wakes from sleep (`NSWorkspace.didWakeNotification`) | Sync all |
| FSEvents change in `<repo>/.git/{HEAD,refs,logs,packed-refs}` | Sync that repo (debounced 1.5 s) |
| ⌘R / refresh button | Sync all |
| Fetch timer (if enabled) | `git fetch`, then sync that repo |
| Repo added | Initial scan (shows progress) |
| Identity list changed | Full rescan of all repos (author filter changed) |

**Worktrees and submodules:** resolve the real git dir with `git rev-parse --git-dir` / `--git-common-dir` and watch that path.

**SyncEngine flow (per repo)**
1. Skip if a sync is already running for this repo; set a "dirty" flag so it runs once more afterwards.
2. List refs (§6.2).
3. For each ref: rewrite check (§6.4) → incremental log (§6.3).
4. Parse → extract tickets (§8) → upsert in **one write transaction**.
5. Update `ref_cursor` and `repo.last_synced_at`.
6. Auto-complete linked tasks (§9.3).
7. GRDB observation notifies the stores, and the UI updates.

**Concurrency:** `SyncEngine` is an `actor`, with a task group capped at 4 repos in parallel. Wrap each repo sync in a 60 s timeout. Errors are recorded per repo (`repo.last_error`) and shown in the sidebar, never crashing the sync of other repos.

**UI feedback:** a status line in the sidebar footer ("synced 2m ago" / "syncing payments-api…") and a red dot on repos with errors.

---

## 8. Ticket Extraction

Default pattern (configurable in Settings):
```regex
\b([A-Z][A-Z0-9]{1,9}-\d{1,6})\b
```
- Look in subject → body → branch name (for example `feat/PAY-218-ledger-v2`), and record the source.
- **Prefix allowlist** setting (e.g. `PAY, MOB, ADM`) to avoid false matches such as `UTF-8`, `ISO-8601` or `SHA-256`. If the allowlist is empty, use a default denylist: `UTF, ISO, SHA, RFC, HTTP, TLS, CVE`.
- Also support GitHub-style `#123` as an option, mapped to `<repo>#123`.
- A commit can have several tickets.
- Manual override: in Commit Detail, add or remove ticket links (`source = 'manual'`).
- Commits with no ticket are grouped under **"No ticket"** in the Tickets view, so nothing is lost.

---

## 9. Tasks

### 9.1 Features
- Quick add from the Tasks panel input, the Overview, or a **global hotkey** (⌃⌥Space) that opens a small floating input panel.
- Inline parsing of the input: `Review release notes PAY-221 #review due:fri`
  - trailing ticket key → `ticket_id` (creates the ticket row if new)
  - `#tag` → tags
  - `due:<date>` → due date (supports `today`, `tomorrow`, weekday names, `2026-11-04`)
- Statuses: pending → in progress → done. Shown as a list (default) or a board (optional).
- Drag to reorder. Edit inline. Delete with undo (⌘Z).
- Filter by status, project, tag or due date. "Due this week" section.

### 9.2 Linking
- A task with a ticket shows that ticket's commit count and last commit.
- In Commit Detail: "Create task from this commit" and "Link to task".

### 9.3 Auto-complete (opt-in setting)
When a commit referencing the task's ticket lands on the repo's **default branch**, suggest marking the task done. Show it as a dismissable suggestion, not a silent change.

---

## 10. Stats

All computed with SQL over `commit` for the selected range and project filter.
- **Totals:** commits, additions, deletions, files changed, tickets touched, tickets done, active days / working days.
- **Comparison:** the same metric for the previous equal-length period (▲/▼ %).
- **Weekly commits:** bar chart (ISO weeks).
- **Heatmap:** day-level commit counts (for longer ranges).
- **Streaks:** current and longest run of days with commits. Setting: count weekends or not.
- **Busiest weekday / hour.**
- **Project split:** % of commits per repo.
- **Commit type split** (from conventional-commit prefixes such as `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`), where present.

Exclude from line stats by default (setting): merge commits, lockfiles (`*.lock`, `package-lock.json`, `Podfile.lock`, `gradle.lockfile`), and generated or vendored paths (configurable glob list). This keeps "lines changed" honest.

---

## 11. Reports

**Report builder screen**
1. Pick a range: preset (this quarter, last quarter, H1, H2, year, custom).
2. Pick projects (all by default).
3. Pick sections: Summary stats · Tickets (with commits) · Completed tasks · Pending tasks · Notes.
4. Grouping: by project → ticket, or by ticket only, or by month.
5. Preview on the right, live.
6. Export: **Markdown** (v1), **copy to clipboard** (v1), **PDF** (phase 2), **CSV** of commits (phase 2).

**Markdown template (v1)**
```markdown
# Work summary — Q3 2026 (Jul 1 – Sep 30)

**248 commits · 37 tickets done · +12.4k / −5.1k lines · 54 of 65 days active**

## payments-api
### PAY-204 — Retry failed card captures (done)
- 18 commits · +1,240 / −312
- Key commits: exponential backoff for capture retries; idempotent capture path tests

### PAY-218 — Ledger v2 schema migration (in progress)
…

## Completed tasks
- Fix flaky checkout test (PAY-204)
…

## Notes
<user-written notes for this period>
```
- "Key commits": the top 3 commits per ticket by lines changed, excluding merges, shown as subjects.
- Ticket titles come from the user-entered `ticket.title`, falling back to the most common subject words. API lookups come later.
- **Period notes:** a free-text notes field per quarter, editable in the report builder and saved in the DB.

---

## 12. Screens & UI Spec (Design D)

Window: min 1000 × 680, default 1280 × 860. Sidebar 210–240 px, collapsible (⌘0).

| # | Screen | Contents |
|---|---|---|
| 1 | **Overview** | ⌘K search bar, range switcher (wk/mo/qtr/yr), Export button; greeting line; 4 stat tiles; weekly commits chart; Tasks panel with quick add; commit history timeline (git-graph style, latest 5–10); Tickets list (latest active). |
| 2 | **Commits** | Full list with filters (repo, ticket, text search, date range, include merges). Grouped by day. Infinite scroll (paged queries of 100). Click → Commit Detail. |
| 3 | **Commit Detail** | Back + prev/next (↑/↓); header (subject, body, sha, ticket, branch, date, totals); copy SHA, open in editor; file list with per-file +/−; diff pane with unified/split toggle, line numbers, hunk headers; sidebar section listing other commits on the same ticket. |
| 4 | **Tickets** | List grouped by status, with commit count, lines, first/last activity. Ticket detail: editable title, status, notes; its commits (timeline); linked tasks. |
| 5 | **Tasks** | List/board toggle, filters, quick add, drag to reorder, due-this-week section. |
| 6 | **Reports** | Builder (left) + live preview (right), export buttons. |
| 7 | **Settings** | Repos (add/remove/rename/color, default branch, scan window), Identities, Ticket pattern + allowlist, Excluded paths, Fetch interval, Global hotkey, Launch at login, Theme. |
| 8 | **Command palette (⌘K)** | Fuzzy search across commits (subject, sha), tickets, tasks, and actions ("Add task", "Export Q3 report", "Refresh"). |
| 9 | **Onboarding** (first launch) | Check git exists → detect `git config user.email` as the first identity → add repos (folder picker, or "scan a folder for repos" up to 3 levels deep) → initial scan with progress. |

**Menu bar extra (phase 2):** today's commit count, quick-add task, open app.

**Keyboard shortcuts**
- `1`–`5` (when not typing) or ⌘1–⌘5: switch sections
- ⌘K command palette · ⌘N new task · ⌘R refresh · ⌘E export report
- ↑/↓ in lists, ⏎ open, ⎋ back
- In Commit Detail: `u` unified / `s` split, `[` `]` previous/next file

**"Open in editor":** setting for the editor command, with presets for VS Code (`code -g path:line`), Android Studio (`studio`), Xcode (`xed`), and a custom command.

**Accessibility:** all controls are real SwiftUI controls with labels; color is never the only signal (+/− signs in diffs); support Dynamic Type sizes in the sidebar and lists; meet 4.5:1 contrast.

---

## 13. Diff Rendering

**Parser** (`UnifiedDiffParser`): turns `git show` output into
```swift
struct FileDiff { let oldPath: String?; let newPath: String; let status: Status /*added, deleted, modified, renamed, binary*/; let hunks: [Hunk] }
struct Hunk { let header: String; let oldStart: Int; let newStart: Int; let lines: [DiffLine] }
struct DiffLine { enum Kind { case context, addition, deletion, noNewline } let kind: Kind; let text: String; let oldNo: Int?; let newNo: Int? }
```

**Unified view:** a `LazyVStack` row per line: old number, new number, sign, text. Green background for additions, red for deletions, blue-tinted hunk headers.

**Split view:** pair runs of deletions and additions side by side (same algorithm as the mockup): context lines on both sides, a block of `d` lines paired with the following block of `a` lines, and empty filler cells where counts differ.

**Performance:** `LazyVStack` inside a horizontal + vertical `ScrollView`; monospace font; no wrapping by default (toggle for wrap). Large-file guard per §6.5.

**Later:** word-level highlights within changed lines; syntax highlighting.

---

## 14. Project Structure

```
Worklog/
├── Worklog.xcodeproj
├── Worklog/
│   ├── App/
│   │   ├── WorklogApp.swift          # @main, window, commands, menu
│   │   ├── AppState.swift            # selection, range, filters
│   │   └── Hotkey.swift              # global quick-add hotkey
│   ├── Theme/
│   │   ├── Theme.swift               # colors, fonts, spacing tokens
│   │   └── Fonts/                    # IBM Plex Sans / Mono
│   ├── Git/
│   │   ├── GitClient.swift           # Process runner, streaming
│   │   ├── LogParser.swift           # %x1e/%x1f + numstat parsing
│   │   ├── UnifiedDiffParser.swift
│   │   └── GitModels.swift
│   ├── Sync/
│   │   ├── SyncEngine.swift          # actor
│   │   ├── RepoWatcher.swift         # FSEvents
│   │   ├── TicketExtractor.swift
│   │   └── FetchScheduler.swift
│   ├── Data/
│   │   ├── AppDatabase.swift         # GRDB pool + migrations
│   │   ├── Records/                  # Repo, Commit, CommitFile, Ticket, Task, Identity…
│   │   └── Queries/                  # StatsQueries, CommitQueries, TicketQueries
│   ├── Stores/
│   │   ├── CommitStore.swift
│   │   ├── StatsStore.swift
│   │   ├── TicketStore.swift
│   │   └── TaskStore.swift
│   ├── Features/
│   │   ├── Overview/
│   │   ├── Commits/
│   │   ├── CommitDetail/
│   │   ├── Tickets/
│   │   ├── Tasks/
│   │   ├── Reports/
│   │   ├── Settings/
│   │   ├── CommandPalette/
│   │   └── Onboarding/
│   └── Shared/                       # components: StatTile, Chip, SectionLabel, GitGraphRow…
└── WorklogTests/
    ├── LogParserTests.swift
    ├── UnifiedDiffParserTests.swift
    ├── TicketExtractorTests.swift
    ├── TaskInputParserTests.swift
    ├── SyncEngineTests.swift         # against temp git repos
    └── Fixtures/                     # sample git outputs
```

---

## 15. Edge Cases & Risks

| Case | Handling |
|---|---|
| `git` missing | Onboarding shows "Install Xcode Command Line Tools" with a button running `xcode-select --install`. |
| Multiple author emails | Identities list; pre-fill from `git config --global user.email` and each repo's local `user.email`. |
| Squash-merged PRs | Scan feature branches and `origin/*`; dedupe by SHA. Phase 3 (API) can add PR data. |
| Rebase / force-push | §6.4 rewrite detection. |
| Huge repos / long history | Initial scan window (12 months default), streaming parse, background actor, progress UI. |
| Monorepo with many projects | Phase 2: "path filters" per virtual project (e.g. `apps/android/**`). |
| Repo moved or deleted | Mark repo "missing" with a re-locate button; keep its data. |
| Shallow clones | Detect with `git rev-parse --is-shallow-repository`; warn that history may be incomplete. |
| Detached HEAD, worktrees, submodules | Resolve the git dir properly; scanning works on refs, not HEAD. |
| Non-UTF-8 commit messages | Decode lossily; never crash. |
| Weird filenames | `core.quotepath=off`; parse numstat with `-z` if needed. |
| Ticket false positives | Allowlist/denylist (§8). |
| Time zones | Store UTC; use the local time zone for day boundaries and streaks. |
| Work-repo policy | Fully local and read-only; no network except optional `git fetch`. |
| App Store sandbox (if ever) | Security-scoped bookmarks per repo and an embedded or allowed git path; out of scope for v1. |

---

## 16. Testing

- **Unit:** LogParser (normal, empty body, multi-line body, binary numstat, renames), UnifiedDiffParser (added/deleted/renamed/binary/no-newline), TicketExtractor (allowlist, branch source, multiple tickets), task input parser, stats queries over a seeded DB, streak calculation across time zones.
- **Integration:** create temp repos in tests (`git init`, scripted commits with fixed dates and authors), then run SyncEngine and assert DB contents. Cover incremental sync, a rebase that changes SHAs, branch deletion, and a new identity added.
- **Performance:** a fixture repo with 20k commits. The initial scan of a 12-month window should finish in under 10 s; an incremental sync after one commit in under 300 ms.
- **UI:** SwiftUI previews for every screen with a seeded in-memory DB; a few XCUITests for add repo → see commits → open diff → add task → export.

---

## 17. Milestones

Each phase ends in a usable app. Give Claude Code one milestone at a time.

### Phase 0 — Scaffold (½ day)
- Xcode project, folder structure, GRDB via SPM, Theme tokens, bundled fonts.
- App shell: sidebar + empty sections, number-key navigation.
- **Done when:** the app launches in the D style with working navigation.

### Phase 1 — Repos & commits (core)
- Onboarding: git check, identity detection, add repo(s), scan a folder for repos.
- GitClient + LogParser; initial scan; DB schema and migrations.
- Commits screen with day grouping and filters.
- **Done when:** adding 2–3 real repos lists all my commits correctly.

### Phase 2 — Commit detail & diff
- `git show` on demand, UnifiedDiffParser, file list, unified + split views, prev/next, open in editor, large-diff guard.
- **Done when:** any commit opens with an accurate diff in both views.

### Phase 3 — Live refresh
- SyncEngine incremental scans, ref cursors, rewrite detection, RepoWatcher (FSEvents), wake/launch/⌘R triggers, status line.
- **Done when:** committing in a terminal shows the commit within ~2 s, and a rebase doesn't create duplicates.

### Phase 4 — Tickets
- TicketExtractor, settings for pattern/allowlist, Tickets screen and ticket detail, manual linking, "No ticket" group.
- **Done when:** commits group under the right tickets with editable titles and status.

### Phase 5 — Tasks
- Task CRUD, list + board, inline input parsing, linking to tickets/commits, global quick-add hotkey, optional auto-complete suggestions.
- **Done when:** my task sheet can be fully replaced.

### Phase 6 — Overview & stats
- Stat tiles with comparison, weekly chart, timeline, streaks, project split, exclusions setting.
- **Done when:** the Overview matches design D with real data.

### Phase 7 — Reports
- Report builder, live Markdown preview, period notes, export .md / copy.
- **Done when:** a quarter's report can be produced in under a minute.

### Phase 8 — Polish
- ⌘K command palette, keyboard shortcuts everywhere, empty/error states, launch at login, app icon, signing + notarization, PDF export, menu bar extra.

### Later (explicitly deferred)
- Jira / Linear / GitHub / GitLab APIs: ticket titles and status, PRs opened, reviews given.
- AI summaries (local model via Ollama first, for privacy).
- Light theme, syntax highlighting, word-level diff.
- Monorepo path-based projects.
- Android companion widget (since I use an Android phone + Mac).

---

## 18. Open Questions

1. Default initial scan window: 12 months, or all history?
2. Should stats count commits by author date or commit date? (Plan assumes author date.)
3. Count weekends in streaks and "active days"?
4. Ticket title source until APIs exist: manual entry only, or also infer from the branch name?
5. Distribution: personal build only, or signed + notarized for others too?

---

## 19. Prompt to start in Claude Code

```
Read plan.md. Implement Phase 0 only: create the macOS SwiftUI Xcode project
"Worklog" (macOS 14+, Swift 6) with the folder structure in §14, add GRDB via SPM,
create Theme.swift with the Design D tokens from §2, bundle IBM Plex Sans/Mono,
and build the app shell (sidebar with Overview/Commits/Tickets/Tasks/Reports,
number-key navigation, empty placeholder views). Don't start Phase 1.
When done, summarise what you built and how to run it.
```

---

## Appendix A — UI Spec (Design D)

Match this spec pixel-for-pixel for v1. Values are in points (pt = CSS px at 1×).

### A.1 Window

- `WindowGroup` with `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unifiedCompact)`. The native traffic lights sit at the top-left of the sidebar; give them **16 pt top / 16 pt left** clearance (the mockup draws them at 12 pt size, 8 pt apart).
- Default size **1280 × 860**, minimum **1000 × 680**.
- Layout is a custom `HStack(spacing: 0)`: **Sidebar (210 pt) | 1 pt divider | Main (flexible)**. Don't use `NavigationSplitView`; it won't match the look.
- Dark appearance is forced for v1: `.preferredColorScheme(.dark)`.

### A.2 Color tokens

| Token | Hex | Used for |
|---|---|---|
| `bg` | `#0F1210` | Main area background, input wells |
| `sidebarBg` | `#0C0F0D` | Sidebar background |
| `surface` | `#141815` | Cards, search field, buttons (secondary) |
| `border` | `#222823` | Card borders, sidebar divider, diff header divider |
| `controlBorder` | `#2A322B` | Search field, segmented control, secondary buttons, git-graph line |
| `divider` | `#1D231E` | Row separators inside cards |
| `navSelectedBg` | `#1A201B` | Selected sidebar item |
| `segmentSelectedBg` | `#243027` | Selected segment (range switcher, unified/split) |
| `fileSelectedBg` | `#1F2A22` | Selected file in Commit Detail file list |
| `textPrimary` | `#E6ECE6` | Headings, body text |
| `textSecondary` | `#C7D2C8` | Nav items, context lines, secondary values |
| `textBody` | `#A9B5AA` | Commit body paragraph, related-commit text |
| `textMuted` | `#8E9C8F` | Labels, meta, counts, timestamps |
| `textDone` | `#7C897D` | Completed task text (with strikethrough) |
| `lineNumber` | `#5C6A5D` | Diff line numbers |
| `accent` | `#5EE89B` | Primary button, active states, additions, ticket IDs, cursor |
| `accentHover` | `#8DF2B9` | Link hover |
| `onAccent` | `#0B130E` | Text on accent (primary button, NEW badge) |
| `accentChipBg` | `#17251C` | Ticket chip background |
| `chartBar` | `#2C5A3E` | Non-peak bars |
| `chartDots` | `#252C26` | Dot grid behind chart |
| `sha` | `#F2C46D` | Commit SHAs; also the color for `mobile-app` |
| `deletion` | `#F28B82` | Deleted line counts, `−` signs |
| `info` | `#6BA6FF` | "In progress" ticket dot |
| `hunkText` | `#8FB8FF` | Diff hunk headers |
| `purple` | `#B9A4FF` | Third project color |
| `diffAddBg` | `rgba(94,232,155,0.10)` | Added line background |
| `diffAddText` | `#D9F5E4` | Added line text |
| `diffDelBg` | `rgba(242,139,130,0.11)` | Deleted line background |
| `diffDelText` | `#F8DAD7` | Deleted line text |
| `diffHunkBg` | `rgba(107,166,255,0.08)` | Hunk header row |
| `diffEmptyBg` | `rgba(255,255,255,0.02)` | Filler cell in split view |

**Project colors** (assigned in order when a repo is added, user can change): `#5EE89B`, `#F2C46D`, `#B9A4FF`, `#6BA6FF`, `#F28B82`, `#7DCFE0`.

**Ticket status dots:** done `accent`, review `sha` (amber), active `info` (blue).

### A.3 Typography

Fonts: **IBM Plex Sans** (UI) and **IBM Plex Mono** (data). Register both in Info.plist (`ATSApplicationFontsPath`).

| Style | Font | Size / weight | Extra |
|---|---|---|---|
| `pageTitle` (Overview greeting) | Plex Sans | 24 / Semibold | tracking −0.24 |
| `detailTitle` (commit subject) | Plex Sans | 20 / Semibold | tracking −0.2 |
| `cardTitle` | Plex Sans | 14 / Semibold | |
| `nav` | Plex Sans | 14 / Regular | |
| `body` | Plex Sans | 13 / Regular | Commit body: line height 1.5 |
| `bodyMedium` | Plex Sans | 13 / Medium | Commit subjects in timeline |
| `buttonPrimary` | Plex Sans | 13 / Semibold | |
| `logo` | Plex Mono | 16 / Semibold | |
| `statValue` | Plex Mono | 26 / Semibold | tracking −0.52 |
| `monoMeta` | Plex Mono | 12 / Regular | Meta rows, search placeholder |
| `monoMedium` | Plex Mono | 12 / Medium | Segments, secondary buttons, nav shortcut keys, file names |
| `monoLabel` | Plex Mono | 11 / Medium | Stat labels, `// section` labels, chips |
| `monoSmall` | Plex Mono | 11 / Regular | Timestamps, SHAs in timeline, repo sublines |
| `monoTiny` | Plex Mono | 10 / Regular | Chart values and week labels |
| `code` | Plex Mono | 12 / Regular | Diff lines, line height 1.7 (≈ 20 pt rows) |

### A.4 Spacing, radius, sizes

- **Main area padding:** top 22, sides 28, bottom 32. **Vertical gap between rows:** 18 (Overview), 16 (Commit Detail). **Gap between cards in a row:** 14. **Gap between stat tiles:** 12.
- **Card:** background `surface`, 1 pt `border`, radius **12**, padding **16 vertical × 18 horizontal**. Card header: title + muted meta on one baseline, 10 pt apart; 10–14 pt below to content.
- **Radii:** cards 12 · search field, primary/secondary buttons, add-repo button 10 · segmented container 10, segments 7 · nav items, file rows, back/prev/next buttons 8 · task input 9 · chips 5 · chart bars 3 (top corners only) · NEW badge 4.
- **Heights:** search field 42 · primary button 42 · segments 34 (container padding 3, gap 4) · nav item 36 · task row ≥ 42 · ticket row ≥ 44 · file row ≥ 44 · secondary buttons 36 · back button 32 · prev/next 34 × 34 · diff toggle segments 30.
- **Sidebar:** width 210, padding 16 top / 12 sides, sections 22 apart, `sidebarBg` with 1 pt `border` on the right.

### A.5 Components

Build these as reusable SwiftUI views in `Shared/`.

**`Logo`** — `~/` in `accent` + `worklog` in `textPrimary` (`logo` style) + a solid `accent` block cursor 8 × 17 pt. Optional: blink the cursor every 1.1 s, and respect Reduce Motion.

**`SectionLabel(text)`** — `// ` + lowercase text, `monoLabel`, `textMuted`. Example: `// repositories`, `// same ticket · PAY-218`.

**`SidebarNavItem(key, label, count?, selected)`** — height 36, horizontal padding 10, radius 8. A 14 pt-wide shortcut key (`monoMedium`, `accent` when selected, otherwise `textMuted`), 10 pt gap, label (`nav`; `textPrimary` selected / `textSecondary` otherwise), and an optional trailing count (`monoMeta`, `textMuted`). Selected background `navSelectedBg`. Items: 1 Overview · 2 Commits · 3 Tickets · 4 Tasks · 5 Reports.

**`RepoRow`** — padding 8 × 10, radius 8. Line 1: a 13 pt git-branch icon stroked in the project color + name (13 pt Sans). Line 2: indented 21 pt, `branch · N commits` in `monoSmall` `textMuted`. 2 pt between lines.

**`AddRepoButton`** — full width, height 44, 1 pt `controlBorder`, radius 10, `surface` background, `+ add repo` in `monoMedium` `textSecondary`. Pinned to the sidebar bottom.

**`CommandSearchField`** — height 42, padding 0 × 14, `surface`, 1 pt `controlBorder`, radius 10. Contents: `❯` in `accent`, 10 pt gap, placeholder "Search commits, tickets, tasks…" (`monoMeta`, `textMuted`), and a trailing `⌘K` keycap (11 pt mono, `textSecondary`, 1 pt `controlBorder`, radius 5, padding 1 × 6). Clicking it opens the command palette.

**`MonoSegmentedControl(options, selection)`** — container: `surface`, 1 pt `controlBorder`, radius 10, padding 3, gap 4. Segments: height 34 (30 in the diff header), padding 0 × 12, radius 7, `monoMedium`. Selected: `segmentSelectedBg` with `accent` text. Unselected: transparent with `textMuted` text. Range options are lowercase: `wk mo qtr yr`.

**`PrimaryButton`** — height 42, padding 0 × 16, `accent` background, `onAccent` text, `buttonPrimary`, radius 10, no border.

**`SecondaryMonoButton`** — height 36, padding 0 × 12, `bg` background, 1 pt `controlBorder`, radius 8, `monoMedium` `textSecondary`. Lowercase labels: `copy sha`, `open in editor`.

**`StatTile(label, value, note, noteColor)`** — card styling with padding 14 × 16, 6 pt spacing. Label (`monoLabel`, `textMuted`, lowercase), value (`statValue`), note (`monoMeta`, `accent` for ▲ changes, otherwise `textMuted`). Tiles sit in an adaptive grid, min width 180. The four tiles: `commits`, `tickets closed`, `lines` (value `+12.4k`, note `−5.1k removed`), `active days` (value `54/65`, note `streak · 12 days`).

**`TicketChip(key)`** — `monoLabel` in `accent`, background `accentChipBg`, padding 2 × 7, radius 5. Shows `—` when there's no ticket.

**`WeeklyBarChart`** — chart area height 150 with a **dot grid** behind it (1 pt dots in `chartDots`, 12 pt spacing). Bars are equal-width with 8 pt gaps, max bar height 110, top radius 3. The peak week is `accent`, others `chartBar`. Value labels above each bar (`monoTiny`; `accent` for the peak, `textMuted` otherwise). Week numbers below in a separate row (`monoTiny`, `textMuted`). Card header meta: `// peak W35 · 28`. Use Swift Charts `BarMark` with a custom background, or a hand-built `HStack`. Either is fine if it matches.

**`TaskInput`** — height 40, padding 0 × 12, `bg` background, 1 pt `controlBorder`, radius 9. A `+` label (14 pt mono semibold, `accent`), then a borderless text field (`monoMeta`, caret `accent`). Placeholder: "New task, end with PROJ-123 · Enter". Enter parses the input (§9.1) and adds the task.

**`TaskRow`** — min height 42, 1 pt `divider` bottom border, 12 pt spacing. A 16 pt checkbox tinted `accent`, title (13 pt Sans; `textPrimary`, or `textDone` + strikethrough when done), and a trailing `TicketChip`. The whole row toggles the task.

**`GitGraphRow(commit, isFirst, isLast)`** — two columns, 14 pt apart.
- Gutter, 12 pt wide: a 2 pt line in `controlBorder` above (10 pt tall; hidden on the first row), a **10 pt ring** (2 pt stroke in the project color, filled with `surface`), and a 2 pt line below that fills the remaining height (hidden on the last row).
- Content (padding 4 top / 12 bottom, 3 pt spacing). Line 1: subject (`bodyMedium`) with a right-aligned relative time (`monoSmall`, `textMuted`). Line 2, 10 pt gaps, all `monoSmall`: SHA in `sha` · ticket in `accent` · repo in `textMuted` · `+N` in `accent` and `−N` in `deletion`.
- Clicking the subject opens Commit Detail.

**`TicketRow`** — min height 44, 1 pt `divider` top border, 10 pt spacing: an 8 pt status dot, key (12 pt mono medium, `textSecondary`, fixed width 64), title (13 pt Sans, single line, truncated with an ellipsis), and a trailing `Nc` commit count (`monoSmall`, `textMuted`).

**`ChangedFileRow`** — min height 44, padding 8 × 10, radius 8. Line 1: file name (`monoMedium`; `accent` when selected, otherwise `textPrimary`, truncated). Line 2 (`monoSmall`): folder path in `textMuted`, then right-aligned `+N` in `accent` and `−N` in `deletion`. Selected background `fileSelectedBg`.

**`DiffLineRow` (unified)** — `code` style, no wrapping. Old line number (44 pt, right-aligned, 8 pt right padding, `lineNumber`) · new line number (same) · sign column 18 pt (`+` in `accent`, `−` in `deletion`) · text (padding-right 14).
- Addition: background `diffAddBg`, text `diffAddText`.
- Deletion: background `diffDelBg`, text `diffDelText`.
- Context: transparent background, `textSecondary` text.
- Hunk header: background `diffHunkBg`, text `hunkText`, no line numbers.

**`SplitDiffRow`** — two equal halves with a 1 pt `border` between them. Each half has a line number (40 pt) and text. The left half shows deletions and context; the right shows additions and context. Unpaired cells use `diffEmptyBg`. Minimum diff width before horizontal scrolling: 640 pt unified, 900 pt split.

**`NewBadge`** — `NEW` in 10 pt mono medium, `onAccent` on `accent`, padding 2 × 6, radius 4. Shown next to added files.

### A.6 Screen: Overview

```
┌──────────────┬─────────────────────────────────────────────────────────────────────┐
│ ● ● ●        │ [❯ Search commits, tickets, tasks…        ⌘K] [wk mo qtr yr] [Export report] │
│ ~/worklog▌   │                                                                     │
│              │ Good evening — here's your quarter   author: me · 3 repos           │
│ 1 Overview   │                                                                     │
│ 2 Commits 248│ ┌commits──┐ ┌tickets closed┐ ┌lines────┐ ┌active days┐              │
│ 3 Tickets 44 │ │ 248     │ │ 37           │ │ +12.4k  │ │ 54/65     │              │
│ 4 Tasks    4 │ │▲18% prev│ │▲6 vs prev    │ │−5.1k rm │ │streak · 12│              │
│ 5 Reports    │ └─────────┘ └──────────────┘ └─────────┘ └───────────┘              │
│              │ ┌Weekly commits // peak W35 · 28──┐ ┌Tasks  4 open─────────────┐     │
│ // repos     │ │ ⋅ ⋅ ▆ ⋅ █ ⋅ ▅ ⋅ ⋅ ▇ ⋅ ▆ ⋅ ▃      │ │ [+ New task …          ] │     │
│ ⑂ payments-api│ │ 27 28 29 … 39                  │ │ ☐ Write migration… PAY-218│     │
│   main · 112 │ └─────────────────────────────────┘ │ ☑ Fix flaky test   PAY-204│     │
│ ⑂ mobile-app │  (flex 3, min 440)                  └──────────(flex 2, min 320)┘     │
│ ⑂ admin-portal│ ┌Commit history        git log →──┐ ┌Tickets 37 done·4 review·3┐     │
│              │ │ ○ Add ledger_entries v2…   2h ago│ │ ● PAY-218 Ledger v2…   9c │     │
│              │ │ │ a41f9c2 PAY-218 payments +214−12│ │ ● ADM-37  Audit log…   7c │     │
│              │ │ ○ Theme tokens for…        5h ago│ │ ● MOB-88  Offline…    26c │     │
│ [+ add repo] │ └─────────────────────────────────┘ └──────────────────────────┘     │
└──────────────┴─────────────────────────────────────────────────────────────────────┘
```

- **Header row:** the search field grows (min 320), then the range segmented control, then the primary **Export report** button. 12 pt gaps; wraps on narrow windows.
- **Greeting line:** `Good evening — here's your <week|month|quarter|year>` (`pageTitle`; the greeting follows the time of day) + `author: me · N repos` (`monoMeta`, `textMuted`), baseline-aligned, 10 pt apart.
- **Stat tiles:** 4 across.
- **Row 2:** Weekly commits (flex 3, min 440) | Tasks (flex 2, min 320). The Tasks card shows its title + `N open`, the `TaskInput`, then up to 5–7 `TaskRow`s.
- **Row 3:** Commit history (flex 3) showing 5–10 `GitGraphRow`s, header link `git log →` (12 pt mono, `accent`) | Tickets (flex 2) with header meta `37 done · 4 review · 3 active` and 5 `TicketRow`s.
- Rows wrap their cards vertically when the window is narrower than the two minimums combined.

### A.7 Screen: Commit Detail

```
┌──────────────┬─────────────────────────────────────────────────────────────────────┐
│ ● ● ●        │ [← back] commits / payments-api / a41f9c2                  [↑] [↓] │
│ ~/worklog▌   │ ┌───────────────────────────────────────────────────────────────────┐│
│              │ │ Add ledger_entries v2 table and backfill job  [copy sha][open in…]││
│ 1 Overview   │ │ Creates the v2 schema alongside v1 and a batched job…             ││
│ 2 Commits 248│ │ sha a41f9c2  ticket PAY-218  branch feat/ledger-v2  Oct 27 · 19:42 ││
│ …            │ │ 4 files · +214 −12                                                ││
│              │ └───────────────────────────────────────────────────────────────────┘│
│ // same      │ ┌// changed files──┐ ┌src/ledger/LedgerRepository.kt   [unified|split]┐│
│ ticket·PAY-218│ │ 0042_ledger…sql  │ │ @@ -42,14 +42,19 @@ class LedgerRepository(   ││
│ a41f9c2 Add… │ │ LedgerRepository │ │ 42 42    private val db: Database,            ││
│ b7e1d40 Dual…│ │ BackfillLedger…  │ │ 43    −  private val clock: Clock             ││
│ 0d93c6a Flag…│ │ LedgerRepoTest   │ │    43 +  private val clock: Clock,            ││
│              │ └(flex 1, min 250)─┘ └(flex 4, min 560)──────────────────────────────┘│
└──────────────┴─────────────────────────────────────────────────────────────────────┘
```

- **Breadcrumb bar:** a `← back` button (height 32, 1 pt `controlBorder`, radius 8, `textSecondary`), then `commits / <repo> / <short sha>` in `monoMeta` `textMuted` (SHA in `sha`), with prev/next buttons (34 × 34) on the right.
- **Header card** (padding 18 × 20, 12 pt spacing): subject (`detailTitle`) and body (`body`, `textBody`, line height 1.5) on the left, `SecondaryMonoButton`s on the right. Meta row in `monoMeta` `textMuted`, 18 pt gaps: `sha` value in `sha` color, `ticket` value in `accent`, `branch` value in `textSecondary`, date `MMM d, yyyy · HH:mm`, `N files · +A −D`.
- **File list card** (flex 1, min 250, padding 10): `// changed files` label, then `ChangedFileRow`s with 2 pt spacing.
- **Diff card** (flex 4, min 560, padding 0, clipped). Header bar: padding 10 × 14, 1 pt `border` bottom, full file path (`monoMedium`), a `NewBadge` if the file was added, and the `MonoSegmentedControl` (`unified` / `split`) on the right. Body: rows per A.5 with 6 pt top/bottom padding, scrolling both ways.
- **Sidebar (this screen only):** below the nav, a `// same ticket · <KEY>` section with up to 6 lines, each a SHA (`monoSmall`, `sha`) + truncated subject (12 pt; the current commit in `textPrimary`, others in `textBody`).

### A.8 Screens not mocked up yet

Build Commits, Tickets, Tasks, Reports, Settings, the command palette and onboarding **from the A.5 components and A.2–A.4 tokens**, following §12 for content. Rules to keep them consistent:
- Every screen uses the same main padding and an optional top bar (search + context controls).
- Lists live inside cards; rows use `divider` separators and a minimum height of 42–44.
- Lowercase mono for labels, segments and secondary buttons; sentence case Sans for titles and content.
- Exactly one `PrimaryButton` per screen at most.
- **Command palette:** a centered 640 pt wide panel, `surface` background, 1 pt `controlBorder`, radius 12, shadow `black 40%, blur 30`. A large `❯` input (16 pt mono) on top, then grouped results under `// commits`, `// tickets`, `// tasks`, `// actions` labels. The highlighted row uses `navSelectedBg`.
- **Empty states:** centered `SectionLabel`-style mono text (e.g. `// no commits in this range`) plus one action button.

### A.9 Interaction details

- Hover: secondary buttons and rows lighten to `navSelectedBg`; links go to `accentHover`. Pointer cursor on clickable rows.
- Focus: 2 pt `accent` focus ring, offset 2, on all focusable controls.
- Animations: 150 ms ease-out for selection and hover changes; none for list content updates.
- Numbers: thousands separators (`12,410`); compact form in tiles (`+12.4k`); minus sign is `−` (U+2212), not a hyphen.
- Relative times: `2h ago`, `1d ago`, then `Oct 21` after 7 days.
