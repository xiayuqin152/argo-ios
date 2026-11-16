// Adapted from ComposerPageEditor in nwverse/Persona
// apple/Persona/DesignSystem/ShellComposerBar.swift
// @ 89927b54baab6b8207315f6c2a4d2e5831598d45 (MIT).
import Foundation
import SwiftUI

struct ComposerPageEditor: View {
    let placeholder: String
    @Bindable var input: ComposerInputOwner
    @Binding var selection: NSRange?
    let canSend: Bool
    let sending: Bool
    let showsStop: Bool
    let canStop: Bool
    let stopping: Bool
    let hasAttachments: Bool
    let canAttach: Bool
    let paste: ([NSItemProvider]) -> Void
    let done: () -> Void
    let send: () -> Void
    let stop: () -> Void
    @State private var focused = false
    @State private var cursor: NSRange?
    @State private var submission = ComposerSubmission()
    @Environment(\.scenePhase) private var scenePhase

    private var draft: Binding<String> {
        Binding(get: { input.text }, set: { input.text = $0 })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.s) {
                HStack {
                    Text("Edit Message").font(Theme.Font.heading)
                    Spacer()
                    if focused {
                        Button {
                            commitTyped()
                            focused = false
                        } label: { ThemedIcon(Theme.Icon.dismissKeyboard).tapTargetFrame() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide Keyboard")
                            .accessibilityIdentifier("composer-page-dismiss-keyboard")
                    }
                    Button("Done") { finish() }
                        .tapTargetHeight()
                        .accessibilityLabel("Finish Editing")
                        .accessibilityIdentifier("composer-page-done")
                }
                ComposerTextInput(text: draft, selection: $cursor, focused: $focused,
                                  canSend: canSend && !submission.claimed,
                                  acceptsInput: { input.acceptsInput && !submission.claimed }, send: sendOnce)
                    .readingContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Message")
                    .accessibilityIdentifier("composer-page-field")
                    .overlay(alignment: .topLeading) {
                        if input.text.isEmpty {
                            Text(verbatim: placeholder).font(Theme.Font.body)
                                .foregroundStyle(.tertiary)
                                .padding(.top, Theme.Space.s)
                                .padding(.leading, Theme.Space.xxs)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                PasteImageChip(focused: focused && input.acceptsInput, enabled: canAttach,
                               paste: paste)
                HStack {
                    Spacer()
                    if showsStop && ((input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments) || stopping) {
                        ComposerRoundButton(symbol: Theme.Icon.interrupt, label: L10n.text("Stop Current Turn"),
                                            id: "composer-page-stop", busy: stopping, pressScales: false) {
                            guard input.acceptsInput else { return }
                            commitTyped()
                            stop()
                        }
                        .disabled(!canStop || !input.acceptsInput)
                    } else {
                        ComposerRoundButton(symbol: Theme.Icon.send, label: L10n.text("Send"),
                                            id: "composer-page-send", busy: sending, action: sendOnce)
                            .disabled(!canSend || !input.acceptsInput || submission.claimed)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: Theme.Size.readable, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            cursor = selection ?? NSRange(location: (input.text as NSString).length, length: 0)
            focused = input.acceptsInput
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                commitTyped()
                selection = cursor
                input.invalidate()
                done()
            }
        }
        .onDisappear {
            guard !submission.claimed else { return }
            commitTyped()
            selection = cursor
        }
    }

    private func finish() {
        commitTyped()
        selection = cursor
        done()
    }

    private func sendOnce() {
        guard input.acceptsInput, !submission.claimed, canSend else { return }
        commitTyped()
        guard submission.claim(allowed: canSend && input.acceptsInput) else { return }
        // The model retains its existing single-POST/unknown receipt semantics.
        // Do not confirm the old text again as the sheet disappears after send.
        send()
    }

    private func commitTyped() {
        guard focused, input.canCommit, !submission.claimed else { return }
        TypedText.commitFocused(into: Binding(get: { input.text }, set: { input.commit($0) }))
    }
}
