import ArgoMobileKit
import Foundation

/// Native evidence is valid only for this exact destination and read epoch.
/// A later native change or a waiting page invalidates it.
struct ModelRecoveryNativeProof: Equatable {
    let destination: SessionKey
    let identity: ArgoAgentIdentity
    let epoch: UUID
}

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
    let destination: SessionKey
    let nativeAtStart: ArgoAgentIdentity?
    var status: Status = .sending
    /// A reviewed receipt is not permission to replay the POST. The current
    /// transcript must still match nativeProof before another user action.
    var reviewed = false
    var nativeProof: ModelRecoveryNativeProof?
    /// A changed native needs a second explicit, consistent read in another
    /// epoch. This candidate never unlocks by itself.
    var nativeCandidate: ModelRecoveryNativeProof?
    var refreshing = false
    var refreshProblem: String?
}

extension ConversationState {
    var isMessageSending: Bool { attachmentSendID != nil || deliveries.contains { $0.status == .sending } }

    private var hasCurrentModelRecoveryProof: Bool {
        guard let operation = modelRecovery, operation.reviewed,
              let proof = operation.nativeProof else { return false }
        return operation.destination == key && proof.destination == key && proof.identity == transcript.identity
    }

    var modelRecoveryNeedsReviewBeforeNewAction: Bool {
        guard let operation = modelRecovery else { return false }
        switch operation.status {
        case .unknown, .switchedAndResumed, .switchedNotResumed: return !hasCurrentModelRecoveryProof
        case .sending, .notSwitched, .notSent, .rejected: return false
        }
    }

    var canStartModelRecovery: Bool {
        if isMessageSending || isInterruptBusy { return false }
        guard let operation = modelRecovery else { return true }
        if operation.refreshing || operation.status == .sending { return false }
        return !modelRecoveryNeedsReviewBeforeNewAction
    }

    func beginModelRecovery(_ id: UUID, model: String) {
        modelRecovery = ModelRecoveryOperation(id: id, model: model, destination: key, nativeAtStart: transcript.identity)
        modelRecoveryProblem = nil
    }

    func finishModelRecovery(_ id: UUID, status: ModelRecoveryOperation.Status) {
        guard modelRecovery?.id == id else { return }
        modelRecovery?.status = status
        modelRecovery?.reviewed = false
        modelRecovery?.nativeProof = nil
        modelRecovery?.nativeCandidate = nil
        modelRecovery?.refreshProblem = nil
    }

    func beginModelRecoveryRefresh(_ id: UUID) -> Bool {
        guard modelRecovery?.id == id, modelRecovery?.destination == key,
              modelRecovery?.refreshing == false else { return false }
        modelRecovery?.refreshing = true
        modelRecovery?.refreshProblem = nil
        return true
    }

    /// Finishes only the native page read by this refresh's chat epoch. Cards,
    /// team and queue success are deliberately not part of this decision.
    func finishModelRecoveryRefresh(_ id: UUID, native: ArgoAgentIdentity?, epoch: UUID, problem: String?) {
        guard modelRecovery?.id == id, modelRecovery?.destination == key else { return }
        modelRecovery?.refreshing = false
        guard let native, transcript.identity == native, native.isValid, native.run == key.run,
              native.engine == "claude", ArgoRun.isManaged(key.run) else {
            invalidateModelRecoveryNativeReview()
            modelRecovery?.refreshProblem = problem ?? L10n.text("The native conversation is unavailable or does not match this Agent. Refresh again before starting another model change.")
            return
        }
        let proof = ModelRecoveryNativeProof(destination: key, identity: native, epoch: epoch)
        if let initial = modelRecovery?.nativeAtStart, initial == native {
            acceptModelRecoveryProof(proof)
        } else if let candidate = modelRecovery?.nativeCandidate,
                  candidate.destination == key, candidate.identity == native, candidate.epoch != epoch {
            acceptModelRecoveryProof(proof)
        } else {
            modelRecovery?.reviewed = false
            modelRecovery?.nativeProof = nil
            modelRecovery?.nativeCandidate = proof
            modelRecovery?.refreshProblem = L10n.text("The native conversation changed. Refresh again with the same native identity before starting another model change.")
        }
    }

    private func acceptModelRecoveryProof(_ proof: ModelRecoveryNativeProof) {
        modelRecovery?.reviewed = true
        modelRecovery?.nativeProof = proof
        modelRecovery?.nativeCandidate = nil
        modelRecovery?.refreshProblem = nil
    }

    func failModelRecoveryRefresh(_ id: UUID, problem: String?) {
        guard modelRecovery?.id == id else { return }
        modelRecovery?.refreshing = false
        modelRecovery?.refreshProblem = problem
    }

    func invalidateModelRecoveryNativeReview() {
        modelRecovery?.reviewed = false
        modelRecovery?.nativeProof = nil
        modelRecovery?.nativeCandidate = nil
    }
}
