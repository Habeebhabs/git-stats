import AppKit
import CoreText
import SwiftUI
import WorklogCore

/// Design D tokens (plan.md Appendix A). Dark only for v1.
enum Theme {
    // A.2 colors
    static let bg = Color(hex: 0x0F1210)
    static let sidebarBg = Color(hex: 0x0C0F0D)
    static let surface = Color(hex: 0x141815)
    static let border = Color(hex: 0x222823)
    static let controlBorder = Color(hex: 0x2A322B)
    static let divider = Color(hex: 0x1D231E)
    static let navSelectedBg = Color(hex: 0x1A201B)
    static let segmentSelectedBg = Color(hex: 0x243027)
    static let fileSelectedBg = Color(hex: 0x1F2A22)
    static let textPrimary = Color(hex: 0xE6ECE6)
    static let textSecondary = Color(hex: 0xC7D2C8)
    static let textBody = Color(hex: 0xA9B5AA)
    static let textMuted = Color(hex: 0x8E9C8F)
    static let textDone = Color(hex: 0x7C897D)
    static let lineNumber = Color(hex: 0x5C6A5D)
    static let accent = Color(hex: 0x5EE89B)
    static let accentHover = Color(hex: 0x8DF2B9)
    static let onAccent = Color(hex: 0x0B130E)
    static let accentChipBg = Color(hex: 0x17251C)
    static let chartBar = Color(hex: 0x2C5A3E)
    static let chartDots = Color(hex: 0x252C26)
    static let sha = Color(hex: 0xF2C46D)
    static let deletion = Color(hex: 0xF28B82)
    static let info = Color(hex: 0x6BA6FF)
    static let hunkText = Color(hex: 0x8FB8FF)
    static let purple = Color(hex: 0xB9A4FF)
    static let diffAddBg = Color(hex: 0x5EE89B, alpha: 0.10)
    static let diffAddText = Color(hex: 0xD9F5E4)
    static let diffDelBg = Color(hex: 0xF28B82, alpha: 0.11)
    static let diffDelText = Color(hex: 0xF8DAD7)
    static let diffHunkBg = Color(hex: 0x6BA6FF, alpha: 0.08)
    static let diffEmptyBg = Color.white.opacity(0.02)

    // A.3 typography
    static let pageTitle = Font.plexSans(24, .semibold)
    static let detailTitle = Font.plexSans(20, .semibold)
    static let cardTitle = Font.plexSans(14, .semibold)
    static let nav = Font.plexSans(14)
    static let body = Font.plexSans(13)
    static let bodyMedium = Font.plexSans(13, .medium)
    static let buttonPrimary = Font.plexSans(13, .semibold)
    static let logo = Font.plexMono(16, .semibold)
    static let statValue = Font.plexMono(26, .semibold)
    static let monoMeta = Font.plexMono(12)
    static let monoMedium = Font.plexMono(12, .medium)
    static let monoLabel = Font.plexMono(11, .medium)
    static let monoSmall = Font.plexMono(11)
    static let monoTiny = Font.plexMono(10)
    static let code = Font.plexMono(12)

    // A.4 spacing
    static let mainPadding = EdgeInsets(top: 22, leading: 28, bottom: 32, trailing: 28)
    static let fast = Animation.easeOut(duration: 0.15)

    static func ticketDot(_ status: TicketStatus) -> Color {
        switch status {
        case .done: accent
        case .review: sha
        case .active: info
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// `#5EE89B`
    init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(s, radix: 16) ?? 0x5EE89B)
    }
}

extension Font {
    static func plexSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Sans", size: size).weight(weight)
    }

    static func plexMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Mono", size: size).weight(weight)
    }
}

/// Registers the bundled IBM Plex fonts (OFL) for this process.
enum FontLoader {
    static func register() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Fonts"))
            candidates.append(res.appendingPathComponent("Worklog_Worklog.bundle/Contents/Resources/Fonts"))
            candidates.append(res.appendingPathComponent("Worklog_Worklog.bundle/Fonts"))
        }
        // `swift run`: the resource bundle sits next to the executable
        let exeDir = Bundle.main.bundleURL
        candidates.append(exeDir.appendingPathComponent("Worklog_Worklog.bundle/Fonts"))
        candidates.append(exeDir.appendingPathComponent("Worklog_Worklog.bundle/Contents/Resources/Fonts"))

        guard let dir = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "otf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
