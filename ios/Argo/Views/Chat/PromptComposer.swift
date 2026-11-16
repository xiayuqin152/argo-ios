// Adapted from nwverse/persona apple/Persona/Views/Chat/PromptComposer.swift and
// apple/Persona/DesignSystem/ShellComposerBar.swift @ 3002eb3 (MIT).
// Full-page input adapted from the latter @ 89927b54baab6b8207315f6c2a4d2e5831598d45.
import Foundation
import SwiftUI

/// The actual iOS Persona shell composer: one field in both the capsule and expanded
/// card. Keeping its identity also keeps focus, selection and Chinese marked text.
/// Argo uses the same field with its real attachment picker and text queue.
struct PromptComposer: View {
    let placeholder: String
    @Bindable var input: ComposerInputOwner
    let renewInputOwner: () -> Void
    let canSend: Bool
    let sending: Bool
    let showsStop: Bool
    let canStop: Bool
    let stopping: Bool
    let stopStatus: String?
    let agentName: String
    let send: () -> Void
    let stop: () -> Void
    let canAttach: Bool
    let hasAttachments: Bool
    let attach: () -> Void
    let paste: ([NSItemProvider]) -> Void
    @State private var selection: NSRange?
    @State private var parkedSelection: NSRange?
    @State private var pagePresentation = SeenPresentation()
    @State private var sentFromPage = false
    @State private var focused = false
    @AppStorage(ReturnSends.enabledKey) private var returnSends = false
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String { input.text }
    private var draft: Binding<String> { Binding(get: { input.text }, set: { input.text = $0 }) }
    private var expanded: Bool { focused || !text.isEmpty || hasAttachments }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            PasteImageChip(focused: focused && input.acceptsInput, enabled: canAttach, paste: paste)
            box
        }
        .sheet(isPresented: pagePresentation.binding(in: model, conversation: input.state.key), onDismiss: pageDismissed) {
            ComposerPageEditor(placeholder: placeholder, input: input, selection: $selection,
                               canSend: canSend, sending: sending, showsStop: showsStop,
                               canStop: canStop, stopping: stopping, hasAttachments: hasAttachments,
                               canAttach: canAttach, paste: paste,
                               done: { pagePresentation.requestDismissal() },
                               send: {
                                   sentFromPage = true
                                   send()
                                   pagePresentation.requestDismissal()
                               }, stop: stop)
                .presentationSizing(.page)
                .presentationDetents([.large])
        }
        .onChange(of: input.canCommit) { _, current in
            if !current { inputRevoked() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && pagePresentation.owner == nil {
                commitMarkedText()
                input.invalidate()
            }
        }
    }

    private var box: some View {
        ComposerBoxLayout(open: expanded, spacing: Theme.Space.xs,
                          rowGap: Theme.Space.l, rowLeading: Theme.Space.s,
                          rowTrailing: Theme.Space.s, rowBottom: expanded ? Theme.Space.s : 0) {
            ComposerTextInput(text: draft,
                              selection: pagePresentation.owner == nil ? $selection : $parkedSelection,
                              focused: $focused, maximumLines: Theme.Shell.composerPhoneMaximumLines,
                              returnSends: returnSends, canSend: canSend,
                              acceptsInput: { input.acceptsInput && pagePresentation.owner == nil }) {
                    commitMarkedText()
                    send()
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: placeholder).font(Theme.Font.body)
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .readingContent()
                .padding(.leading, Theme.Space.l)
                .padding(.trailing, expanded ? Theme.Size.tapTarget : Theme.Space.xs)
                .padding(.vertical, Theme.Space.m)
                .frame(minHeight: Theme.Size.tapTarget)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("message-draft")
                .overlay(alignment: .topTrailing) {
                    if expanded {
                        Button(action: enlarge) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(.secondary).tapTargetFrame()
                        }
                        .buttonStyle(.plain)
                        .disabled(!input.acceptsInput)
                        .accessibilityLabel("Expand the message box")
                        .accessibilityIdentifier("shell-composer-expand")
                    }
                }
            HStack(spacing: Theme.Space.xs) {
                Button {
                    guard input.acceptsInput else { return }
                    commitMarkedText()
                    focused = false
                    attach()
                } label: { Image(systemName: "plus").font(Theme.Font.heading).tapTargetFrame() }
                    .buttonStyle(.plain).disabled(!canAttach || !input.acceptsInput).accessibilityLabel("Attach photos or files")
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
                        .disabled(!canStop || !input.acceptsInput)
                        .opacity(canStop || stopping ? 1 : 0.35)
                        .accessibilityValue(Text(verbatim: stopStatus ?? ""))
                } else {
                    ComposerRoundButton(symbol: Theme.Icon.send, label: L10n.text("Send"),
                                        id: "composer-send", busy: sending) {
                        commitMarkedText()
                        send()
                    }
                    .disabled(!canSend || !input.acceptsInput || pagePresentation.owner != nil)
                    .opacity(canSend || sending ? 1 : 0.35)
                    .keyboardShortcut(focused && pagePresentation.owner == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
            }
        }
        .padding(.horizontal, expanded ? 0 : Theme.Space.xs)
        .padding(.vertical, expanded ? 0 : Theme.Space.xxs)
        .modifier(ComposerSurface())
        .contentShape(.rect(cornerRadius: Theme.Shell.composerRadius))
        .onTapGesture { if pagePresentation.owner == nil && input.acceptsInput { focused = true } }
        .animation(reduceMotion ? nil : Theme.Motion.state, value: expanded)
        .animation(reduceMotion ? nil : Theme.Motion.composerGrow, value: text)
    }

    private func inputRevoked() {
        input.invalidate()
        focused = false
        pagePresentation.requestDismissal()
        // Keep this owner until the sheet actually closes; its callbacks stay
        // revoked, and the replacement shell starts without keyboard focus.
        if pagePresentation.owner == nil { renewInputOwner() }
    }

    private func pageDismissed() {
        pagePresentation.didDismiss(in: model)
        if !sentFromPage && input.acceptsInput { focused = true }
        sentFromPage = false
        if !input.canCommit { renewInputOwner() }
    }

    private func enlarge() {
        guard input.acceptsInput, pagePresentation.owner == nil else { return }
        if focused { commitMarkedText() }
        else { selection = NSRange(location: (text as NSString).length, length: 0) }
        sentFromPage = false
        pagePresentation.setPresented(true, in: model, conversation: input.state.key)
        focused = false
    }

    private func commitMarkedText() {
        if focused && input.canCommit {
            TypedText.commitFocused(into: Binding(get: { input.text }, set: { input.commit($0) }))
        }
    }
}
