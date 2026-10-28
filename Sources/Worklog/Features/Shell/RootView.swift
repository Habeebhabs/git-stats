import AppKit
import SwiftUI
import WorklogCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    SidebarView()
                        .frame(width: 210)
                    Rectangle().fill(Theme.border).frame(width: 1)
                }
                MainArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.bg)

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(Theme.monoMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlBorder, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 12)
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if model.palette.isOpen {
                CommandPaletteView()
            }
            if model.showOnboarding {
                OnboardingView()
            }
        }
        .ignoresSafeArea()
        .background(WindowAccessor { window in
            model.mainWindow = window
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Theme.bg)
        })
        .animation(Theme.fast, value: model.toast)
    }
}

private struct MainArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let nav = model.detail {
                CommitDetailView(nav: nav)
                    .id(nav.current)
            } else {
                switch model.section {
                case .overview: OverviewView()
                case .commits: CommitsView()
                case .tickets: TicketsView()
                case .tasks: TasksView()
                case .reports: ReportsView()
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = model.dbError {
                Text(error).font(Theme.monoSmall).foregroundStyle(Theme.deletion).padding(6)
            }
        }
    }
}

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Common screen scaffold: main padding + optional top bar + scrolling content.
struct Screen<Bar: View, Content: View>: View {
    var scrolls = true
    var spacing: CGFloat = 18
    @ViewBuilder var bar: Bar
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            bar
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: spacing) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Theme.mainPadding.bottom)
                }
                .scrollIndicators(.automatic)
            } else {
                content
                    .padding(.bottom, Theme.mainPadding.bottom)
            }
        }
        .padding(.top, Theme.mainPadding.top)
        .padding(.horizontal, Theme.mainPadding.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
