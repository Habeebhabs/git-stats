import SwiftUI
import WorklogCore

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var palette = model.palette
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .onTapGesture { palette.close() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("❯").font(.plexMono(16, .semibold)).foregroundStyle(Theme.accent)
                    TextField("", text: $palette.query, prompt: Text("Search commits, tickets, tasks, actions…").foregroundStyle(Theme.textMuted))
                        .textFieldStyle(.plain)
                        .font(.plexMono(16))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focused)
                    Keycap("esc")
                }
                .padding(.horizontal, 18)
                .frame(height: 56)
                .rowDivider()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(PaletteGroup.allCases, id: \.self) { group in
                                let rows = palette.items.enumerated().filter { $0.element.group == group }
                                if !rows.isEmpty {
                                    SectionLabel(group.rawValue).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                                    ForEach(rows, id: \.element.id) { index, item in
                                        row(item, highlighted: index == palette.selected)
                                            .id(item.id)
                                            .onTapGesture { palette.perform(item) }
                                    }
                                }
                            }
                            if palette.items.isEmpty {
                                EmptyState("nothing matches")
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: palette.selected) {
                        if palette.items.indices.contains(palette.selected) {
                            proxy.scrollTo(palette.items[palette.selected].id)
                        }
                    }
                }
            }
            .frame(width: 640)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 30)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
    }

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if let accent = item.accent {
                Text(accent)
                    .font(Theme.monoSmall)
                    .foregroundStyle(item.group == .commits ? Theme.sha : Theme.accent)
                    .frame(minWidth: 60, alignment: .leading)
            }
            Text(item.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail).font(Theme.monoSmall).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(highlighted ? Theme.navSelectedBg : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
