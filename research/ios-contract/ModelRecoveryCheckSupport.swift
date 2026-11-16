import ArgoMobileKit
import Foundation

// Only the storage that the production extension needs. UI/attachments and
// localization are outside this Linux contract probe.
struct SessionKey: Hashable {
    let host: UUID
    let workspace: String
    let run: String
    let terminal: String
}

enum L10n {
    static func text(_ value: String) -> String { value }
}

@MainActor final class ConversationState {
    struct Delivery {
        enum Status { case sending, delivered }
        var status: Status
    }
    let key: SessionKey
    var transcript = ChatTranscript()
    var attachmentSendID: UUID?
    var deliveries: [Delivery] = []
    var isInterruptBusy = false
    var modelRecovery: ModelRecoveryOperation?
    var modelRecoveryProblem: String?
    init(key: SessionKey) { self.key = key }
}
