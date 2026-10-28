import GRDB
import SwiftUI
import UniformTypeIdentifiers
import WorklogCore

private enum TaskFilter: String, CaseIterable {
    case open, all, pending, progress = "in progress", done
}

private enum TaskLayout: String { case list, board }

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var rows: [TaskRow] = []
    @State private var filter: TaskFilter = .open
    @State private var layout: TaskLayout = .list
    @State private var tag: String?
    @State private var editing: Int64?

    private var allTags: [String] { Array(Set(rows.flatMap(\.task.tagList))).sorted() }

    private var visible: [TaskRow] {
        rows.filter { row in
            let statusOK: Bool = switch filter {
            case .open: row.task.status != .done
            case .all: true
            case .pending: row.task.status == .pending
            case .progress: row.task.status == .inProgress
            case .done: row.task.status == .done
            }
            return statusOK && (tag == nil || row.task.tagList.contains(tag!))
        }
    }

    private var dueThisWeek: [TaskRow] {
        let week = Calendar.worklog.dateInterval(of: .weekOfYear, for: Date())
        return rows.filter { row in
            guard row.task.status != .done, let due = row.task.dueDate, let week else { return false }
            return due < week.end
        }
        .sorted { ($0.task.dueDate ?? .distantFuture) < ($1.task.dueDate ?? .distantFuture) }
    }

    var body: some View {
        Screen(spacing: 16) {
            HStack(spacing: 12) {
                TaskInput(onSubmit: { model.addTask($0) }, focusTrigger: model.taskFocusTrigger)
                    .frame(minWidth: 300)
                MonoSegmentedControl(options: TaskFilter.allCases.map { ($0.rawValue, $0) }, selection: $filter)
                if !allTags.isEmpty {
                    Menu {
                        Button("All tags") { tag = nil }
                        ForEach(allTags, id: \.self) { t in Button("#" + t) { tag = t } }
                    } label: {
                        Text(tag.map { "#" + $0 } ?? "tags").font(Theme.monoMedium)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                MonoSegmentedControl(options: [("list", TaskLayout.list), ("board", TaskLayout.board)], selection: $layout)
            }
        } content: {
            if !dueThisWeek.isEmpty && layout == .list {
                Card(spacing: 6) {
                    CardHeader(title: "Due this week", meta: "\(dueThisWeek.count)")
                    VStack(spacing: 0) {
                        ForEach(dueThisWeek) { row in TaskRowView(row: row, showDetails: true) { model.toggleTask(row.task) } }
                    }
                }
            }
            if layout == .list {
                Card(spacing: 0) {
                    if visible.isEmpty {
                        EmptyState(rows.isEmpty ? "no tasks yet — type one above" : "nothing here")
                    }
                    ForEach(visible) { row in
                        EditableTaskRow(row: row, editing: $editing, onDelete: { model.deleteTask(row.task, undoManager: undoManager) })
                            .draggable(String(row.id))
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let id = Int64(raw), id != row.id else { return false }
                                model.moveTask(id, before: row.id)
                                return true
                            }
                    }
                }
                Text("tip: drag to reorder · click the box to complete · right-click for status, ticket and delete")
                    .font(Theme.monoSmall).foregroundStyle(Theme.textMuted)
            } else {
                board
            }
        }
        .task(id: model.revision) {
            rows = (try? await model.db.writer.read { db in try Queries.tasks(db) }) ?? []
        }
    }

    private var board: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                let column = rows.filter { $0.task.status == status && (tag == nil || $0.task.tagList.contains(tag!)) }
                Card(spacing: 8) {
                    CardHeader(title: status.label.capitalized, meta: "\(column.count)")
                    ForEach(column) { row in
                        BoardCard(row: row)
                            .draggable(String(row.id))
                    }
                    if column.isEmpty {
                        Text("drop here").font(Theme.monoSmall).foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let id = Int64(raw) else { return false }
                    model.setTaskStatus(id, status)
                    return true
                }
            }
        }
    }
}

