import SwiftUI
import WorklogCore

// MARK: - Basics

struct Logo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorOn = true

    var body: some View {
        HStack(spacing: 0) {
            Text("~/").foregroundStyle(Theme.accent)
            Text("worklog").foregroundStyle(Theme.textPrimary)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 8, height: 17)
                .opacity(cursorOn ? 1 : 0)
                .padding(.leading, 8)
        }
        .font(Theme.logo)
        .accessibilityLabel("Worklog")
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.1))
                cursorOn.toggle()
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text("// " + text.lowercased())
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.textMuted)
    }
}

/// Card: surface, 1pt border, radius 12, padding 16 × 18.
struct Card<Content: View>: View {
    var padding = EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    var meta: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Theme.cardTitle).foregroundStyle(Theme.textPrimary)
            if let meta { Text(meta).font(Theme.monoSmall).foregroundStyle(Theme.textMuted).lineLimit(1) }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, meta: String? = nil) {
        self.init(title: title, meta: meta) { EmptyView() }
    }
}

struct TicketChip: View {
    let key: String?

    var body: some View {
        Text(key ?? "—")
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.accentChipBg, in: RoundedRectangle(cornerRadius: 5))
            .lineLimit(1)
            .fixedSize()
    }
}

struct NewBadge: View {
    var text = "NEW"
    var body: some View {
        Text(text)
            .font(.plexMono(10, .medium))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// `+214 −12`
struct LineCounts: View {
    let additions: Int
    let deletions: Int
    var font = Theme.monoSmall
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text(Fmt.plus(additions, compact: compact)).foregroundStyle(Theme.accent)
            Text(Fmt.minus(deletions, compact: compact)).foregroundStyle(Theme.deletion)
        }
        .font(font)
        .fixedSize()
    }
}

// MARK: - Buttons

/// Dims disabled custom-styled buttons.
private struct EnabledDim: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.4) }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.buttonPrimary)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .modifier(EnabledDim())
    }
}

struct SecondaryMonoButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    var background = Theme.bg

    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(base: background, radius: 8) {
            configuration.label
                .font(Theme.monoMedium)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: height)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.8 : 1)
        .modifier(EnabledDim())
    }
}

/// Square icon button (prev/next, 34 × 34).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        HoverBackground(base: Theme.surface, radius: 8) {
            configuration.label
                .font(Theme.monoMedium)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.8 : 1)
        .modifier(EnabledDim())
    }
}

/// Plain mono link (`git log →`).
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration)
    }

    private struct LinkLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.monoMeta)
                .foregroundStyle(hovering ? Theme.accentHover : Theme.accent)
                .onHover { hovering = $0 }
                .pointingHandCursor()
        }
    }
}

/// Lightens to `navSelectedBg` on hover.
struct HoverBackground<Content: View>: View {
    var base: Color = .clear
    var hover: Color = Theme.navSelectedBg
    var radius: CGFloat = 8
    var isSelected = false
    var selected: Color = Theme.navSelectedBg
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .background(isSelected ? selected : (hovering ? hover : base), in: RoundedRectangle(cornerRadius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { h in withAnimation(Theme.fast) { hovering = h } }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    func accentFocusRing() -> some View {
        focusEffectDisabled()
    }

    /// Divider line at the top or bottom of a row.
    func rowDivider(_ edge: VerticalEdge = .bottom) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

// MARK: - Segmented control

struct MonoSegmentedControl<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    var height: CGFloat = 34
    var background = Theme.surface

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let isOn = option.value == selection
                Button {
                    withAnimation(Theme.fast) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(Theme.monoMedium)
                        .foregroundStyle(isOn ? Theme.accent : Theme.textMuted)
                        .padding(.horizontal, 12)
                        .frame(height: height)
                        .background(isOn ? Theme.segmentSelectedBg : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlBorder, lineWidth: 1))
        .fixedSize()
    }
}

// MARK: - Search field

/// Button that looks like the search field and opens the command palette.
struct CommandSearchField: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("❯").foregroundStyle(Theme.accent)
                Text("Search commits, tickets, tasks…").foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                Keycap("⌘K")
            }
            .font(Theme.monoMeta)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search commits, tickets, tasks")
    }
}

struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.plexMono(11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.controlBorder, lineWidth: 1))
    }
}

/// Real text input styled like the search field.
struct MonoSearchInput: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("❯").foregroundStyle(Theme.accent)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: { Text("×").foregroundStyle(Theme.textMuted) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(Theme.monoMeta)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .frame(minWidth: 220, maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlBorder, lineWidth: 1))
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let label: String
    let value: String
    let note: String
    var noteIsUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.lowercased()).font(Theme.monoLabel).foregroundStyle(Theme.textMuted)
            Text(value).font(Theme.statValue).tracking(-0.52).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(Theme.monoMeta).foregroundStyle(noteIsUp ? Theme.accent : Theme.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

struct EmptyState<Action: View>: View {
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 14) {
            SectionLabel(message)
            action
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, 20)
    }
}

extension EmptyState where Action == EmptyView {
    init(_ message: String) {
        self.init(message: message) { EmptyView() }
    }
}

// MARK: - Branch icon (from the mockup's SVG)

struct BranchIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        for (x, y) in [(6.0, 5.0), (6.0, 19.0), (18.0, 9.0)] {
            path.addEllipse(in: CGRect(x: rect.minX + (x - 2.5) * s, y: rect.minY + (y - 2.5) * s, width: 5 * s, height: 5 * s))
        }
        path.move(to: p(6, 7.5))
        path.addLine(to: p(6, 16.5))
        path.move(to: p(18, 11.5))
        path.addCurve(to: p(7, 17), control1: p(18, 15.5), control2: p(12, 14.5))
        return path
    }
}

// MARK: - Flexible row (CSS flex-wrap with grow factors)

private struct FlexKey: LayoutValueKey {
    static let defaultValue: (grow: CGFloat, min: CGFloat) = (1, 0)
}

extension View {
    /// Grow factor and min width inside a `FlexRow`.
    func flex(_ grow: CGFloat, min: CGFloat) -> some View {
        layoutValue(key: FlexKey.self, value: (grow, min))
    }
}

/// Lays children out side by side, sharing width by grow factor; stacks them when their minimum widths don't fit.
struct FlexRow: Layout {
    var spacing: CGFloat = 14

    private func widths(_ subviews: Subviews, total: CGFloat) -> [CGFloat]? {
        let specs = subviews.map { $0[FlexKey.self] }
        let available = total - spacing * CGFloat(max(subviews.count - 1, 0))
        let minSum = specs.reduce(0) { $0 + $1.min }
        guard minSum <= available else { return nil }
        let growSum = max(specs.reduce(0) { $0 + $1.grow }, 0.0001)
        let extra = available - minSum
        // Distribute like flex-basis = min, flex-grow = grow
        return specs.map { $0.min + extra * $0.grow / growSum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 1000
        if let w = widths(subviews, total: total) {
            // Side by side: fill a finite proposed height (cards stretch), otherwise hug the tallest child.
            if let ph = proposal.height, ph.isFinite, ph > 0 { return CGSize(width: total, height: ph) }
            let h = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            return CGSize(width: total, height: h)
        }
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: total, height: nil)).height }
        return CGSize(width: total, height: h.reduce(0, +) + spacing * CGFloat(max(h.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let w = widths(subviews, total: bounds.width) {
            var x = bounds.minX
            for (sub, width) in zip(subviews, w) {
                sub.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for sub in subviews {
                let h = sub.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                sub.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
        }
    }
}
