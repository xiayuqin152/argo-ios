// Adapted from nwverse/persona apple/Persona/Views/Chat/PromptComposer.swift and
// apple/Persona/DesignSystem/ShellComposerBar.swift @ 3002eb3 (MIT).
import SwiftUI

/// The actual iOS Persona shell composer: one field in both the capsule and expanded
/// card. Keeping its identity also keeps focus, selection and Chinese marked text.
/// Argo uses the same field with its real attachment picker and text queue.
struct PromptComposer: View {
    let placeholder: String
    @Binding var text: String
    let canSend: Bool
    let sending: Bool
    let showsStop: Bool
    let canStop: Bool
    let stopping: Bool
    let agentName: String
    let send: () -> Void
    let stop: () -> Void
    let canAttach: Bool
    let hasAttachments: Bool
    let attach: () -> Void
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { focused || !text.isEmpty || hasAttachments }

    var body: some View {
        ComposerBoxLayout(open: expanded, spacing: Theme.Space.xs,
                          rowGap: Theme.Space.l, rowLeading: Theme.Space.s,
                          rowTrailing: Theme.Space.s, rowBottom: expanded ? Theme.Space.s : 0) {
            TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
                .font(Theme.Font.body)
                .readingContent()
                .lineLimit(1...Theme.Shell.composerPhoneMaximumLines)
                .focused($focused)
                .textFieldStyle(.plain)
                .padding(.leading, Theme.Space.l)
                .padding(.trailing, expanded ? Theme.Space.l : Theme.Space.xs)
                .padding(.vertical, Theme.Space.m)
                .frame(minHeight: Theme.Size.tapTarget)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("message-draft")
            HStack(spacing: Theme.Space.xs) {
                Button {
                    commitMarkedText()
                    focused = false
                    attach()
                } label: { Image(systemName: "plus").font(Theme.Font.heading).tapTargetFrame() }
                    .buttonStyle(.plain).disabled(!canAttach).accessibilityLabel("Attach photos or files")
                    .accessibilityIdentifier("composer-attach")
                if expanded && focused {
                    Button { commitMarkedText(); focused = false } label: {
                        ThemedIcon(Theme.Icon.dismissKeyboard)
                            .font(Theme.Font.heading)
                            .foregroundStyle(.secondary)
                            .tapTargetFrame()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide Keyboard")
                }
            }
            HStack(spacing: Theme.Space.xs) {
                if expanded {
                    Text(verbatim: agentName)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if showsStop && ((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments) || stopping) {
                    ComposerRoundButton(symbol: Theme.Icon.interrupt, label: L10n.text("Stop Current Turn"),
                                        id: "composer-stop", busy: stopping, pressScales: false, action: stop)
                        .disabled(!canStop)
                        .opacity(canStop || stopping ? 1 : 0.35)
                } else {
                    ComposerRoundButton(symbol: Theme.Icon.send, label: L10n.text("Send"),
                                        id: "composer-send", busy: sending) {
                        commitMarkedText()
                        send()
                    }
                    .disabled(!canSend)
                    .opacity(canSend || sending ? 1 : 0.35)
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
            }
        }
        .padding(.horizontal, expanded ? 0 : Theme.Space.xs)
        .padding(.vertical, expanded ? 0 : Theme.Space.xxs)
        .modifier(ComposerSurface())
        .contentShape(.rect(cornerRadius: Theme.Shell.composerRadius))
        .onTapGesture { focused = true }
        .animation(reduceMotion ? nil : Theme.Motion.state, value: expanded)
        .animation(reduceMotion ? nil : Theme.Motion.composerGrow, value: text)
    }

    private func commitMarkedText() { if focused { TypedText.commitFocused(into: $text) } }
}
