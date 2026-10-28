import AppKit
import WorklogCore

/// Dev aid: `WORKLOG_SNAPSHOT_DIR=/tmp/shots Worklog` renders each screen of the main window to PNG, then quits.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["WORKLOG_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for section in AppSection.allCases {
                model.section = section
                try? await Task.sleep(for: .seconds(1.2))
                capture(model, to: url.appendingPathComponent("\(section.rawValue)-\(section.label.lowercased()).png"))
            }
            let ids = (try? await model.db.writer.read { db in
                try Queries.commits(db, filter: CommitFilter(), limit: 20).map(\.id)
            }) ?? []
            if let first = ids.first {
                model.section = .commits
                model.openCommit(first, context: ids)
                try? await Task.sleep(for: .seconds(1.5))
                capture(model, to: url.appendingPathComponent("6-commit-unified.png"))
                model.diffMode = .split
                try? await Task.sleep(for: .seconds(1))
                capture(model, to: url.appendingPathComponent("7-commit-split.png"))
                model.diffMode = .unified
            }
            model.detail = nil
            model.section = .overview
            model.palette.open()
            try? await Task.sleep(for: .seconds(1))
            capture(model, to: url.appendingPathComponent("8-palette.png"))
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ model: AppModel, to url: URL) {
        guard let view = model.mainWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