private struct BoardCard: View {
    @Environment(AppModel.self) private var model
    let row: TaskRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.task.title).font(Theme.body).foregroundStyle(row.task.status == .done ? Theme.textDone : Theme.textPrimary)
            HStack(spacing: 6) {
                if row.ticketKey != nil { TicketChip(key: row.ticketKey) }
                ForEach(row.task.tagList, id: \.self) { Text("#" + $0).font(Theme.monoSmall).foregroundStyle(Theme.textMuted) }
                Spacer(minLength: 0)
                if let due = row.task.dueDate {
                    Text(due.formatted(.dateTime.month(.abbreviated).day())).font(Theme.monoSmall).foregroundStyle(Theme.sha)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.controlBorder, lineWidth: 1))
        .contextMenu {
            ForEach(TaskStatus.allCases, id: \.self) { s in Button(s.label) { model.setTaskStatus(row.id, s) } }
        }
    }
}

private struct EditableTaskRow: View {
    @Environment(AppModel.self) private var model
    let row: TaskRow
    @Binding var editing: Int64?
    let onDelete: () -> Void
    @State private var draft = ""
    @State private var ticketDraft = ""
    @State private var editingTicket = false
    @FocusState private var focused: Bool

    var body: some View {
        let done = row.task.status == .done
        HStack(spacing: 12) {
            Button { model.toggleTask(row.task) } label: { TaskCheckbox(status: row.task.status) }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Mark not done" : "Mark done")

            if editing == row.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit(commitEdit)
                    .onExitCommand { editing = nil }
                    .onAppear { draft = row.task.title; focused = true }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.task.title)
                        .font(Theme.body)
                        .foregroundStyle(done ? Theme.textDone : Theme.textPrimary)
                        .strikethrough(done, color: Theme.textDone)
                    if let meta = metaLine {
                        Text(meta).font(Theme.monoSmall).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
                .onTapGesture(count: 2) { editing = row.id }
            }
            Spacer(minLength: 8)
            if row.task.status == .inProgress {
                Text("in progress").font(Theme.monoSmall).foregroundStyle(Theme.info)
            }
            if editingTicket {
                TextField("", text: $ticketDraft, prompt: Text("KEY-1").foregroundStyle(Theme.textMuted))
                    .textFieldStyle(.plain)
                    .font(Theme.monoLabel)
                    .frame(width: 70)
                    .onSubmit {
                        model.setTaskTicket(row.id, key: ticketDraft)
                        editingTicket = false
                    }
            } else {
                Button {
                    if let id = row.task.ticketId { model.openTicket(id) } else { editingTicket = true }
                } label: { TicketChip(key: row.ticketKey) }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .rowDivider()
        .contextMenu {
            ForEach(TaskStatus.allCases, id: \.self) { s in
                Button((row.task.status == s ? "● " : "") + s.label) { model.setTaskStatus(row.id, s) }
            }
            Divider()
            Button("Edit title") { editing = row.id }
            Button(row.ticketKey == nil ? "Set ticket…" : "Change ticket…") { ticketDraft = row.ticketKey ?? ""; editingTicket = true }
            if row.ticketKey != nil { Button("Remove ticket") { model.setTaskTicket(row.id, key: nil) } }
            Menu("Due") {
                Button("Today") { setDue("today") }
                Button("Tomorrow") { setDue("tomorrow") }
                Button("Friday") { setDue("fri") }
                Button("Next Monday") { setDue("mon") }
                Button("No due date") { var t = row.task; t.dueDate = nil; model.saveTask(t) }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let due = row.task.dueDate { parts.append("due " + due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        parts += row.task.tagList.map { "#" + $0 }
        if let repo = row.repoName { parts.append(repo) }
        if row.ticketKey != nil, row.ticketCommitCount > 0 {
            parts.append("\(row.ticketCommitCount) commits" + (row.ticketLastCommit.map { " · last " + Fmt.relative($0) } ?? ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func setDue(_ word: String) {
        var t = row.task
        t.dueDate = TaskInputParser.parseDue(word, now: Date(), calendar: .worklog)
        model.saveTask(t)
    }

    private func commitEdit() {
        var t = row.task
        if let title = draft.nonEmpty, title != t.title {
            t.title = title
            model.saveTask(t)
        }
        editing = nil
    }
}
