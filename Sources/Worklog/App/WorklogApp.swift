import AppKit
import SwiftUI
import WorklogCore

@main
struct WorklogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        FontLoader.register()
    }

    var body: some Scene {
        WindowGroup("Worklog", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 860)
        .commands { WorklogCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running via `swift run` (no bundle) still needs a regular, frontmost app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct WorklogCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { model.newTask() }.keyboardShortcut("n")
            Button("Add Repo…") { model.pickRepos() }.keyboardShortcut("o")
        }
        CommandGroup(after: .sidebar) {
            Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                .keyboardShortcut("0")
        }
        CommandMenu("Go") {
            ForEach(AppSection.allCases) { s in
                Button(s.label) { model.section = s }
                    .keyboardShortcut(KeyEquivalent(Character(s.key)), modifiers: .command)
            }
            Divider()
            Button("Command Palette") { model.palette.open() }.keyboardShortcut("k")
            Button("Refresh") { model.refresh() }.keyboardShortcut("r")
            Button("Export Report") { model.section = .reports }.keyboardShortcut("e")
        }
    }
}
