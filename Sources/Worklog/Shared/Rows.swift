import SwiftUI
import WorklogCore

struct SidebarNavItem: View {
    let key: String
    let label: String
    var count: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoverBackground(radius: 8, isSelected: selected) {
                HStack(spacing: 10) {
                    Text(key)
                        .font(Theme.monoMedium)
                        .foregroundStyle(selected ? Theme.accent : Theme.textMuted)
                        .frame(width: 14, alignment: .leading)
                    Text(label)
                        .font(Theme.nav)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Spacer(minLength: 4)
                    if let count, !count.isEmpty {
                        Text(count).font(Theme.monoMeta).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(count.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RepoRow: View {
    let repo: Repo
    let commitCount: Int
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoverBackground(radius: 8, isSelected: selected) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        BranchIcon()
                            .stroke(Color(hexString: repo.color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .frame(width: 13, height: 13)
                        Text(repo.name)
                            .font(.plexSans(13))
                            .foregroundStyle(repo.isActive ? Theme.textPrimary : Theme.textMuted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if repo.lastError != nil {
                            StatusDot(color: Theme.deletion, size: 6).help(repo.lastError ?? "")
                        }
                    }
                    Text("\(repo.defaultBranch ?? "—") · \(Fmt.thousands(commitCount)) commits")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, 21)
                        .lineLimit(1)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Timeline row: ring + line gutter, subject, sha · ticket · repo · +/−.
struct GitGraphRow: View {
    let commit: CommitRow
    let isFirst: Bool
    let isLast: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : Theme.controlBorder).frame(width: 2, height: 10)
                Circle()
                    .strokeBorder(Color(hexString: commit.repoColor), lineWidth: 2)
                    .background(Circle().fill(Theme.surface))
                    .frame(width: 10, height: 10)
                Rectangle().fill(isLast ? .clear : Theme.controlBorder).frame(width: 2).frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button(action: open) {
                        SubjectText(text: commit.subject)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Text(Fmt.relative(commit.authorDate)).font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                }
                HStack(spacing: 10) {
                    Text(commit.shortSha).foregroundStyle(Theme.sha)
                    if !commit.tickets.isEmpty {
                        Text(commit.tickets.joined(separator: " ")).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                    Text(commit.repoName).foregroundStyle(Theme.textMuted).lineLimit(1)
                    LineCounts(additions: commit.statAdditions, deletions: commit.statDeletions)
                }
                .font(Theme.monoSmall)
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct SubjectText: View {
        let text: String
        @State private var hovering = false
        var body: some View {
            Text(text)
                .font(Theme.bodyMedium)
                .foregroundStyle(hovering ? Theme.accentHover : Theme.textPrimary)
                .lineLimit(1)
                .onHover { hovering = $0 }
                .pointingHandCursor()
        }
    }
}

struct TicketRowView: View {
    let ticket: TicketSummary
    var selected = false
    var showLines = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoverBackground(radius: 6, isSelected: selected) {
                HStack(spacing: 10) {
                    StatusDot(color: Theme.ticketDot(ticket.status))
                    Text(ticket.key)
                        .font(.plexMono(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 64, alignment: .leading)
                        .lineLimit(1)
                        .fixedSize()
                    Text(ticket.displayTitle)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if showLines {
                        LineCounts(additions: ticket.additions, deletions: ticket.deletions, compact: true)
                    }
                    Text("\(ticket.commitCount)c").font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, selected ? 8 : 0)
            }
        }
        .buttonStyle(.plain)
        .rowDivider(.top)
        .accessibilityLabel("\(ticket.key), \(ticket.displayTitle), \(ticket.status.label), \(ticket.commitCount) commits")
    }
}

/// Checkbox row. The whole row toggles done.
struct TaskRowView: View {
    let row: TaskRow
    var showDetails = false
    let toggle: () -> Void

    var body: some View {
        let done = row.task.status == .done
        Button(action: toggle) {
            HStack(spacing: 12) {
                TaskCheckbox(status: row.task.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.task.title)
                        .font(Theme.body)
                        .foregroundStyle(done ? Theme.textDone : Theme.textPrimary)
                        .strikethrough(done, color: Theme.textDone)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if showDetails, let meta = metaLine {
                        Text(meta).font(Theme.monoSmall).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                TicketChip(key: row.ticketKey)
            }
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowDivider()
        .accessibilityLabel("\(row.task.title), \(row.task.status.label)")
    }

    private var metaLine: String? {
        var parts: [String] = []
        if row.task.status == .inProgress { parts.append("in progress") }
        if let due = row.task.dueDate { parts.append("due " + due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        parts += row.task.tagList.map { "#" + $0 }
        if row.ticketKey != nil, row.ticketCommitCount > 0 {
            parts.append("\(row.ticketCommitCount)c" + (row.ticketLastCommit.map { " · last " + Fmt.relative($0) } ?? ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct TaskCheckbox: View {
    let status: TaskStatus

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(status == .done ? Theme.accent : Theme.bg)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(status == .done ? Theme.accent : Theme.controlBorder, lineWidth: 1.5)
            switch status {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onAccent)
            case .inProgress:
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 8, height: 8)
            case .pending:
                EmptyView()
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// `+ New task, end with PROJ-123 · Enter`
struct TaskInput: View {
    let onSubmit: (String) -> Void
    var focusTrigger: Int = 0
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("+").font(.plexMono(14, .semibold)).foregroundStyle(Theme.accent)
            TextField("", text: $text, prompt: Text("New task, end with PROJ-123 · Enter").foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain)
                .font(Theme.monoMeta)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    onSubmit(t)
                    text = ""
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.controlBorder, lineWidth: 1))
        .onChange(of: focusTrigger) { focused = true }
        .accessibilityLabel("New task")
    }
}

/// Bars over a dot grid; the peak bar is accent.
struct WeeklyBarChart: View {
    let buckets: [ChartBucket]

    var body: some View {
        let peak = buckets.map(\.count).max() ?? 0
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: buckets.count > 20 ? 4 : 8) {
                ForEach(buckets) { b in
                    let isPeak = peak > 0 && b.count == peak
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text("\(b.count)")
                            .font(Theme.monoTiny)
                            .foregroundStyle(isPeak ? Theme.accent : Theme.textMuted)
                            .lineLimit(1)
                            .fixedSize()
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                            .fill(isPeak ? Theme.accent : Theme.chartBar)
                            .frame(height: peak > 0 ? max(CGFloat(b.count) / CGFloat(peak) * 110, b.count > 0 ? 2 : 0) : 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 2)
            .frame(height: 150)
            .background(DotGrid())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(buckets.map { "\($0.peakLabel): \($0.count)" }.joined(separator: ", "))

            HStack(spacing: buckets.count > 20 ? 4 : 8) {
                ForEach(buckets) { b in
                    Text(b.label)
                        .font(Theme.monoTiny)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 6
            while y < size.height {
                var x: CGFloat = 6
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(Theme.chartDots))
                    x += 12
                }
                y += 12
            }
        }
    }
}
