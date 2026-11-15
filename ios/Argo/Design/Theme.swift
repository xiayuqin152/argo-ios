// Adapted from nwverse/persona apple/Shared/Design/Theme.swift @ 3002eb387c65fe471a75b03586e89bd49e20f4a3 (MIT).
// Argo keeps Persona's iOS Liquid Glass type scale, spacing, roles and shell surfaces.
import BeautifulUI
import SwiftUI
import UIKit

nonisolated enum Theme {
    static let accent = Palette.systemBlue
    static let brand = Palette.systemBlue
    static let danger = Color(light: 0xD93A3A, dark: 0xFF5F57)
    static let positive = Color(light: 0x248A3D, dark: 0x30D158)
    static let cautionText = Color(light: 0xB35400, dark: 0xFF9F0A)
    static let ai = Color(light: 0x5B4FD6, dark: 0x9C94FF)
    static let busy = StatusPalette.working.dot
    static let pageBackground = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let cardStroke = Color.primary.opacity(0.08)
    static let primaryText = Color(light: 0x1C1C1E, dark: 0xF2F2F7)
    static let codeBackground = Color(light: 0xF3F1EC, dark: 0x1C1D21)
    static let codeBar = Color(light: 0xE8E5DE, dark: 0x27282D)
    static let userBubble = Color(light: 0xDCEAFF, dark: 0x1D3557)
    static let caution = Color(light: 0xF08A00, dark: 0xFF9F0A)
    static let userBubbleText = Color.primary

    enum Radius {
        static let thumbnail: CGFloat = 3
        static let badge: CGFloat = 6
        static let control: CGFloat = 10
        static let card: CGFloat = 14
        static let bubble: CGFloat = 20
        static let panel: CGFloat = 22
        static let page: CGFloat = 55
    }
    enum Space {
        static let flush: CGFloat = 0
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let page = l
    }
    enum Fill {
        static let well = Color(uiColor: .quaternarySystemFill)
        static let chip = Color(uiColor: .tertiarySystemFill)
        static let pressed = Color(uiColor: .secondarySystemFill)
    }
    enum Font {
        static let display = SwiftUI.Font.title.bold()
        static let title = SwiftUI.Font.title2.weight(.semibold)
        static let heading = SwiftUI.Font.headline
        static let body = SwiftUI.Font.body
        static let secondary = SwiftUI.Font.subheadline
        static let caption = SwiftUI.Font.footnote
        static let sectionHeader = SwiftUI.Font.footnote.weight(.semibold)
        static let label = SwiftUI.Font.caption
        static let code = SwiftUI.Font.footnote.monospaced()
        static let bodyStrong = body.weight(.semibold)
        static let bodyHeavy = body.weight(.bold)
        static let secondaryStrong = secondary.weight(.semibold)
        static let secondaryMedium = secondary.weight(.medium)
        static let captionStrong = caption.weight(.semibold)
        static let captionMedium = caption.weight(.medium)
        static let labelStrong = label.weight(.semibold)
        static let labelHeavy = label.weight(.bold)
    }
    enum Size {
        static let hairline: CGFloat = 0.5
        static let line: CGFloat = 1
        static let lineMedium: CGFloat = 1.5
        static let rule: CGFloat = 2
        static let dot: CGFloat = 8
        static let dotS: CGFloat = 7
        static let dotXL: CGFloat = 10
        static let markS: CGFloat = 14
        static let markL: CGFloat = 17
        static let icon: CGFloat = 24
        static let wellS: CGFloat = 30
        static let wellL: CGFloat = 36
        static let tapTarget: CGFloat = 44
        static let readable: CGFloat = 560
        static let sidebarMin: CGFloat = 340
        static let sidebar: CGFloat = 400
        static let sidebarMax: CGFloat = 480
        static let splitPageMin: CGFloat = 400
    }
    enum Level {
        case body, secondary, caption, code
        var extraLeading: CGFloat {
            switch self {
            case .body: (1.45 - 1.19) * 17
            case .secondary: (1.4 - 1.19) * 15
            case .caption, .code: (1.35 - 1.19) * 13
            }
        }
    }
    enum Motion {
        static let state = Animation.snappy(duration: 0.25)
        static let layout = Animation.smooth(duration: 0.3)
        static let standard = state
        static let composerGrow = Animation.easeInOut(duration: 0.1)
        static let composerPressScale: CGFloat = 0.75
        static let composerPress = Animation.easeOut(duration: 0.4)
        static let composerRelease = Animation.timingCurve(0.38, 0.7, 0.125, 1, duration: 0.25)
        static let drawer = Animation.interpolatingSpring(duration: 0.32, bounce: 0)
    }
    enum Shell {
        static let segment = Color(light: 0xE6E6E6, dark: 0x3A3A3C)
        static let composer = Color(light: 0xFFFFFF, dark: 0x1F1F21)
        static let composerStroke = Color(light: 0xE3E3E3, dark: 0x3A3A3C)
        static let ink = Color(light: 0x0D0D0D, dark: 0xF2F2F2)
        static let inkText = Color(light: 0xFFFFFF, dark: 0x0D0D0D)
        static let drawer = Color(light: 0xF9F9F9, dark: 0x171717)
        static let composerRadius: CGFloat = 32
        static let composerPhoneMaximumLines = 6
    }

    // Persona Theme.Attach values retained for the two-tab photo/file panel.
    enum Attach {
        static let dim = 0.25
        static let gridSpacing: CGFloat = 1
        static let badge: CGFloat = 29
        static let badgeInset: CGFloat = 3
        static let badgeRing: CGFloat = 1.5
        static let barWidth: CGFloat = 160
        static let barHeight: CGFloat = 62
        static let barLensInset: CGFloat = 3
        static let tileHeight: CGFloat = 64
        static let cardWidth: CGFloat = 240
    }

    enum FilterCapsule {
        static let separatorHeight: CGFloat = 22
        static let selection = Theme.accent.opacity(0.12)
    }

    /// Persona's bridge scales desktop BeautifulUI components up for a phone.
    static var beautifulUI: BUITheme {
        var theme = BUITheme.standard
        theme.typeScale = 1.2
        theme.entrances = false
        theme.strings.expanded = L10n.text("Expanded")
        theme.strings.collapsed = L10n.text("Collapsed")
        theme.strings.send = L10n.text("Send")
        return theme
    }
}
