// Adapted from nwverse/persona apple/Persona/Views/Chats/AgentRowStyles.swift @ 3002eb3 (MIT).
import SwiftUI

/// Persona's default avatar row, backed by the thin Argo session projection.
struct SlotRow: View {
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            AgentAvatar(session: session)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                TimeBesideOrUnder {
                    Text(verbatim: session.displayTitle)
                        .font(session.card.unread ? Theme.Font.bodyHeavy : Theme.Font.bodyStrong)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } time: {
                    if let updated = session.updated {
                        Text(updated, style: .relative)
                            .font(Theme.Font.label.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let words = session.preview {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Text(verbatim: words)
                            .font(Theme.Font.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if session.state == .needsYou {
                            Chip(text: session.state.label, tint: session.state.tone.text).fixedSize()
                        }
                    }
                }
                HStack(spacing: Theme.Space.xs) {
                    Text(verbatim: session.agentName).lineLimit(1)
                    Text(verbatim: "·")
                    Text(verbatim: session.state.label).foregroundStyle(session.state.tone.text)
                    if session.card.queued > 0 {
                        Image(systemName: Theme.Icon.time)
                        Text("\(session.card.queued) queued")
                    }
                    if session.card.nativeHistory > 0 {
                        Image(systemName: "tray")
                        Text("Native records: \(session.card.nativeHistory)")
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Space.xxs)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-row-" + session.card.run)
    }
}

struct AgentAvatar: View {
    let session: AgentSession
    var body: some View {
        AgentMark(name: session.agentName, side: Theme.Size.markL)
            .scaledFrame(width: Theme.Size.wellL, height: Theme.Size.wellL)
            .background(Theme.Fill.well, in: Circle())
            .overlay(alignment: .bottomTrailing) {
                StatusDot(state: session.state, size: Theme.Size.dotXL)
                    .padding(Theme.Size.rule)
                    .background(Theme.pageBackground, in: Circle())
                    .offset(x: Theme.Size.rule, y: Theme.Size.rule)
            }
    }
}
