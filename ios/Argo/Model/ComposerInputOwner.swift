import Foundation
import Observation

/// One input surface owns one actual conversation object, never a lookup of the
/// newly selected chat. Revocation also rejects delayed system-paste callbacks.
@MainActor @Observable
final class ComposerInputOwner: Identifiable {
    let id = UUID()
    let state: ConversationState
    private(set) var valid = true
    @ObservationIgnored private let destinationIsCurrent: () -> Bool
    @ObservationIgnored private let foreground: () -> Bool

    init(state: ConversationState, destinationIsCurrent: @escaping () -> Bool,
         foreground: @escaping () -> Bool) {
        self.state = state
        self.destinationIsCurrent = destinationIsCurrent
        self.foreground = foreground
    }

    var canCommit: Bool { valid && destinationIsCurrent() }
    var acceptsInput: Bool { canCommit && foreground() }
    var text: String {
        get { state.draft }
        set { if acceptsInput { state.draft = newValue } }
    }

    /// A lifecycle transition can confirm IME text in its original destination
    /// before revocation, even after the model has stopped foreground work.
    func commit(_ text: String) { if canCommit { state.draft = text } }
    func invalidate() { valid = false }
}

/// Shared by the page's button and keyboard shortcut; never retries a send.
nonisolated struct ComposerSubmission {
    private(set) var claimed = false
    mutating func claim(allowed: Bool) -> Bool {
        guard allowed, !claimed else { return false }
        claimed = true
        return true
    }
}
