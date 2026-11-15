import ArgoMobileKit
import Foundation

struct ModelRecoveryOperation: Identifiable, Equatable {
    enum Status: Equatable {
        case sending
        case notSwitched(String)
        case switchedAndResumed(String)
        case switchedNotResumed(String)
        case notSent(String)
        case unknown(String)
        case rejected(String)
    }

    let id: UUID
    let model: String
    var status: Status = .sending
    /// A successful GET after an uncertain or already-switched result. It is
    /// evidence for review, not permission for the client to replay the POST.
    var reviewed = false
    var refreshing = false
    var refreshProblem: String?

    var needsReviewBeforeNewAction: Bool {
        if reviewed { return false }
        switch status {
        case .unknown, .switchedAndResumed, .switchedNotResumed: return true
        case .sending, .notSwitched, .notSent, .rejected: return false
        }
    }

    var acceptsNewAction: Bool {
        if refreshing || needsReviewBeforeNewAction { return false }
        if case .sending = status { return false }
        return true
    }
}

extension ConversationState {
    var isMessageSending: Bool { attachmentSendID != nil || deliveries.contains { $0.status == .sending } }

    var canStartModelRecovery: Bool {
        !isMessageSending && !isInterruptBusy && (modelRecovery?.acceptsNewAction ?? true)
    }

    func beginModelRecovery(_ id: UUID, model: String) {
        modelRecovery = ModelRecoveryOperation(id: id, model: model)
        modelRecoveryProblem = nil
    }

    func finishModelRecovery(_ id: UUID, status: ModelRecoveryOperation.Status) {
        guard modelRecovery?.id == id else { return }
        modelRecovery?.status = status
        modelRecovery?.reviewed = false
        modelRecovery?.refreshProblem = nil
    }

    func beginModelRecoveryRefresh(_ id: UUID) -> Bool {
        guard modelRecovery?.id == id, modelRecovery?.refreshing == false else { return false }
        modelRecovery?.refreshing = true
        modelRecovery?.refreshProblem = nil
        return true
    }

    func finishModelRecoveryRefresh(_ id: UUID) {
        guard modelRecovery?.id == id else { return }
        modelRecovery?.refreshing = false
        modelRecovery?.refreshProblem = nil
        modelRecovery?.reviewed = true
    }

    func failModelRecoveryRefresh(_ id: UUID, problem: String?) {
        guard modelRecovery?.id == id else { return }
        modelRecovery?.refreshing = false
        modelRecovery?.refreshProblem = problem
    }
}
