// Adapted from nwverse/persona apple/Persona/DesignSystem/Components.swift @ 3002eb3 (MIT).
import SwiftUI

nonisolated extension AgentState {
    var tone: StatusTone {
        switch self {
        case .needsYou: StatusPalette.needsYou
        case .working: StatusPalette.working
        case .unread: StatusPalette.unread
        case .idle, .unknown: StatusPalette.idle
        case .offline: StatusPalette.offline
        case .error: StatusTone(dot: Theme.danger, text: Theme.danger, tint: Theme.danger.opacity(0.1))
        }
    }
}

/// Persona's Working ring and Needs You breathing dot, with a state label for VoiceOver.
struct StatusDot: View {
    let state: AgentState
    var size: CGFloat = Theme.Size.dot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .foregroundStyle(state.tone.dot)
            .frame(width: size, height: size)
            .symbolEffect(.breathe, isActive: state == .needsYou && !reduceMotion)
            .overlay {
                if state == .working {
                    Circle().strokeBorder(state.tone.dot.opacity(0.45), lineWidth: Theme.Size.lineMedium)
                        .frame(width: size * 1.7, height: size * 1.7)
                }
            }
            .accessibilityLabel(state.label)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(verbatim: text)
            .font(Theme.Font.label)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xxs)
            .background(tint.opacity(0.1), in: Capsule())
    }
}

/// Persona's title/time layout gives the title another line when Dynamic Type needs it.
struct TimeBesideOrUnder<Words: View, Time: View>: View {
    @ViewBuilder var words: Words
    @ViewBuilder var time: Time
    var body: some View {
        BesideOrUnder(alignment: .firstTextBaseline, minShare: 0.7) {
            words
            time
        }
    }
}
