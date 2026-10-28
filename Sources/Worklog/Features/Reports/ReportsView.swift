import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers
import WorklogCore

struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var preset: ReportPreset = .thisQuarter
    @State private var customStart = Calendar.worklog.date(byAdding: .month, value: -3, to: Date())!
    @State private var customEnd = Date()
    @State private var repoIds: Set<Int64> = []
    @State private var sections: Set<ReportSection> = [.summary, .tickets, .completedTasks, .notes]
    @State private var grouping: ReportGrouping = .projectTicket
    @State private var notes = ""
    @State private var loadedNoteKey = ""
    @State private var markdown = ""
    @State private var saveTask: Task<Void, Never>?

    private var interval: DateInterval {
        if let i = preset.interval() { return i }
        let cal = Calendar.worklog
        let start = cal.startOfDay(for: min(customStart, customEnd))
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd)))!
        return DateInterval(start: start, end: end)
    }

    private var reloadKey: String {
        "\(model.revision)|\(interval.start.timeIntervalSince1970)|\(interval.end.timeIntervalSince1970)|\(repoIds.sorted())|\(sections.map(\.rawValue).sorted())|\(grouping.rawValue)|\(notes.hashValue)"
    }

    var body: some View {
        Screen(scrolls: false, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report · \(ReportBuilder.title(for: interval))").font(Theme.pageTitle).tracking(-0.24).foregroundStyle(Theme.textPrimary)
                    Text(interval.label).font(Theme.monoMeta).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("copy") { model.copy(markdown, message: "report copied") }
                    .buttonStyle(SecondaryMonoButtonStyle())
                Button("save pdf") { savePDF() }
                    .buttonStyle(SecondaryMonoButtonStyle())
                Button("Export .md") { saveMarkdown() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } content: {
            FlexRow {
                builder.flex(2, min: 320)
                preview.flex(3, min: 460)
            }
            .frame(maxHeight: .infinity)
        }
        .task(id: reloadKey) { await build() }
        .task(id: interval.noteKey) { await loadNotes() }
    }

    // MARK: Builder

    private var builder: some View {
        Card(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("range")
                        FlowChips(items: ReportPreset.allCases, label: \.label, selected: { $0 == preset }) { preset = $0 }
                        if preset == .custom {
                            HStack {
                                DatePicker("", selection: $customStart, displayedComponents: .date).labelsHidden()
                                Text("→").foregroundStyle(Theme.textMuted)
                                DatePicker("", selection: $customEnd, displayedComponents: .date).labelsHidden()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("projects")
                        CheckRow(label: "all projects", isOn: repoIds.isEmpty) { repoIds = [] }
                        ForEach(model.repos) { repo in
                            CheckRow(label: repo.name, color: Color(hexString: repo.color), isOn: repoIds.contains(repo.id ?? -1)) {
                                guard let id = repo.id else { return }
                                if repoIds.contains(id) { repoIds.remove(id) } else { repoIds.insert(id) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("sections")
                        ForEach(ReportSection.allCases) { s in
                            CheckRow(label: s.label, isOn: sections.contains(s)) {
                                if sections.contains(s) { sections.remove(s) } else { sections.insert(s) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("group by")
                        MonoSegmentedControl(options: ReportGrouping.allCases.map { ($0.label, $0) }, selection: $grouping, height: 30, background: Theme.bg)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("notes for \(ReportBuilder.title(for: interval))")
                        TextEditor(text: $notes)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 120)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.controlBorder, lineWidth: 1))
                            .onChange(of: notes) { scheduleNoteSave() }
                    }
                }
            }
        }
    }

    private var preview: some View {
        Card(spacing: 10) {
            CardHeader(title: "Preview", meta: "markdown · \(markdown.split(separator: "\n").count) lines")
            ScrollView {
                Text(markdown)
                    .font(Theme.code)
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Data

    private func build() async {
        let interval = self.interval, ids = repoIds, notes = self.notes
        let sections = self.sections, grouping = self.grouping
        let countWeekends = model.settings.countWeekends
        let md = try? await model.db.writer.read { db in
            let data = try ReportBuilder.load(db, interval: interval, repoIds: ids, notes: notes, countWeekends: countWeekends)
            return ReportBuilder.markdown(data, sections: sections, grouping: grouping)
        }
        markdown = md ?? ""
    }

    private func loadNotes() async {
        let key = interval.noteKey
        notes = (try? await model.db.writer.read { db in try Mutations.periodNote(key: key, db: db) }) ?? ""
        loadedNoteKey = key
    }

    private func scheduleNoteSave() {
        let key = loadedNoteKey, text = notes
        guard key == interval.noteKey else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            _ = try? await model.db.writer.write { db in try Mutations.savePeriodNote(key: key, text: text, db: db) }
        }
    }

    private var fileStem: String {
        "work-summary-" + ReportBuilder.title(for: interval).lowercased().replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "–", with: "").replacingOccurrences(of: ",", with: "")
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileStem + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            model.flash("saved \(url.lastPathComponent)")
        } catch {
            model.flash("couldn't save: \(error.localizedDescription)")
        }
    }

    /// Renders the Markdown as rich text on letter-size pages.
    private func savePDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileStem + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let attributed = ReportPDF.attributed(markdown)
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 54; printInfo.bottomMargin = 54; printInfo.leftMargin = 54; printInfo.rightMargin = 54
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 792 - 108))
        textView.textStorage?.setAttributedString(attributed)
        textView.backgroundColor = .white
        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if op.run() { model.flash("saved \(url.lastPathComponent)") }
    }
}

enum ReportPDF {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont(name: "IBMPlexSans", size: 11) ?? NSFont.systemFont(ofSize: 11)
        func font(_ size: CGFloat, bold: Bool) -> NSFont {
            let base = NSFont(name: bold ? "IBMPlexSans-SemiBold" : "IBMPlexSans", size: size)
            return base ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            var attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.black]
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 3
            if line.hasPrefix("# ") { line.removeFirst(2); attrs[.font] = font(18, bold: true); para.paragraphSpacing = 10 }
            else if line.hasPrefix("## ") { line.removeFirst(3); attrs[.font] = font(14, bold: true); para.paragraphSpacingBefore = 10; para.paragraphSpacing = 6 }
            else if line.hasPrefix("### ") { line.removeFirst(4); attrs[.font] = font(12, bold: true); para.paragraphSpacingBefore = 6 }
            else if line.hasPrefix("- ") { line = "•  " + line.dropFirst(2); para.headIndent = 14 }
            if line.hasPrefix("**") && line.hasSuffix("**") { line = String(line.dropFirst(2).dropLast(2)); attrs[.font] = font(11, bold: true) }
            line = line.replacingOccurrences(of: "_", with: "")
            attrs[.paragraphStyle] = para
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        return out
    }
}

// MARK: - Small controls

struct CheckRow: View {
    let label: String
    var color: Color? = nil
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                TaskCheckbox(status: isOn ? .done : .pending)
                if let color { StatusDot(color: color, size: 7) }
                Text(label).font(Theme.body).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Wrapping row of mono chips (single choice).
struct FlowChips<Item: Hashable>: View {
    let items: [Item]
    let label: KeyPath<Item, String>
    let selected: (Item) -> Bool
    let pick: (Item) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                let on = selected(item)
                Button { pick(item) } label: {
                    Text(item[keyPath: label])
                        .font(Theme.monoMedium)
                        .foregroundStyle(on ? Theme.accent : Theme.textMuted)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(on ? Theme.segmentSelectedBg : Theme.bg, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? .clear : Theme.controlBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
