// Adapted from nwverse/persona apple/Persona/DesignSystem/ComposerButtons.swift @ 3002eb3 (MIT).
import SwiftUI

/// Persona's ink circle, 44pt hit area and Telegram-style pressed motion.
struct ComposerRoundButton: View {
    var symbol: String
    var label: String
    var id: String
    var busy = false
    var pressScales = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().tint(Theme.Shell.inkText) }
                else { ThemedIcon(symbol).font(Theme.Font.bodyHeavy) }
            }
            .foregroundStyle(Theme.Shell.inkText)
            .scaledFrame(width: Theme.Size.wellL, height: Theme.Size.wellL)
            .background(Theme.Shell.ink, in: Circle())
            .tapTargetFrame()
            .contentShape(.circle)
        }
        .buttonStyle(ComposerPress(scales: pressScales))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

private struct ComposerPress: ButtonStyle {
    let scales: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && scales && !reduceMotion ? Theme.Motion.composerPressScale : 1)
            .animation(reduceMotion ? nil : configuration.isPressed ? Theme.Motion.composerPress : Theme.Motion.composerRelease,
                       value: configuration.isPressed)
    }
}
