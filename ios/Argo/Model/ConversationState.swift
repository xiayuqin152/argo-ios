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
        case native(ArgoNativeHandoff)
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
    /// Server-owned identity for later queue reads; text is never a receipt key.
    var queueItemID: String?
    var receiptTruncatedFields: [String] = []
    var receiptItemTruncatedFields: [String] = []
}

/// One visible full-item read. It owns no send/edit action and is discarded
/// with its row or presentation, including when an identical row is refreshed.
@MainActor @Observable
final class QueueItemRead: Identifiable {
    let id = UUID()
    let key: SessionKey
    /// The presentation belongs to key; the HTTP resource can be an older run.
    let run: String
    let historyID: UUID?
    let source: ArgoQueuedMessage
    let displayed: ArgoQueuedMessage
    let identity: ArgoAgentIdentity?
    let chatIdentity: ArgoAgentIdentity?
    let queueState: String
    let ended: Bool
    let later: Bool
    let copyWhenLoaded: Bool
    var item: ArgoQueuedMessage?
    var problem: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(key: SessionKey, source: ArgoQueuedMessage, displayed: ArgoQueuedMessage, queue: ArgoQueue,
         chatIdentity: ArgoAgentIdentity?, copy: Bool, historyID: UUID? = nil) {
        self.key = key; self.source = source; self.displayed = displayed
        run = queue.run; self.historyID = historyID
        identity = queue.identity; self.chatIdentity = chatIdentity
        queueState = queue.state; ended = queue.ended
        later = queue.later.contains { $0.id == source.id }
        copyWhenLoaded = copy
    }

    func close() {
        task?.cancel(); task = nil
        item = nil; problem = nil
    }
}

/// A single read-only source window. Never feeds the current queue, receipt
/// evidence or native transcript; closing it releases every host-backed row.
@MainActor @Observable
final class NativeHistoryRead: Identifiable {
    let id = UUID()
    let key: SessionKey
    let source: ArgoNativeHistorySource
    let ownerIdentity: ArgoAgentIdentity?
    let chatIdentity: ArgoAgentIdentity?
    var queue: ArgoQueue? { didSet { closeQueueItem() } }
    var queueItemRead: QueueItemRead?
    var problem: String?
    var hideProblem: String?
    var loading = false
    var hiddenIDs: Set<String> = []
    var hidingIDs: Set<String> = []
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var loadID = UUID()
    @ObservationIgnored var hideTasks: [String: Task<Void, Never>] = [:]

    init(key: SessionKey, source: ArgoNativeHistorySource, ownerIdentity: ArgoAgentIdentity?,
         chatIdentity: ArgoAgentIdentity?) {
        self.key = key; self.source = source
        self.ownerIdentity = ownerIdentity; self.chatIdentity = chatIdentity
    }

    var rows: [ArgoQueuedMessage] {
        ((queue?.items ?? []) + (queue?.later ?? [])).filter {
            ($0.native != nil || !$0.deliveryUnknown.isEmpty) && $0.target == source.target && !hiddenIDs.contains($0.id)
        }
    }

    func closeQueueItem() {
        queueItemRead?.close()
        queueItemRead = nil
    }

