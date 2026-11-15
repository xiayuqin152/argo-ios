// Adapted from nwverse/persona apple/Persona/DesignSystem/AgentMark.swift @ 3002eb3 (MIT).
import SwiftUI

/// Persona's letter tile and CLI badge, using the server's actual agent name.
struct AgentMark: View {
    let name: String
    var side: CGFloat = Theme.Size.markS

    var body: some View {
        Text(name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?")
            .font(Theme.Font.labelHeavy)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .scaledFrame(width: side * 0.92, height: side * 0.92)
            .background(Theme.Fill.chip, in: .rect(cornerRadius: Theme.Radius.thumbnail))
            .scaledFrame(width: side, height: side)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: Theme.Icon.commandLine)
                    .resizable().scaledToFit()
                    .foregroundStyle(Theme.pageBackground)
                    .padding(side * 0.1)
                    .scaledFrame(width: side * 0.62, height: side * 0.62)
                    .background(Color.primary, in: .rect(cornerRadius: Theme.Radius.thumbnail))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                            .strokeBorder(Theme.pageBackground, lineWidth: Theme.Size.line)
                    }
                    .offset(x: side * 0.22, y: side * 0.18)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(name), command line"))
            .accessibilityIdentifier("agent.mark")
    }
}
