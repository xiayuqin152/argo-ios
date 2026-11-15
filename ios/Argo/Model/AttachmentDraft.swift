import ArgoMobileKit
import Foundation

/// A user-selected source. The picker adapter owns any scope/coordinator; only
/// its private, bounded copy crosses into the conversation model.
nonisolated struct AttachmentInput: Sendable {
    let name: String
    let kind: ArgoLocalAttachment.Kind
    let prepare: @Sendable () async throws -> ArgoLocalAttachment
}

struct DraftAttachment: Identifiable {
    enum Phase: Equatable {
        case waiting, preparing, readyLocal, uploading, readyRemote
        case failed(String)
    }
    let id: UUID
    let name: String
    let kind: ArgoLocalAttachment.Kind
    let identity: ArgoAgentIdentity
    var phase: Phase = .waiting
    var local: ArgoLocalAttachment?
    var remote: ArgoUploadedFile?
}

struct SentAttachment {
    let local: ArgoLocalAttachment
    let remote: ArgoUploadedFile
}

extension ConversationState {
    func prepareAttachments(_ inputs: [AttachmentInput], identity: ArgoAgentIdentity, start: Bool) {
        guard attachments.count + inputs.count <= ArgoAttachmentPolicy.countLimit else {
            attachmentProblem = L10n.text("Up to 4 attachments per message.")
            return
        }
        guard attachmentSendID == nil, identity.isValid, identity.run == key.run else { return }
        attachmentProblem = nil
        for input in inputs {
            let id = UUID()
            attachments.append(DraftAttachment(id: id, name: input.name, kind: input.kind, identity: identity))
            guard start else {
                updateAttachment(id) { $0.phase = .failed(L10n.text("Attachment preparation cancelled. Remove it and select it again.")) }
                continue
            }
            let preceding = lastAttachmentPreparation
            let task = Task { [weak self] in
                await preceding?.value
                guard let self else { return }
                defer { attachmentPreparations[id] = nil }
                do {
                    try Task.checkCancellation()
                    updateAttachment(id) { $0.phase = .preparing }
                    let file = try await input.prepare()
                    try Task.checkCancellation()
                    // A removed selection or forgotten host never regains a file
                    // from an iCloud/provider callback that finished late.
                    updateAttachment(id) { $0.local = file; $0.phase = .readyLocal }
                } catch {
                    updateAttachment(id) { $0.phase = .failed(L10n.error(error)) }
                }
            }
            attachmentPreparations[id] = task
            lastAttachmentPreparation = task
        }
    }

    func updateAttachment(_ id: UUID, _ change: (inout DraftAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[index])
    }

    func removeAttachment(_ id: UUID) {
        guard attachments.contains(where: { $0.id == id }) else { return }
        cancelAttachmentSend()
        attachmentPreparations.removeValue(forKey: id)?.cancel()
        attachments.removeAll { $0.id == id }
        attachmentProblem = nil
    }

    func cancelAttachmentSend() {
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentSendID = nil
        for i in attachments.indices where attachments[i].phase == .uploading {
            // Cancellation can race a completed upload. Keep that evidence with
            // the owned local file instead of relabeling it as never uploaded.
            let problem = L10n.fileError(ArgoClientError.deliveryUnknown(.message("The operation was cancelled.")))
            attachments[i].phase = .failed(problem)
            attachmentProblem = problem
        }
    }

    /// Leaving the destination/background stops work and retains its original
    /// draft. Selecting files again is explicit after cancelled preparation.
    func cancelAttachmentWork() {
        cancelAttachmentSend()
        for task in attachmentPreparations.values { task.cancel() }
        for i in attachments.indices {
            switch attachments[i].phase {
            case .waiting, .preparing:
                attachments[i].phase = .failed(L10n.text("Attachment preparation cancelled. Remove it and select it again."))
            default: break
            }
        }
    }
}
