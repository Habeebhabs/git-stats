import AppKit
import SwiftUI
import WorklogCore

enum PaletteGroup: String, CaseIterable {
    case commits, tickets, tasks, actions
}

struct PaletteItem: Identifiable {
    enum Action {
        case commit(Int64)
        case ticket(Int64)
        case task
        case addTask(String)
        case go(AppSection)
        case refresh
        case exportReport
        case addRepo
        case settings
    }

    let id: String
    let group: PaletteGroup
    let title: String
    var detail: String = ""
    var accent: String? = nil   // sha / key shown in color
    let action: Action
}

@MainActor @Observable
final class PaletteModel {
    @ObservationIgnored weak var model: AppModel?
    var isOpen = false
    var query = "" { didSet { search() } }
    var items: [PaletteItem] = []
    var selected = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func open() {
        query = ""
        isOpen = true
        search()
    }

    func close() {
        isOpen = false
        searchTask?.cancel()
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    func performSelected() {
        guard items.indices.contains(selected) else { return }
        perform(items[selected])
    }

    func perform(_ item: PaletteItem) {
        guard let model else { return }
        close()
        switch item.action {
        case let .commit(id): model.openCommit(id, context: items.compactMap { if case let .commit(c) = $0.action { c } else { nil } })
        case let .ticket(id): model.openTicket(id)
        case .task: model.section = .tasks
        case let .addTask(text): model.addTask(text); model.flash("task added")
        case let .go(section): model.section = section
        case .refresh: model.refresh()
        case .exportReport: model.section = .reports
        case .addRepo: model.pickRepos()
        case .settings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private func actions(for q: String) -> [PaletteItem] {
        var list: [PaletteItem] = []
        if !q.isEmpty { list.append(PaletteItem(id: "a-add", group: .actions, title: "Add task “\(q)”", action: .addTask(q))) }
        let fixed: [PaletteItem] = [
            PaletteItem(id: "a-refresh", group: .actions, title: "Refresh all repos", detail: "⌘R", action: .refresh),
            PaletteItem(id: "a-export", group: .actions, title: "Export report", detail: "⌘E", action: .exportReport),
            PaletteItem(id: "a-repo", group: .actions, title: "Add repo…", action: .addRepo),
            PaletteItem(id: "a-settings", group: .actions, title: "Settings", detail: "⌘,", action: .settings),
        ] + AppSection.allCases.map {
            PaletteItem(id: "a-go-\($0.rawValue)", group: .actions, title: "Go to \($0.label)", detail: $0.key, action: .go($0))
        }
        list += fixed.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
        return list
    }

    private func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let db = model?.db else { return }
        searchTask = Task {
            struct Found: Sendable { var commits: [CommitRow]; var tickets: [Ticket]; var tasks: [WorkTask] }
            let found: Found
            if q.isEmpty {
                found = (try? await db.writer.read { db in
                    Found(commits: try Queries.commits(db, filter: CommitFilter(), limit: 5), tickets: [], tasks: [])
                }) ?? Found(commits: [], tickets: [], tasks: [])
            } else {
                found = (try? await db.writer.read { db in
                    Found(commits: try Queries.searchCommits(db, text: q),
                          tickets: try Queries.searchTickets(db, text: q),
                          tasks: try Queries.searchTasks(db, text: q))
                }) ?? Found(commits: [], tickets: [], tasks: [])
            }
            guard !Task.isCancelled else { return }
            var list: [PaletteItem] = []
            list += found.commits.map {
                PaletteItem(id: "c\($0.id)", group: .commits, title: $0.subject, detail: $0.repoName, accent: $0.shortSha, action: .commit($0.id))
            }
            list += found.tickets.compactMap { t in
                t.id.map { PaletteItem(id: "t\($0)", group: .tickets, title: t.title ?? t.status.label, detail: t.status.label, accent: t.key, action: .ticket($0)) }
            }
            list += found.tasks.map {
                PaletteItem(id: "k\($0.id ?? 0)", group: .tasks, title: $0.title, detail: $0.status.label, action: .task)
            }
            list += actions(for: q)
            items = list
            selected = 0
        }
    }
}
