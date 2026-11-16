// Adapted from nwverse/persona apple/Persona/DesignSystem/TypedText.swift and TextViewScroll.swift @ 3002eb3 (MIT).
import SwiftUI
import UIKit
import GameController

enum TypedText {
    @MainActor static func commitFocused(into text: Binding<String>) {
        guard let view = FirstResponder.current as? (UIResponder & UITextInput) else { return }
        if view.markedTextRange != nil { view.unmarkText() }
        guard let all = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument),
              let shown = view.text(in: all), shown != text.wrappedValue else { return }
        text.wrappedValue = shown
    }
}

private enum FirstResponder {
    @MainActor static weak var found: UIResponder?
    @MainActor static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.argoFindFirstResponder(_:)), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found
    }
}

private extension UIResponder {
    @objc func argoFindFirstResponder(_ sender: Any?) { FirstResponder.found = self }
}

/// Shared with Settings; Return Key Sends remains opt-in.
nonisolated enum ReturnSends {
    static let enabledKey = "argo.returnSends"
}

/// Only the two conversation editing surfaces use this native input boundary.
/// UIKit owns editing, marked text, undo, selection, paste and drop. SwiftUI still
/// owns the Persona surface/layout and the conversation's draft and focus.
struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?
    @Binding var focused: Bool
    var maximumLines: Int? = nil
    var returnSends = false
    var canSend: Bool
    var acceptsInput: () -> Bool
    var send: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.pasteDelegate = view
        view.backgroundColor = .clear
        view.textColor = .label
        view.allowsEditingTextAttributes = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if maximumLines != nil {
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
        }
        view.submit = { [weak coordinator = context.coordinator] view in
            coordinator?.submit(view)
        }
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        view.acceptsInput = acceptsInput
        view.isEditable = acceptsInput()
        view.sendsOnReturn = returnSends
        let label: UIReturnKeyType = returnSends ? .send : .default
        if view.returnKeyType != label {
            view.returnKeyType = label
            if view.isFirstResponder { view.reloadInputViews() }
        }
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        if view.font != font { view.font = font }
        coordinator.updateDraft(view)
        view.wantsFocus = focused && view.isEditable
        view.updateFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let maximumLines, let width = proposal.width, width > 0 else { return nil }
        let line = uiView.font?.lineHeight ?? 0
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(min(max(height, line), line * CGFloat(maximumLines))))
    }

    // Use the reading environment, including Persona's Small/Standard/Large
    // preference and AX sizes, rather than the interface's capped traits.
    private var contentSizeCategory: UIContentSizeCategory {
        switch typeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        var updating = false
        init(_ parent: ComposerTextInput) { self.parent = parent }

        func updateDraft(_ view: ComposerTextView) {
            // A render during composition must not unmark or move its selection.
            guard view.markedTextRange == nil else { return }
            if view.text != parent.text { view.setDraft(parent.text) }
            let count = (view.text as NSString).length
            let wanted = parent.selection ?? NSRange(location: count, length: 0)
            let start = min(wanted.location, count)
            let selected = NSRange(location: start, length: min(wanted.length, count - start))
            if view.selectedRange != selected { view.selectedRange = selected }
            view.invalidateIntrinsicContentSize()
        }

        func submit(_ view: ComposerTextView) {
            guard parent.focused, parent.acceptsInput(), parent.canSend else { return }
            parent.send()
            // send() clears the binding synchronously. Clear the native buffer in
            // the same event so a second Return/commit cannot restore the draft.
            updating = true
            defer { updating = false }
            updateDraft(view)
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { parent.acceptsInput() }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !updating { parent.focused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if !updating { parent.focused = false }
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !updating, parent.acceptsInput() else { return }
            parent.text = textView.text
            parent.selection = textView.selectedRange
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, parent.acceptsInput() else { return }
            parent.selection = textView.selectedRange
        }
    }
}

/// UIKeyInput is the keyboard insertion boundary. Text replacements, programmatic
/// draft updates and UITextPasteDelegate (both paste and drop, including async item
/// providers) never enter the Return action. No draft-diff or clipboard inspection.
final class ComposerTextView: UITextView, UITextPasteDelegate {
    var sendsOnReturn = false
    var acceptsInput: () -> Bool = { false }
    var submit: ((ComposerTextView) -> Void)?
    var wantsFocus = false
    private var replacing = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFocus()
    }

    func updateFocus() {
        let shouldFocus = wantsFocus && acceptsInput()
        if shouldFocus && window != nil && !isFirstResponder { becomeFirstResponder() }
        else if !shouldFocus && isFirstResponder { resignFirstResponder() }
    }

    override func insertText(_ text: String) {
        if text == "\n", !replacing, sendsOnReturn, isFirstResponder,
           acceptsInput(), markedTextRange == nil, !Self.lineBreakModifierHeld {
            submit?(self)
            return
        }
        super.insertText(text)
    }

    override func replace(_ range: UITextRange, withText text: String) {
        // UIKit may implement a replacement by calling insertText internally.
        // The origin stays replacement for that entire synchronous operation.
        let previous = replacing
        replacing = true
        defer { replacing = previous }
        super.replace(range, withText: text)
    }

    func setDraft(_ draft: String) {
        let previous = replacing
        replacing = true
        defer { replacing = previous }
        text = draft
    }

    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          performPasteOf attributedString: NSAttributedString,
                                          to textRange: UITextRange) -> UITextRange {
        guard acceptsInput() else { return textRange }
        let start = offset(from: beginningOfDocument, to: textRange.start)
        replace(textRange, withText: attributedString.string)
        let end = position(from: beginningOfDocument, offset: start + attributedString.length) ?? endOfDocument
        selectedTextRange = self.textRange(from: end, to: end)
        // UITextInput.replace is also a programmatic API; publish explicitly.
        delegate?.textViewDidChange?(self)
        return self.textRange(from: position(from: beginningOfDocument, offset: start) ?? end, to: end) ?? textRange
    }

    override var keyCommands: [UIKeyCommand]? {
        // Cmd-Return remains the existing SwiftUI send button's shortcut. Only
        // modified line breaks belong here; IME confirmation keeps UIKit's keys.
        guard acceptsInput(), markedTextRange == nil else { return super.keyCommands }
        let breaks = [UIKeyModifierFlags.shift, .alternate, [.shift, .alternate]].map {
            let key = UIKeyCommand(input: "\r", modifierFlags: $0, action: #selector(insertLineBreak))
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
        return breaks + (super.keyCommands ?? [])
    }

    @objc private func insertLineBreak() {
        // Directly invoke UIKit editing; this explicit modified key never sends.
        super.insertText("\n")
    }

    /// Preserve Shift/Option even when UIKit delivers hardware input through
    /// UIKeyInput instead of the registered key command. Read only for a keyboard
    /// newline, never to classify a change to the draft.
    private static var lineBreakModifierHeld: Bool {
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return false }
        return keys.button(forKeyCode: .leftShift)?.isPressed == true || keys.button(forKeyCode: .rightShift)?.isPressed == true ||
            keys.button(forKeyCode: .leftAlt)?.isPressed == true || keys.button(forKeyCode: .rightAlt)?.isPressed == true ||
            keys.button(forKeyCode: .leftControl)?.isPressed == true || keys.button(forKeyCode: .rightControl)?.isPressed == true ||
            keys.button(forKeyCode: .leftGUI)?.isPressed == true || keys.button(forKeyCode: .rightGUI)?.isPressed == true
    }
}