    func close() {
        loadID = UUID()
        task?.cancel(); task = nil
        for task in hideTasks.values { task.cancel() }
        hideTasks.removeAll()
        hidingIDs.removeAll()
        closeQueueItem()
        queue = nil
        hiddenIDs.removeAll()
        problem = nil; hideProblem = nil; loading = false
    }
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
    var queue: ArgoQueue? {
        didSet {
            closeQueueItem()
            if let read = nativeHistoryRead,
               queue?.run != key.run || queue?.ws != key.workspace || queue?.identity != read.ownerIdentity ||
                !(queue?.nativeSources ?? []).contains(read.source) {
                closeNativeHistory()
            }
            reconcileQueueReceipts()
        }
    }
    var queueItemRead: QueueItemRead?
    var nativeHistoryRead: NativeHistoryRead?
    var deliveries: [PendingDelivery] = []
    /// Session-owned evidence may arrive before POST binds its server item ID.
    private var queueEvidence: [String: ArgoQueuedMessage] = [:]
    private var hiddenNativeIDs: Set<String> = []
    var hidingNativeIDs: Set<String> = []
    var nativeHideProblem: String?
    var loading = true
    var loadingOlder = false
    var followingLatest = true
    var problem: String?
    var sessionNotice: String?
    /// Input owners follow explicit native-session invalidation, not initial loading.
    private(set) var nativeConversationGeneration = UUID()
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
        !hidingNativeIDs.isEmpty || nativeHideProblem != nil ||
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
    /// The caller supplies live request IDs; receipt status is not a task lifetime.
    func releaseReloadableContent(inFlightDeliveryIDs: Set<String> = []) {
        transcript.reset()
        team = nil
        queue = nil
        problem = nil
        loading = true
        loadingOlder = false
        followingLatest = true
        deliveries.removeAll { $0.status.isKnownSuccess }
        let awaitingItemID = deliveries.contains { delivery in
            guard case .message = delivery.operation else { return false }
            return delivery.queueItemID == nil && inFlightDeliveryIDs.contains(delivery.id)
        }
        if !awaitingItemID {
            let retainedIDs = Set(deliveries.compactMap(\.queueItemID))
            queueEvidence = queueEvidence.filter { retainedIDs.contains($0.key) }
        }
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
        queueEvidence.removeAll()
        hiddenNativeIDs.removeAll()
        hidingNativeIDs.removeAll()
        nativeHideProblem = nil
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
        deliveries[index].queueItemID = receipt.queued?.id
        deliveries[index].receiptTruncatedFields = receipt.truncatedFields
        deliveries[index].receiptItemTruncatedFields = receipt.queued?.truncatedFields ?? []
        if let item = receipt.queued, hiddenNativeIDs.contains(item.id) {
            deliveries.remove(at: index)
            return // A late POST must not restore an explicitly hidden record.
        }
        if let item = receipt.queued { rememberQueueEvidence(item) }
        // GET can identify the handoff before POST reveals this attempt's item ID.
        reconcileQueueReceipts()
        if let item = receipt.queued, let native = nativeRecord(for: item)?.native {
            deliveries[index].status = .native(native)
        } else if let item = receipt.queued, let reason = deliveryUnknown(for: item) {
            deliveries[index].status = .unknown(reason)
        } else if receipt.delivered { deliveries[index].status = .delivered }
        else if receipt.pasted { deliveries[index].status = .pasted(receipt.note) }
        else { deliveries[index].status = .queued(receipt.note) }
        deliveries[index].duplicate = receipt.duplicate
        // A queue read may finish before this receipt supplies its item ID.
        reconcileQueueReceipts()
        // Keep the receipt across native-session changes, but not its old queue snapshot.
        if case .message(let message) = deliveries[index].operation,
           message.target == transcript.identity {
            queue = receipt.queue
        }
        trimSuccessfulDeliveries()
    }

    /// Keep explicit unknown evidence through stale queue snapshots. Absence
    /// from a queue or matching transcript text never establishes delivery.
    func deliveryUnknown(for item: ArgoQueuedMessage) -> String? {
        if !item.deliveryUnknown.isEmpty { return item.deliveryUnknown }
        if let evidence = queueEvidence[item.id], !evidence.deliveryUnknown.isEmpty { return evidence.deliveryUnknown }
        if let delivery = deliveries.first(where: { $0.queueItemID == item.id }),
           case .unknown(let reason) = delivery.status { return reason }
        return nil
    }

    private func reconcileQueueReceipts() {
        guard let queue, queue.run == key.run else { return }
        for item in queue.items + queue.later { rememberQueueEvidence(item) }
        for index in deliveries.indices {
            guard let id = deliveries[index].queueItemID else { continue }
            if let evidence = queueEvidence[id] { deliveries[index].receiptItemTruncatedFields = evidence.truncatedFields }
            if let native = queueEvidence[id]?.native {
                deliveries[index].status = .native(native)
            } else if let item = queueEvidence[id], !item.deliveryUnknown.isEmpty {
                deliveries[index].status = .unknown(item.deliveryUnknown)
            }
        }
    }

