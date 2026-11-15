import ArgoMobileKit
import Foundation
import Observation

/// The draft, transcript and delivery receipts always belong to this exact destination.
nonisolated struct SessionKey: Hashable, Sendable {
    let host: UUID
    let workspace: String
    let run: String
    let terminal: String
}

enum ConnectionStatus: Equatable {
    case disconnected, connecting, connected, suspended
    case failed(String, needsPairing: Bool)

    var isConnected: Bool { self == .connected }
    var problem: String? {
        if case .failed(let text, _) = self { return text }
        return nil
    }
    var needsPairing: Bool {
        if case .failed(_, let value) = self { return value }
        return false
    }
}

struct PendingDelivery: Identifiable {
    enum Operation {
        case message(ArgoOutgoingMessage)
        case reply(ArgoAsk, terminal: String, text: String, attempt: String)

        var text: String {
            switch self {
            case .message(let message): message.text
            case .reply(_, _, let text, _): text
            }
        }
        var attempt: String {
            switch self {
            case .message(let message): message.attempt
            case .reply(_, _, _, let attempt): attempt
            }
        }
    }

    enum Status: Equatable {
        case sending
        case delivered
        case answered
        case queued(String?)
        case pasted(String)
        case notSent(String)
        case unknown(String)
        case rejected(String)

        var canRetry: Bool {
            if case .notSent = self { return true }
            return false
        }
        var isKnownSuccess: Bool { self == .delivered || self == .answered }
    }

    let id: String
    let operation: Operation
    var attachments: [SentAttachment] = []
    let created = Date()
    var status: Status = .sending
    var duplicate = false
}

enum InterruptStatus: Equatable {
    case stopping, stopped, notWorking, idle, unconfirmed
    case unknown(String), failed(String)

    var message: String {
        switch self {
        case .stopping: L10n.text("Stopping current turn…")
        case .stopped: L10n.text("The host confirmed the turn stopped.")
        case .notWorking: L10n.text("No stop key was sent: the Agent is no longer working.")
        case .idle: L10n.text("No stop key was sent: the terminal prompt is already idle.")
        case .unconfirmed: L10n.text("The stop key was sent. The host has not confirmed the turn stopped. Refresh status before another stop.")
        case .unknown(let detail): L10n.text("The stop result is unknown. Refresh status before another stop.") + "\n" + detail
        case .failed(let detail): L10n.text("The stop request failed.") + "\n" + detail
        }
    }
}

/// Like Persona's per-conversation drafts, this survives view rebuilds and navigation.
/// Receipts are separate from the native transcript: a queue acknowledgement is never
/// drawn as though it were already a message from the CLI.
@MainActor @Observable
final class ConversationState {
    private static let successfulDeliveryLimit = 32

    let key: SessionKey
    var draft = ""
    var attachments: [DraftAttachment] = []
    var attachmentProblem: String?
    var attachmentSendID: UUID?
    @ObservationIgnored var attachmentTask: Task<Void, Never>?
    @ObservationIgnored var attachmentPreparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var lastAttachmentPreparation: Task<Void, Never>?
    var replyDrafts: [String: String] = [:]
    /// Typed model IDs and recovery receipts belong to this same SessionKey.
    var modelRecoveryDraft = ""
    var modelRecovery: ModelRecoveryOperation?
    var modelRecoveryProblem: String?
    private(set) var answeredQuestions: [String: ArgoAsk] = [:]
    var transcript = ChatTranscript()
    var team: ArgoTeamView?
    var queue: ArgoQueue?
    var deliveries: [PendingDelivery] = []
    var loading = true
    var loadingOlder = false
    var followingLatest = true
    var problem: String?
    var sessionNotice: String?
    var creation: FirstMessageSubmission?
    var interruptStatus: InterruptStatus?
    var interruptNeedsReview = false
    var refreshingInterrupt = false
    /// Exact IDs reported by question bodies that have been visible in this session.
    /// Loading team/list data alone never adds an ID here.
    @ObservationIgnored var displayedQuestionIDs: Set<String> = []
    /// Last successfully confirmed snapshot; a failed/cancelled write stays retryable.
    @ObservationIgnored var seenSignature: String?

    init(key: SessionKey) { self.key = key }

