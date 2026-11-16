// Framework doubles only. Native delivery and rendering are not emulated.
import Foundation
import Observation

@MainActor protocol UITextPasteDelegate {}
@MainActor protocol UITextPasteConfigurationSupporting {}
final class UITextRange { let start: Int; let end: Int; init(_ start: Int, _ end: Int) { self.start = start; self.end = end } }
struct UIKeyModifierFlags: OptionSet {
    let rawValue: Int
    static let shift = Self(rawValue: 1), alternate = Self(rawValue: 2), command = Self(rawValue: 4)
}
final class UIKeyCommand {
    let input: String; let modifierFlags: UIKeyModifierFlags; let action: String
    var wantsPriorityOverSystemBehavior = false
    init(input: String, modifierFlags: UIKeyModifierFlags, action: String) {
        self.input = input; self.modifierFlags = modifierFlags; self.action = action
    }
}
enum KeyCode: CaseIterable { case leftShift, rightShift, leftAlt, rightAlt, leftControl, rightControl, leftGUI, rightGUI }
struct KeyState { let isPressed = true }
struct KeyboardInput {
    var held: Set<KeyCode> = []
    func button(forKeyCode key: KeyCode) -> KeyState? { held.contains(key) ? KeyState() : nil }
}
@MainActor struct GCKeyboard { var keyboardInput: KeyboardInput?; static var coalesced: GCKeyboard? }
@MainActor protocol UITextViewDelegate {}
@MainActor final class DelegateForwarder {
    var textViewDidChange: ((UITextView) -> Void)?
}
@MainActor class UITextView: UITextPasteConfigurationSupporting {
    var text = ""
    var markedTextRange: UITextRange?
    var isFirstResponder = true
    var window: Int? = 1
    var delegate: DelegateForwarder?
    var selectedRange = NSRange(location: 0, length: 0)
    var selectedTextRange: UITextRange? {
        get { UITextRange(selectedRange.location, NSMaxRange(selectedRange)) }
        set { if let range = newValue { selectedRange = NSRange(location: range.start, length: range.end - range.start) } }
    }
    var beginningOfDocument: Int { 0 }
    var endOfDocument: Int { (text as NSString).length }
    var keyCommands: [UIKeyCommand]? { nil }
    func didMoveToWindow() {}
    @discardableResult func becomeFirstResponder() -> Bool { isFirstResponder = true; return true }
    @discardableResult func resignFirstResponder() -> Bool { isFirstResponder = false; return true }
    func offset(from: Int, to: Int) -> Int { to - from }
    func position(from: Int, offset: Int) -> Int? { from + offset <= endOfDocument ? from + offset : nil }
    func textRange(from: Int, to: Int) -> UITextRange? { UITextRange(from, to) }
    func invalidateIntrinsicContentSize() {}
    func insertText(_ insertion: String) {
        text = (text as NSString).replacingCharacters(in: selectedRange, with: insertion)
        selectedRange = NSRange(location: selectedRange.location + (insertion as NSString).length, length: 0)
        delegate?.textViewDidChange?(self)
    }
    func replace(_ range: UITextRange, withText replacement: String) {
        // Exercise the hardest valid superclass behavior: replacement reenters
        // overridden insertText. The production source guard must still hold.
        selectedTextRange = range
        insertText(replacement)
    }
}
@MainActor final class ComposerTextInput {
    var text: String
    var selection: NSRange?
    var focused = true
    var canSend = true
    var acceptsInput: () -> Bool = { true }
    var send: () -> Void = {}
    init(_ text: String) { self.text = text }
}
@MainActor @Observable final class ConversationState { var draft = "" }