    private func rememberQueueEvidence(_ item: ArgoQueuedMessage) {
        guard item.native != nil || !item.deliveryUnknown.isEmpty, !hiddenNativeIDs.contains(item.id) else { return }
        // Old ordinary snapshots cannot erase a known native handoff.
        if queueEvidence[item.id]?.native != nil, item.native == nil { return }
        // An explicit accepted receipt is stronger than an earlier pre-written
        // unknown snapshot. It still says nothing about model completion.
        if queueEvidence[item.id]?.native?.state == .accepted, item.native?.unrecognizedState == nil { return }
        queueEvidence[item.id] = item
    }

    func nativeRecord(for item: ArgoQueuedMessage) -> ArgoQueuedMessage? {
        guard !hiddenNativeIDs.contains(item.id) else { return nil }
        let evidence = queueEvidence[item.id] ?? item
        return evidence.native == nil ? nil : evidence
    }

    var allQueueItems: [ArgoQueuedMessage] { (queue?.items ?? []) + (queue?.later ?? []) }
    var nativeQueueItems: [ArgoQueuedMessage] { allQueueItems.compactMap { nativeRecord(for: $0) } }
    var ordinaryQueueItems: [ArgoQueuedMessage] {
        allQueueItems.filter { !hiddenNativeIDs.contains($0.id) && nativeRecord(for: $0) == nil }
    }
    var pendingQueueCount: Int {
        guard let queue else { return 0 }
        guard let pending = queue.pending else { return ordinaryQueueItems.count }
        // A late ordinary snapshot cannot make a known native record sendable.
        let stale = allQueueItems.filter { $0.native == nil && (queueEvidence[$0.id]?.native != nil || hiddenNativeIDs.contains($0.id)) }.count
        return max(0, pending - stale)
    }
    var nativeHistoryCount: Int {
        guard let queue else { return 0 }
        let hidden = allQueueItems.filter { $0.native != nil && hiddenNativeIDs.contains($0.id) }.count
        var local = max(0, queue.nativeHistory)
        for source in queue.nativeSources ?? [] {
            local -= min(local, max(0, source.nativeHistory))
        }
        return max(nativeQueueItems.count, local - hidden)
    }
    var nativeHistorySources: [ArgoNativeHistorySource] { queue?.nativeSources ?? [] }
    var deliveryReceipts: [PendingDelivery] {
        let shown = Set(nativeQueueItems.map(\.id))
        return deliveries.filter { $0.queueItemID.map { !shown.contains($0) && !hiddenNativeIDs.contains($0) } ?? true }
    }

    func didHideNativeRecord(_ id: String) {
        if queueItemRead?.source.id == id { closeQueueItem() }
        hiddenNativeIDs.insert(id)
        queueEvidence[id] = nil
        deliveries.removeAll { $0.queueItemID == id }
    }

    func closeQueueItem() {
        queueItemRead?.close()
        queueItemRead = nil
    }

    func closeNativeHistory() {
        nativeHistoryRead?.close()
        nativeHistoryRead = nil
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
        nativeConversationGeneration = UUID()
        cancelAttachmentWork()
        sessionNotice = L10n.text("The terminal opened a different conversation. Your draft is kept; review the new conversation before sending.")
        transcript.reset()
        followingLatest = true
        team = nil
        queue = nil
        displayedQuestionIDs.removeAll()
        seenSignature = nil
        invalidateModelRecoveryNativeReview()
        modelRecoveryProblem = nil
    }
}

/// A local creation note, separate from native messages and delivery receipts.
/// Identical old transcript text never upgrades this to a delivered message.
struct FirstMessageSubmission {
    let context: String
    let text: String?
}