    var isSending: Bool { isMessageSending || modelRecovery?.status == .sending }
    var isInterruptBusy: Bool { interruptStatus == .stopping || refreshingInterrupt }
    /// User work and delivery evidence that cannot be reconstructed by rereading the host.
    var hasNonReloadableState: Bool {
        !attachments.isEmpty || attachmentSendID != nil || attachmentTask != nil ||
            !attachmentPreparations.isEmpty || attachmentProblem != nil ||
            modelRecovery != nil || !modelRecoveryDraft.isEmpty || modelRecoveryProblem != nil ||
            creation != nil || interruptStatus != nil || interruptNeedsReview || refreshingInterrupt ||
            !displayedQuestionIDs.isEmpty || !draft.isEmpty || replyDrafts.contains { !$0.value.isEmpty } || !answeredQuestions.isEmpty ||
            deliveries.contains { !$0.status.isKnownSuccess }
    }
    var canSendToIdentity: Bool {
        guard let identity = transcript.identity else { return false }
        return identity.isValid && identity.run == key.run && ArgoRun.isManaged(key.run)
    }

    func hasAnswered(_ ask: ArgoAsk) -> Bool { answeredQuestions[ask.uiID] != nil }

    func pendingReply(to ask: ArgoAsk) -> PendingDelivery? {
        guard let delivery = deliveries.last(where: {
            if case .reply(let question, _, _, _) = $0.operation { return question.uiID == ask.uiID }
            return false
        }) else { return nil }
        switch delivery.status {
        case .sending, .notSent, .unknown: return delivery
        default: return nil
        }
    }

    func canReply(to ask: ArgoAsk) -> Bool {
        !hasAnswered(ask) && pendingReply(to: ask) == nil && team?.asks.contains { $0.uiID == ask.uiID } == true
    }

    func append(_ delivery: PendingDelivery) {
        deliveries.append(delivery)
        trimSuccessfulDeliveries()
    }

    func recordReply(to ask: ArgoAsk, for id: String) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }),
              case .reply(let original, _, _, _) = deliveries[index].operation,
              original.uiID == ask.uiID else { return }
        // The host owns a multi-question dialog's position and InputAt claim.
        // A terminal visit can happen entirely between phone polls.
        if ask.questions <= 1 { answeredQuestions[ask.uiID] = ask }
        deliveries[index].status = .answered
        trimSuccessfulDeliveries()
    }

    /// Keep only user work and unresolved delivery evidence in a cold conversation.
    func releaseReloadableContent() {
        transcript.reset()
        team = nil
        queue = nil
        problem = nil
        loading = true
        loadingOlder = false
        followingLatest = true
        deliveries.removeAll { $0.status.isKnownSuccess }
    }

    func forget() {
        cancelAttachmentWork()
        attachmentPreparations.removeAll()
        lastAttachmentPreparation = nil
        attachments.removeAll()
        attachmentProblem = nil
        draft = ""
        replyDrafts.removeAll()
        modelRecoveryDraft = ""
        modelRecovery = nil
        modelRecoveryProblem = nil
        answeredQuestions.removeAll()
        deliveries.removeAll()
        transcript.reset()
        team = nil
        queue = nil
        problem = nil
        sessionNotice = nil
        creation = nil
        interruptStatus = nil
        interruptNeedsReview = false
        refreshingInterrupt = false
        displayedQuestionIDs.removeAll()
        seenSignature = nil
        loading = false
        loadingOlder = false
        followingLatest = true
    }

    func setStatus(_ status: PendingDelivery.Status, for id: String) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else { return }
        deliveries[index].status = status
        trimSuccessfulDeliveries()
    }

    func record(_ receipt: ArgoSendReceipt, for id: String) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else { return }
        if receipt.delivered { deliveries[index].status = .delivered }
        else if receipt.pasted { deliveries[index].status = .pasted(receipt.note) }
        else { deliveries[index].status = .queued(receipt.note) }
        deliveries[index].duplicate = receipt.duplicate
        // Keep the receipt across native-session changes, but not its old queue snapshot.
        if case .message(let message) = deliveries[index].operation,
           message.target == transcript.identity {
            queue = receipt.queue
        }
        trimSuccessfulDeliveries()
    }

    private func trimSuccessfulDeliveries() {
        var remove = deliveries.reduce(0) { $0 + ($1.status.isKnownSuccess ? 1 : 0) } - Self.successfulDeliveryLimit
        guard remove > 0 else { return }
        deliveries.removeAll { delivery in
            guard remove > 0, delivery.status.isKnownSuccess else { return false }
            remove -= 1
            return true
        }
    }

    func sessionChanged() {
        cancelAttachmentWork()
        sessionNotice = L10n.text("The terminal opened a different conversation. Your draft is kept; review the new conversation before sending.")
        transcript.reset()
        followingLatest = true
        team = nil
        queue = nil
        displayedQuestionIDs.removeAll()
        seenSignature = nil
        modelRecoveryProblem = nil
    }
}

/// A local creation note, separate from native messages and delivery receipts.
/// Identical old transcript text never upgrades this to a delivered message.
struct FirstMessageSubmission {
    let context: String
    let text: String?
}
