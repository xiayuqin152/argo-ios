// Adapted from nwverse/persona apple/Persona/Views/Chat/MessageViews.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import SwiftUI
import UIKit

struct MessageRow: View {
    let item: ArgoChatItem
    let openFile: (ArgoFileReference) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch item.type {
            case "thinking": ThinkingRow(item: item)
            case "tool", "result": ToolCallRow(item: item)
            default:
                if item.role == "user" { UserBubble(item: item) }
                else { AssistantText(item: item) }
            }
            if !item.fileRefs.isEmpty { AttachmentCards(references: item.fileRefs, open: openFile) }
            if item.truncated {
                Label("This content block was shortened by the host. View the full content on your computer.",
                      systemImage: Theme.Icon.warning)
                    .font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
            }
        }
        .accessibilityIdentifier("message-" + item.id)
    }
}

/// Persona's user side: a trailing soft-blue bubble with the original 48pt inset.
struct UserBubble: View {
    let item: ArgoChatItem
    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.sm) {
            HStack {
                Spacer(minLength: 48)
                Text(verbatim: item.text)
                    .font(Theme.Font.body)
                    .lineHeight(.body)
                    .readingContent()
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.userBubbleText)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .background(Theme.userBubble, in: .rect(cornerRadius: Theme.Radius.bubble, style: .continuous))
            }
            MessageTime(at: item.at)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu { CopyMessageButton(text: item.text) }
    }
}

/// Agent replies keep Persona's open reading column, rather than a second bubble.
struct AssistantText: View {
    let item: ArgoChatItem
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ReplyText(text: item.text)
                .font(Theme.Font.body)
                .lineHeight(.body)
                .readingContent()
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                MessageTime(at: item.at)
                Spacer()
                CopyMessageButton(text: item.text)
                    .labelStyle(.iconOnly)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .tapTargetFrame()
            }
        }
        .contextMenu { CopyMessageButton(text: item.text) }
    }
}

struct ThinkingRow: View {
    let item: ArgoChatItem
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button { open.toggle() } label: {
                HStack(spacing: Theme.Space.sm) {
                    ThemedIcon(Theme.Icon.memory).font(Theme.Font.label)
                    Text(verbatim: open ? L10n.text("Thinking") : String(item.text.split(separator: "\n").first ?? ""))
                        .font(Theme.Font.label).lineLimit(1)
                    Spacer(minLength: 0)
                    ThemedIcon(Theme.Icon.disclosure).font(Theme.Font.label).rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .tapTargetHeight()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thinking")
            .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
            if open {
                Text(verbatim: item.text)
                    .font(Theme.Font.caption)
                    .readingContent()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, Theme.Space.m)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: Theme.Size.rule)
                    }
            }
        }
    }
}

/// Persona's pending-message affordances are adapted to explicit core receipts.
/// Unknown delivery exposes refresh and copy, without an automatic resend path.
struct PendingBubble: View {
    let message: PendingDelivery
    let retry: () -> Void
    let refresh: () -> Void
    let preview: (ArgoLocalAttachment) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            DisclosureGroup(isExpanded: $expanded) {
                if !message.attachments.isEmpty { LocalAttachmentCards(files: message.attachments.map(\.local), open: preview) }
                Text(verbatim: message.operation.text)
                    .font(Theme.Font.secondary).readingContent().textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let problem {
                    Text(verbatim: problem).font(Theme.Font.caption).foregroundStyle(.secondary)
                        .readingContent()
                }
                if message.duplicate {
                    Text("Acknowledged earlier attempt").font(Theme.Font.label).foregroundStyle(.secondary)
                }
                HStack(spacing: Theme.Space.l) {
                    if message.status.canRetry { Button("Retry Sending", action: retry).tapTargetHeight() }
                    if case .unknown = message.status { Button("Refresh Conversation", action: refresh).tapTargetHeight() }
                    CopyMessageButton(text: message.operation.text).tapTargetHeight()
                }
                .font(Theme.Font.captionStrong)
            } label: {
                HStack(spacing: Theme.Space.s) {
                    if message.status == .sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: symbol) }
                    Text(title).font(Theme.Font.captionStrong)
                    Spacer(minLength: Theme.Space.xs)
                    Text(message.created, style: .time).font(Theme.Font.label).foregroundStyle(.secondary)
                }
            }
            .tint(tint)
        }
        .padding(Theme.Space.m)
        .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
        .accessibilityIdentifier("delivery-" + message.id)
    }

    private var title: String {
        let key = switch message.status {
        case .sending: "Sending…"
        case .delivered: "Delivered to Agent"
        case .answered: "Answer Sent to Terminal"
        case .queued: "Queued on Host"
        case .pasted: "Pasted in Terminal — Submit There"
        case .notSent: "Not Sent"
        case .unknown: "Delivery Unknown — Refresh First"
        case .rejected: "Message Refused"
        }
        return L10n.text(key)
    }
    private var problem: String? {
        switch message.status {
        case .notSent(let text), .unknown(let text), .rejected(let text): text
        case .queued(let note): note
        case .pasted(let note): note
        default: nil
        }
    }
    private var symbol: String {
        switch message.status {
        case .delivered, .answered: "checkmark"
        case .queued: Theme.Icon.time
        case .pasted: "keyboard"
        case .notSent, .rejected, .unknown: Theme.Icon.warning
        case .sending: Theme.Icon.time
        }
    }
    private var tint: Color {
        switch message.status {
        case .notSent, .rejected: Theme.danger
        case .unknown, .pasted: Theme.cautionText
        default: .secondary
        }
    }
}

struct MessageTime: View {
    let at: String
    var body: some View {
        if let date = ArgoTime.date(at) {
            Text(date, style: .time).font(Theme.Font.label).foregroundStyle(.secondary)
        }
    }
}

struct CopyMessageButton: View {
    let text: String
    var body: some View {
        Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: Theme.Icon.copy) }
            .buttonStyle(.plain)
    }
}
