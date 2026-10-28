import SwiftUI
import WorklogCore

private let rowHeight: CGFloat = 20

private enum UnifiedItem: Identifiable {
    case header(Int, String)
    case line(Int, DiffLine)

    var id: Int {
        switch self {
        case let .header(i, _), let .line(i, _): i
        }
    }
}

struct UnifiedDiffView: View {
    let diff: FileDiff
    private let items: [UnifiedItem]

    init(diff: FileDiff) {
        self.diff = diff
        var items: [UnifiedItem] = []
        var i = 0
        for hunk in diff.hunks {
            items.append(.header(i, hunk.header)); i += 1
            for line in hunk.lines { items.append(.line(i, line)); i += 1 }
        }
        self.items = items
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case let .header(_, text): HunkHeaderRow(text: text)
                        case let .line(_, line): UnifiedLineRow(line: line)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: max(640, geo.size.width), alignment: .leading)
            }
        }
    }
}

private struct HunkHeaderRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.code)
            .foregroundStyle(Theme.hunkText)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .background(Theme.diffHunkBg)
    }
}

private struct UnifiedLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            LineNumber(line.oldNo, width: 44)
            LineNumber(line.newNo, width: 44)
            Text(sign)
                .foregroundStyle(signColor)
                .frame(width: 18, alignment: .leading)
            Text(line.kind == .noNewline ? "\\ " + line.text : line.text)
                .foregroundStyle(textColor)
                .italic(line.kind == .noNewline)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 14)
        }
        .font(Theme.code)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .background(background)
    }

    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: Fmt.minus
        case .context, .noNewline: " "
        }
    }
    private var signColor: Color { line.kind == .addition ? Theme.accent : Theme.deletion }
    private var textColor: Color {
        switch line.kind {
        case .addition: Theme.diffAddText
        case .deletion: Theme.diffDelText
        case .context: Theme.textSecondary
        case .noNewline: Theme.textMuted
        }
    }
    private var background: Color {
        switch line.kind {
        case .addition: Theme.diffAddBg
        case .deletion: Theme.diffDelBg
        case .context, .noNewline: .clear
        }
    }
}

private struct LineNumber: View {
    let number: Int?
    let width: CGFloat
    init(_ number: Int?, width: CGFloat) {
        self.number = number
        self.width = width
    }

    var body: some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(Theme.lineNumber)
            .frame(width: width - 8, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

// MARK: Split

private enum SplitItem: Identifiable {
    case header(Int, String)
    case row(Int, SplitRow)

    var id: Int {
        switch self {
        case let .header(i, _), let .row(i, _): i
        }
    }
}

struct SplitDiffView: View {
    let diff: FileDiff
    private let items: [SplitItem]

    init(diff: FileDiff) {
        self.diff = diff
        var items: [SplitItem] = []
        var i = 0
        for hunk in diff.hunks {
            items.append(.header(i, hunk.header)); i += 1
            for row in SplitDiff.rows(for: hunk) { items.append(.row(i, row)); i += 1 }
        }
        self.items = items
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(900, geo.size.width)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case let .header(_, text): HunkHeaderRow(text: text)
                        case let .row(_, row):
                            HStack(spacing: 0) {
                                SplitCell(line: row.left, side: .left).frame(width: (width - 1) / 2)
                                Rectangle().fill(Theme.border).frame(width: 1)
                                SplitCell(line: row.right, side: .right).frame(width: (width - 1) / 2)
                            }
                            .frame(height: rowHeight)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(width: width, alignment: .leading)
            }
        }
    }
}

private struct SplitCell: View {
    enum Side { case left, right }
    let line: DiffLine?
    let side: Side

    var body: some View {
        HStack(spacing: 0) {
            if let line {
                LineNumber(side == .left ? line.oldNo : line.newNo, width: 40)
                Text(line.text)
                    .foregroundStyle(textColor(line))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, 10)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(Theme.code)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
    }

    private func textColor(_ line: DiffLine) -> Color {
        switch line.kind {
        case .addition: Theme.diffAddText
        case .deletion: Theme.diffDelText
        default: Theme.textSecondary
        }
    }

    private var background: Color {
        guard let line else { return Theme.diffEmptyBg }
        switch line.kind {
        case .addition: return Theme.diffAddBg
        case .deletion: return Theme.diffDelBg
        default: return .clear
        }
    }
}
