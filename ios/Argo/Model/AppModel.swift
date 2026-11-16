import ArgoMobileKit
import Foundation
import Observation
#if canImport(SwiftUI)
import SwiftUI
#endif

private struct ModelRecoveryReadClaim {
    let chat: UUID
    let list: UUID
    let native: ArgoAgentIdentity?
}

/// Thin UI adapter for ArgoMobileKit. No endpoint, TLS or credential logic lives here.
@MainActor @Observable
final class AppModel {
    private static let retainedTranscriptLimit = 4

    typealias ConnectionFactory = @Sendable (LoomHost, GatewayCredential) throws -> ArgoConnection

    private(set) var hosts: [LoomHost] = []
    private(set) var hostID: UUID?
    private(set) var projects: [ArgoProject] = []
    private(set) var workspaces: [ArgoWorkspace] = []
    private(set) var workspaceID: String?
    private(set) var agents: [ArgoAgentCard] = []
    private(set) var selectedKey: SessionKey?
    private(set) var status: ConnectionStatus = .disconnected
    private(set) var server: ArgoServerInfo?
    private(set) var loadingHosts = true
    private(set) var loadingAgents = false
    private(set) var refreshingAgents = false
    private(set) var hostProblem: String?
    private(set) var pairing = false
    private(set) var pairingProblem: String?
    private(set) var pairedHostID: UUID?
    private(set) var conversationVisible = false
    private var seenPresentationOwners: Set<SeenPresentationOwner> = []
    var seenAdmissionAllowed: Bool { conversationVisible && seenPresentationOwners.isEmpty }
    var notificationProblem: String?
    var search = ""
    var filter: AgentFilter = .all
    let newSession: NewSessionModel
    let newSessionPresentation = SeenPresentation()
    var newSessionShown: Bool {
        get { newSessionPresentation.isPresented }
        set { newSessionPresentation.setPresented(newValue, in: self) }
    }

    @ObservationIgnored private let store: ArgoHostStore
    @ObservationIgnored private let makeConnection: ConnectionFactory
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored var unregisterNotifications: (@MainActor (UUID) async throws -> Void)?
    @ObservationIgnored var prepareNotificationsForPairing: (@MainActor (UUID) async throws -> Void)?
    @ObservationIgnored var restoreNotificationsAfterPairing: (@MainActor (UUID) async -> Void)?
    @ObservationIgnored private var notificationRoute: ArgoPushRoute?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var connection: ArgoConnection?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var hostEpoch = UUID()
    @ObservationIgnored private var listEpoch = UUID()
    @ObservationIgnored private var chatEpoch = UUID()
    @ObservationIgnored private var workspaceEpoch = UUID()
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var pairTask: Task<Void, Never>?
    @ObservationIgnored private var seenTask: Task<Void, Never>?
    @ObservationIgnored private var seenEpoch = UUID()
    @ObservationIgnored private var sends: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var interrupts: [SessionKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var conversationOrder: [SessionKey] = []
    private var conversations: [SessionKey: ConversationState] = [:]

    init(store: ArgoHostStore, announce: @escaping @MainActor (String) -> Void = { _ in },
         pendingCreations: any PendingCreationStoring = PendingCreationFile(),
         makeConnection: @escaping ConnectionFactory) {
        self.store = store
        self.newSession = NewSessionModel(store: pendingCreations)
        self.announce = announce
        self.makeConnection = makeConnection
    }

    var selectedHost: LoomHost? { hosts.first { $0.id == hostID } }
    var selectedWorkspace: ArgoWorkspace? { workspaces.first { $0.id == workspaceID } }
    var selectedAgent: ArgoAgentCard? { agents.first { $0.run == selectedKey?.run && $0.terminal == selectedKey?.terminal } }
    var conversation: ConversationState? { selectedKey.flatMap { conversations[$0] } }
    var acceptsComposerInput: Bool { active }

    var showsInterrupt: Bool {
        guard let state = conversation, let card = selectedAgent,
              state.canSendToIdentity, card.state == "working", card.status != "stopped",
              state.transcript.identity?.engine == card.engine else { return false }
        return ["claude", "codex"].contains(card.engine)
    }

    var canInterrupt: Bool {
        showsInterrupt && active && conversationVisible && status.isConnected &&
            conversation?.isInterruptBusy == false && conversation?.interruptNeedsReview == false &&
            conversation?.isSending == false
    }

    var visibleAgents: [ArgoAgentCard] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return agents.filter { card in
            filter.includes(AgentSession(card)) && (query.isEmpty ||
                [card.displayTitle, card.activity, card.reply, card.cli, card.profile, card.run]
                    .contains { $0.localizedStandardContains(query) })
        }.sorted { a, b in
            if a.attention != b.attention { return a.attention > b.attention }
            return ArgoTime.isLater(a.updated, than: b.updated)
        }
    }

    func loadHosts() async {
        loadingHosts = true
        defer { loadingHosts = false }
        do {
            hosts = try await store.hosts()
            hostProblem = nil
            if !hosts.contains(where: { $0.id == hostID }) { selectHost(hosts.first?.id) }
        } catch { hostProblem = L10n.error(error) }
    }

    func removeHost(_ id: UUID) async throws {
        try await unregisterNotifications?(id)
        // Preserve UI state until both metadata and credential removal succeed.
        // A failed credential deletion restores metadata or reports its rollback.
        try await store.remove(id)
        newSession.forgetHost(id)
        hosts.removeAll { $0.id == id }
        if hostID == id { selectHost(hosts.first?.id) }
        if pairedHostID == id { pairedHostID = nil }
        for (key, state) in conversations where key.host == id {
            interrupts.removeValue(forKey: key)?.cancel()
            for delivery in state.deliveries {
                sends.removeValue(forKey: delivery.id)?.cancel()
            }
            if let recovery = state.modelRecovery {
                sends.removeValue(forKey: recovery.id.uuidString)?.cancel()
            }
            // Views and cancelled requests can still retain this object. Clear it
            // as well as the cache so a late receipt cannot restore forgotten data.
            state.forget()
            conversations.removeValue(forKey: key)
        }
        conversationOrder.removeAll { $0.host == id }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value { reconnect() } else {
            pairTask?.cancel()
            invalidateConnection()
            pruneConversations()
            status = .suspended
        }
    }

    func selectHost(_ id: UUID?) {
        guard hostID != id else { return }
        notificationTask?.cancel()
        if notificationRoute?.hostID != id { notificationRoute = nil }
        invalidateConnection()
        hostID = id
        newSession.selectHost(id)
        workspaceID = nil
        selectedKey = nil
        conversationVisible = false
        discardUnselectedSeenPresentations()
        pruneConversations()
        projects = []
        workspaces = []
        agents = []
        search = ""
        server = nil
        status = .disconnected
        reconnect()
    }

    func reconnect() {
        guard active, let host = selectedHost else { return }
        invalidateConnection()
        let epoch = hostEpoch
        status = .connecting
        connectTask = Task { [weak self] in
            guard let self else { return }
            var opened: ArgoConnection?
            do {
                // A cancelled re-pair can still finish its synchronous save.
                // Resolve the selected UUID again so its new pin/device and
                // token are used together without changing the selection.
                guard let currentHost = try await store.hosts().first(where: { $0.id == host.id }) else {
                    throw ArgoClientError.needsPairing(.message("This host was removed or paired again. Select the host again."))
                }
                let credential = try await store.credential(for: currentHost)
                try Task.checkCancellation()
                guard isCurrentHost(epoch) else { return }
                if let index = hosts.firstIndex(where: { $0.id == currentHost.id }) { hosts[index] = currentHost }
                let client = try makeConnection(currentHost, credential)
                opened = client
                connection = client
                let hello = try await client.connect()
                async let allProjects = client.projects()
                async let allWorkspaces = client.workspaces()
                let catalog = try await (allProjects, allWorkspaces)
                try Task.checkCancellation()
                guard isCurrentHost(epoch) else { await client.close(); return }
                server = hello
                projects = catalog.0
                workspaces = catalog.1
                status = .connected
                if !workspaces.contains(where: { $0.id == workspaceID }) {
                    selectWorkspace(workspaces.first?.id)
                } else {
                    startAgentPolling()
                    startConversationPolling()
                }
                resolveNotification()
                newSession.loadProfiles(from: client)
                for intent in newSession.pending where intent.host == host.id && intent.receipt == nil {
                    newSession.reconcile(intent, using: client) { [weak self] in self?.adoptCreation($0, navigate: false) }
                }
            } catch {
                if let opened { await opened.close() }
                guard isCurrentHost(epoch) else { return }
                failConnection(error)
            }
        }
    }

    func selectWorkspace(_ id: String?) {
        guard workspaceID != id else { return }
        cancelConversationRequests()
        listTask?.cancel()
        listEpoch = UUID()
        workspaceID = id
        workspaceEpoch = UUID()
        newSession.present(host: hostID, workspace: selectedWorkspace)
        selectedKey = nil
        conversationVisible = false
        discardUnselectedSeenPresentations()
        pruneConversations()
        agents = []
        search = ""
        startAgentPolling()
    }

    func openNotification(_ route: ArgoPushRoute) {
        guard hosts.contains(where: { $0.id == route.hostID && $0.deviceID == route.deviceID }) else { return }
        notificationRoute = route
        notificationProblem = nil
        let sameHost = hostID == route.hostID
        selectHost(route.hostID)
        if status.isConnected { resolveNotification() }
        else if sameHost { reconnect() }
    }

    /// A tap resolves the current directory through GETs. No payload may
    /// manufacture a card, start/resume a run, or send a conversation POST.
    private func resolveNotification() {
        guard let route = notificationRoute, validateNotificationRoute(route),
              active, status.isConnected, let connection else { return }
        notificationTask?.cancel()
        let epoch = hostEpoch
        let navigationWorkspace = workspaceEpoch
        let navigationChat = chatEpoch
        notificationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await connection.workspaces()
                guard isCurrentHost(epoch), validateNotificationRoute(route) else { return }
                guard workspaceEpoch == navigationWorkspace, chatEpoch == navigationChat else {
                    notificationRoute = nil
                    return
                }
                guard catalog.contains(where: { $0.id == route.workspace }) else {
                    throw ArgoClientError.refusedLocally(.message("This notification's workspace is no longer available."))
                }
                let cards = try await connection.agents(workspace: route.workspace)
                try Task.checkCancellation()
                guard isCurrentHost(epoch), validateNotificationRoute(route) else { return }
                guard workspaceEpoch == navigationWorkspace, chatEpoch == navigationChat else {
                    notificationRoute = nil
                    return
                }
                guard let card = cards.first(where: { $0.ws == route.workspace && $0.run == route.run }) else {
                    throw ArgoClientError.refusedLocally(.message("This notification's Agent is no longer available."))
                }
                workspaces = catalog
                selectWorkspace(route.workspace)
                agents = cards
                notificationRoute = nil
                selectSession(key(for: card))
            } catch {
                guard isCurrentHost(epoch), validateNotificationRoute(route) else { return }
                notificationRoute = nil
                guard workspaceEpoch == navigationWorkspace, chatEpoch == navigationChat else { return }
                notificationProblem = L10n.error(error)
            }
        }
    }

    private func validateNotificationRoute(_ route: ArgoPushRoute) -> Bool {
        guard notificationRoute == route else { return false }
        // Re-pairing keeps the host UUID but replaces its device credential.
        // A reconnect may resume a tap only while that pairing still owns it.
        guard hostID == route.hostID, selectedHost?.deviceID == route.deviceID else {
            notificationRoute = nil
            return false
        }
        return true
    }

    func key(for card: ArgoAgentCard) -> SessionKey? {
        guard let hostID, card.ws == workspaceID else { return nil }
        return SessionKey(host: hostID, workspace: card.ws, run: card.run, terminal: card.terminal)
    }

    /// A missing card is ambiguous because the two list GETs are not atomic.
    /// Only the terminal's own lifecycle/current owner can retire a selection.
    private func selectionEnded(_ key: SessionKey, terminals: [ArgoTerminalView]) -> Bool {
        guard let terminal = terminals.first(where: { $0.id == key.terminal && $0.ws == key.workspace }) else { return false }
        if terminal.alive == false { return true }
        guard terminal.alive == true else { return false }
        if let owner = terminal.agent { return ArgoRun.isManaged(owner.run) && owner.run != key.run }
        let currentRun = terminal.unmanaged.map { _ in "unmanaged:" + terminal.id }
        return currentRun != key.run
    }

    func selectSession(_ key: SessionKey?) {
        if let key {
            guard key.host == hostID, key.workspace == workspaceID,
                  (agents.contains(where: { self.key(for: $0) == key }) ||
                   newSession.pending.contains(where: { $0.key == key })) else { return }
        }
        guard selectedKey != key else { return }
        cancelConversationRequests()
        selectedKey = key
        conversationVisible = false
        discardUnselectedSeenPresentations()
        if let key {
            if conversations[key] == nil { conversations[key] = ConversationState(key: key) }
            conversationOrder.removeAll { $0 == key }
            conversationOrder.append(key)
        }
        if let key, let intent = newSession.pending.first(where: { $0.key == key }), conversations[key]?.creation == nil {
            conversations[key]?.creation = FirstMessageSubmission(context: intent.context, text: newSession.prompt(for: intent.context))
        }
        pruneConversations()
    }

    func showConversation(_ key: SessionKey, visible: Bool) {
        guard key == selectedKey else { return }
        conversationVisible = visible
        if visible {
            startConversationPolling()
            markSelectedConversationSeen()
        } else { cancelConversationRequests() }
    }

    /// Modal coverage affects only seen admission and its pending dispatch.
    /// Sending, uploads, creation and conversation reads keep their own lifecycle.
    func pauseSeen(for owner: SeenPresentationOwner) {
        guard owner.conversation == nil || owner.conversation == selectedKey else { return }
        let wasEmpty = seenPresentationOwners.isEmpty
        guard seenPresentationOwners.insert(owner).inserted else { return }
        if wasEmpty { cancelSeen() }
    }

    func resumeSeen(for owner: SeenPresentationOwner) {
        seenPresentationOwners.remove(owner)
        // QuestionCard observes seenAdmissionAllowed and reports the current
        // ask/key only if its body is still in the viewport. Keep displayed IDs.
    }

    private func discardUnselectedSeenPresentations() {
        // Navigation has removed this Chat branch. Root/other presenters retain
        // their owners; an old branch's eventual onDismiss cannot remove them.
        seenPresentationOwners = seenPresentationOwners.filter {
            $0.conversation == nil || $0.conversation == selectedKey
        }
    }

    func refreshConversation() {
        conversation?.closeQueueItem()
        conversation?.closeNativeHistory()
        if let state = conversation, !state.followingLatest, state.transcript.identity != nil {
            readWindow(.around(state.transcript.start), followingLatest: false)
        } else { startConversationPolling() }
    }

    func openQueueItem(_ item: ArgoQueuedMessage, for key: SessionKey, copy: Bool = false) {
        guard active, conversationVisible, selectedKey == key, let state = conversations[key], let queue = state.queue,
              let source = state.allQueueItems.first(where: { $0.id == item.id }),
              (state.nativeRecord(for: source) ?? source) == item else { return }
        state.closeQueueItem()
        let read = QueueItemRead(key: key, source: source, displayed: item, queue: queue,
                                 chatIdentity: state.transcript.identity, copy: copy)
        state.queueItemRead = read
        // Even an untruncated preview may predate a host edit or removal.
        // Copy/view must read the current item and validate its revision.
        guard status.isConnected, let connection, connection.host.id == key.host,
              queue.run == key.run, queue.ws == key.workspace, let identity = queue.identity, identity.run == key.run else {
            read.problem = L10n.text("The queue item changed. Refresh the conversation.")
            return
        }
        loadQueueItem(read, using: connection)
    }

    private func loadQueueItem(_ read: QueueItemRead, using connection: ArgoConnection) {
        let epoch = hostEpoch
        read.task = Task { [weak self, weak read] in
            guard let self, let read else { return }
            defer { read.task = nil }
            do {
                let full = try await connection.queueItem(run: read.run, itemID: read.source.id)
                try Task.checkCancellation()
                guard isCurrentHost(epoch), self.connection === connection else { return }
                guard queueReadIsCurrent(read) else { closeQueueItem(read); return }
                // The displayed row may carry an accepted ACK stronger than
                // the raw queue's old ordinary/unknown snapshot.
                guard full.run == read.run, full.ws == read.key.workspace, full.identity == read.identity, full.state == read.queueState,
                      full.ended == read.ended, full.later == read.later, read.displayed.matchesFullItem(full.item) else {
                    throw ArgoClientError.invalidResponse(.message("The queue item changed. Refresh the conversation."))
                }
                read.item = full.item
            } catch {
                guard !Task.isCancelled, isCurrentHost(epoch) else { return }
                guard queueReadIsCurrent(read) else { closeQueueItem(read); return }
                read.problem = L10n.error(error)
            }
        }
    }

    private func queueReadIsCurrent(_ read: QueueItemRead) -> Bool {
        guard active, conversationVisible, selectedKey == read.key, let state = conversations[read.key],
              state.transcript.identity == read.chatIdentity else { return false }
        if let historyID = read.historyID {
            guard let history = state.nativeHistoryRead, history.id == historyID, nativeHistoryIsCurrent(history),
                  history.queueItemRead === read, history.queue?.identity == read.identity,
                  history.source.sourceRun == read.run else { return false }
            return history.rows.contains(read.source) && read.source == read.displayed
        }
        guard state.queueItemRead === read, read.run == read.key.run,
              state.queue?.identity == read.identity,
              let row = state.allQueueItems.first(where: { $0.id == read.source.id }) else { return false }
        return row == read.source && (state.nativeRecord(for: row) ?? row) == read.displayed
    }

    func queueItemText(_ read: QueueItemRead) -> String? {
        guard queueReadIsCurrent(read), let item = read.item, item.isComplete("text") else { return nil }
        return item.text
    }

    func closeQueueItem(_ read: QueueItemRead) {
        if let historyID = read.historyID {
            guard let history = conversations[read.key]?.nativeHistoryRead, history.id == historyID,
                  history.queueItemRead === read else { return }
            history.closeQueueItem()
            return
        }
        guard let state = conversations[read.key], state.queueItemRead === read else { return }
        state.closeQueueItem()
    }

    func openNativeHistory(_ source: ArgoNativeHistorySource, for key: SessionKey) {
        guard active, conversationVisible, selectedKey == key, let state = conversations[key],
              state.nativeHistorySources.contains(source) else { return }
        state.closeQueueItem()
        state.closeNativeHistory()
        let read = NativeHistoryRead(key: key, source: source, ownerIdentity: state.queue?.identity,
                                     chatIdentity: state.transcript.identity)
        state.nativeHistoryRead = read
        guard nativeHistoryIsCurrent(read) else {
            read.problem = L10n.text("The original handoff source changed. Refresh the conversation.")
            return
        }
        refreshNativeHistory(read)
    }

    private func nativeHistoryIsCurrent(_ read: NativeHistoryRead) -> Bool {
        guard active, conversationVisible, selectedKey == read.key, let state = conversations[read.key],
              state.nativeHistoryRead === read, state.transcript.identity == read.chatIdentity,
              state.queue?.run == read.key.run, state.queue?.ws == read.key.workspace,
              state.queue?.identity == read.ownerIdentity else { return false }
        return state.nativeHistorySources.contains(read.source)
    }

    func refreshNativeHistory(_ read: NativeHistoryRead) {
        guard nativeHistoryIsCurrent(read), read.hidingIDs.isEmpty else { return }
        read.task?.cancel()
        read.closeQueueItem()
        read.queue = nil
        read.problem = nil
        guard status.isConnected, let connection, connection.host.id == read.key.host,
              let owner = read.ownerIdentity, owner.isValid, owner.run == read.key.run,
              owner == read.chatIdentity, read.source.nativeHistory > 0,
              ArgoRun.isManaged(read.source.sourceRun), read.source.sourceRun != read.key.run,
              read.source.target.isValid, read.source.target.run == read.source.sourceRun,
              read.source.target.engine == owner.engine, read.source.target.session == owner.session else {
            read.loading = false
            read.problem = L10n.text("The original handoff source changed. Refresh the conversation.")
            return
        }
        let epoch = hostEpoch
        let loadID = UUID()
        read.loadID = loadID
        read.loading = true
        read.task = Task { [weak self, weak read] in
            guard let self, let read else { return }
            defer {
                if read.loadID == loadID { read.loading = false; read.task = nil }
            }
            do {
                let queue = try await connection.queue(run: read.source.sourceRun)
                try Task.checkCancellation()
                guard isCurrentHost(epoch), self.connection === connection, nativeHistoryIsCurrent(read),
                      read.loadID == loadID else { return }
                guard queue.run == read.source.sourceRun, queue.ws == read.key.workspace,
                      queue.identity == read.source.target else {
                    throw ArgoClientError.invalidResponse(.message("The original handoff source changed. Refresh the conversation."))
                }
                read.queue = queue
                read.hideProblem = nil
                if read.rows.isEmpty && read.hiddenIDs.isEmpty {
                    read.problem = L10n.text("No matching original handoff records were returned. Refresh the conversation.")
                }
            } catch {
                guard !Task.isCancelled, isCurrentHost(epoch), self.connection === connection,
                      nativeHistoryIsCurrent(read), read.loadID == loadID else { return }
                read.problem = L10n.error(error)
            }
        }
    }

    func closeNativeHistory(_ read: NativeHistoryRead) {
        guard let state = conversations[read.key], state.nativeHistoryRead === read else { return }
        state.closeNativeHistory()
    }

    func openNativeHistoryItem(_ item: ArgoQueuedMessage, in history: NativeHistoryRead, copy: Bool = false) {
        guard nativeHistoryIsCurrent(history), let queue = history.queue, history.rows.contains(item),
              status.isConnected, let connection, connection.host.id == history.key.host else { return }
        history.closeQueueItem()
        let read = QueueItemRead(key: history.key, source: item, displayed: item, queue: queue,
                                 chatIdentity: history.chatIdentity, copy: copy, historyID: history.id)
        history.queueItemRead = read
        loadQueueItem(read, using: connection)
    }

    func hideNativeHistoryItem(_ item: ArgoQueuedMessage, in read: NativeHistoryRead) {
        guard nativeHistoryIsCurrent(read), status.isConnected, let connection,
              connection.host.id == read.key.host, read.rows.contains(item), read.hideProblem == nil,
              !read.hidingIDs.contains(item.id) else { return }
        read.hidingIDs.insert(item.id)
        let epoch = hostEpoch
        read.hideTasks[item.id] = Task { [weak self, weak read] in
            guard let self, let read else { return }
            defer { read.hideTasks[item.id] = nil; read.hidingIDs.remove(item.id) }
            do {
                try await connection.hideNativeHandoff(run: read.source.sourceRun, itemID: item.id)
                try Task.checkCancellation()
                guard isCurrentHost(epoch), self.connection === connection, nativeHistoryIsCurrent(read) else { return }
                read.hiddenIDs.insert(item.id)
                if read.queueItemRead?.source.id == item.id { read.closeQueueItem() }
                startConversationPolling()
                refreshAgents()
            } catch {
                guard !Task.isCancelled, isCurrentHost(epoch), self.connection === connection,
                      nativeHistoryIsCurrent(read) else { return }
                let detail: String
                switch error {
                case ArgoClientError.deliveryUnknown(let reason): detail = L10n.error(ArgoClientError.invalidResponse(reason))
                case ArgoClientError.http(let status, let message, _): detail = message.isEmpty ? "HTTP \(status)" : message
                default: detail = L10n.error(error)
                }
                read.hideProblem = L10n.text("Hiding was not confirmed. Refresh the records before trying again. Codex input is unchanged.") + "\n" + detail
            }
        }
    }

    /// This removes only the selected Argo status record, including records
    /// for an earlier native thread. It never sends or cancels Agent input.
    func hideNativeHandoff(_ item: ArgoQueuedMessage, for key: SessionKey) {
        guard active, selectedKey == key, let state = conversations[key],
              status.isConnected, let connection, state.queue?.run == key.run,
              state.nativeQueueItems.contains(where: { $0.id == item.id }),
              !state.hidingNativeIDs.contains(item.id) else { return }
        state.hidingNativeIDs.insert(item.id)
        state.nativeHideProblem = nil
        let epoch = hostEpoch
        Task { [weak self] in
            guard let self else { return }
            defer { state.hidingNativeIDs.remove(item.id) }
            do {
                try await connection.hideNativeHandoff(run: key.run, itemID: item.id)
                guard conversations[key] === state else { return }
                state.didHideNativeRecord(item.id)
                if isCurrentHost(epoch), selectedKey == key {
                    refreshConversation()
                    refreshAgents()
                }
            } catch {
                guard conversations[key] === state else { return }
                let detail: String
                switch error {
                case ArgoClientError.deliveryUnknown(let reason): detail = L10n.error(ArgoClientError.invalidResponse(reason))
                case ArgoClientError.http(let status, let message, _): detail = message.isEmpty ? "HTTP \(status)" : message
                default: detail = L10n.error(error)
                }
                state.nativeHideProblem = L10n.text("Hiding was not confirmed. Refresh the records before trying again. Codex input is unchanged.") + "\n" + detail
            }
        }
    }
    var agentRefreshAvailable: Bool {
        active && selectedHost != nil && workspaceID != nil && status != .connecting
    }

    var canRefreshAgents: Bool { agentRefreshAvailable && !refreshingAgents }

    func refreshAgents() {
        guard canRefreshAgents else { return }
        if status.isConnected { startAgentPolling() } else { reconnect() }
    }

    var startingCreations: [PendingAgentCreation] {
        newSession.pending.filter { $0.host == hostID && $0.workspace == workspaceID && $0.receipt != nil }
    }

    func presentNewSession() {
        newSession.present(host: hostID, workspace: selectedWorkspace)
        newSessionShown = true
        refreshLaunchProfiles()
    }

    func refreshLaunchProfiles() {
        if status.isConnected, let connection { newSession.loadProfiles(from: connection) }
    }

    func startNewSession() {
        guard active, status.isConnected, let hostID, let workspace = selectedWorkspace, let connection else { return }
        let host = hostEpoch, workspaceRevision = workspaceEpoch
        newSession.start(host: hostID, workspace: workspace, using: connection) { [weak self] intent in
            guard let self else { return }
            adoptCreation(intent, navigate: isCurrentHost(host) && workspaceEpoch == workspaceRevision)
        }
    }

    func checkCreation(_ intent: PendingAgentCreation) {
        guard active, status.isConnected, intent.host == hostID, let connection else { return }
        newSession.reconcile(intent, using: connection) { [weak self] in self?.adoptCreation($0, navigate: false) }
    }

    func openCreation(_ intent: PendingAgentCreation) { adoptCreation(intent, navigate: true) }

    private func adoptCreation(_ intent: PendingAgentCreation, navigate: Bool) {
        guard let key = intent.key else { return }
        let state = conversations[key] ?? ConversationState(key: key)
        if state.creation == nil {
            state.creation = FirstMessageSubmission(context: intent.context, text: newSession.prompt(for: intent.context))
        }
        conversations[key] = state
        conversationOrder.removeAll { $0 == key }
        conversationOrder.append(key)
        defer { pruneConversations() }
        guard navigate, active, intent.host == hostID, intent.workspace == workspaceID else { return }
        selectSession(key)
        newSessionShown = false
    }

    func interruptCurrentTurn() {
        guard canInterrupt, let state = conversation, let connection,
              connection.host.id == state.key.host, let identity = state.transcript.identity else { return }
        let epoch = hostEpoch
        let chat = chatEpoch
        let list = listEpoch
        state.interruptStatus = .stopping
        interrupts[state.key] = Task { [weak self] in
            guard let self else { return }
            defer {
                interrupts[state.key] = nil
                pruneConversations()
            }
            do {
                try Task.checkCancellation()
                let receipt = try await connection.interrupt(run: state.key.run)
                guard conversations[state.key] === state else { return }
                guard receipt.ws == state.key.workspace else {
                    throw ArgoClientError.deliveryUnknown(.message("The conversation changed before the stop result arrived."))
                }
                if receipt.stopped { state.interruptStatus = .stopped }
                else if receipt.reason == "not_working" { state.interruptStatus = .notWorking }
                else if receipt.reason == "idle" { state.interruptStatus = .idle }
                else { state.interruptStatus = .unconfirmed; state.interruptNeedsReview = true }
                announceInterruptResult(in: state, chat: chat)
            } catch {
                guard conversations[state.key] === state else { return }
                state.interruptNeedsReview = (error as? ArgoClientError)?.mayHaveBeenDelivered == true
                state.interruptStatus = state.interruptNeedsReview ? .unknown(L10n.error(error)) : .failed(L10n.error(error))
                announceInterruptResult(in: state, chat: chat)
                if isCurrentHost(epoch), isConnectionFailure(error) { failConnection(error) }
            }
            // Refreshes are reads. They never repeat the stop, release a queue
            // hold, or project the receipt's state onto the live Agent card.
            await refreshInterruptState(state, using: connection, epoch: epoch, chat: chat, list: list,
                                        identity: identity, reviewed: false)
        }
    }

    private func announceInterruptResult(in state: ConversationState, chat: UUID) {
        guard let status = state.interruptStatus, status != .stopping,
              conversations[state.key] === state, currentChat(state, chat) else { return }
        announce(status.message)
    }

    func refreshInterrupt() {
        guard let state = conversation, !state.isInterruptBusy, status.isConnected,
              let connection, active, conversationVisible else { return }
        let epoch = hostEpoch
        let chat = chatEpoch
        let list = listEpoch
        let identity = state.transcript.identity
        state.refreshingInterrupt = true
        interrupts[state.key] = Task { [weak self] in
            guard let self else { return }
            defer {
                interrupts[state.key] = nil
                pruneConversations()
            }
            await refreshInterruptState(state, using: connection, epoch: epoch, chat: chat, list: list,
                                        identity: identity, reviewed: true)
        }
    }

    private func refreshInterruptState(_ state: ConversationState, using connection: ArgoConnection,
                                       epoch: UUID, chat: UUID, list: UUID,
                                       identity: ArgoAgentIdentity?, reviewed: Bool) async {
        state.refreshingInterrupt = true
        defer { state.refreshingInterrupt = false }
        // A receipt belongs to its operation even after navigation. Readback
        // may take ownership only while that operation's view and list still own it.
        guard isCurrentHost(epoch), currentChat(state, chat), listEpoch == list,
              conversations[state.key] === state, state.transcript.identity == identity else { return }
        // Invalidate pre-stop polls so a late older read cannot overwrite these.
        listTask?.cancel()
        listEpoch = UUID()
        chatTask?.cancel()
        historyTask?.cancel()
        chatEpoch = UUID()
        state.loadingOlder = false
        let readbackChat = chatEpoch
        let readbackList = listEpoch
        refreshingAgents = true
        defer { if listEpoch == readbackList { refreshingAgents = false } }
        // Cards and details require both owners; normal chat reading can
        // resume independently when only a newer list has taken ownership.
        func currentReadback() -> Bool {
            isCurrentHost(epoch) && currentChat(state, readbackChat) && listEpoch == readbackList &&
                conversations[state.key] === state && state.transcript.identity == identity
        }
        func readSnapshot() async throws -> (cards: [ArgoAgentCard], terminals: [ArgoTerminalView]) {
            defer { if listEpoch == readbackList { refreshingAgents = false } }
            return try await connection.agentSnapshot(workspace: state.key.workspace)
        }
        defer {
            resumeAgentPolling(afterReadback: readbackList)
            if isCurrentHost(epoch), currentChat(state, readbackChat), conversations[state.key] === state {
                refreshConversation()
            }
        }
        do {
            async let snapshot = readSnapshot()
            async let team = connection.team(run: state.key.run)
            async let queue = connection.queue(run: state.key.run)
            let fresh = try await (snapshot, team, queue)
            try Task.checkCancellation()
            guard currentReadback() else { return }
            agents = fresh.0.cards
            state.team = fresh.1
            state.queue = fresh.2
            state.problem = nil
            if reviewed { state.interruptNeedsReview = false }
            if !newSession.pending.contains(where: { $0.key == state.key }),
               selectionEnded(state.key, terminals: fresh.0.terminals) { selectSession(nil) }
        } catch {
            guard currentReadback() else { return }
            state.problem = L10n.error(error)
            if isConnectionFailure(error) { failConnection(error) }
        }
    }

    private func resumeAgentPolling(afterReadback epoch: UUID) {
        // A readback borrows the workspace poller, not the chat's lifetime.
        // Navigation/cancellation must return it even after the chat is gone.
        // A newer list, workspace or connection already owns its own polling.
        guard listEpoch == epoch else { return }
        startAgentPolling()
    }

    private func startAgentPolling() {
        listTask?.cancel()
        listEpoch = UUID()
        guard active, status.isConnected, let connection, let workspaceID else {
            loadingAgents = false
            refreshingAgents = false
            return
        }
        let epoch = listEpoch
        let host = hostEpoch
        loadingAgents = agents.isEmpty
        refreshingAgents = true
        listTask = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == listEpoch { refreshingAgents = false } }
            do {
                while !Task.isCancelled {
                    refreshingAgents = true
                    let snapshot = try await connection.agentSnapshot(workspace: workspaceID)
                    try Task.checkCancellation()
                    guard epoch == listEpoch, isCurrentHost(host) else { return }
                    let cards = snapshot.cards
                    agents = cards
                    loadingAgents = false
                    refreshingAgents = false
                    let retired = newSession.observed(cards, terminals: snapshot.terminals, host: connection.host.id, workspace: workspaceID)
                    if let selectedKey, retired.contains(selectedKey) ||
                        (!newSession.pending.contains(where: { $0.key == selectedKey }) &&
                         selectionEnded(selectedKey, terminals: snapshot.terminals)) {
                        selectSession(nil)
                    }
                    markSelectedConversationSeen()
                    try await Task.sleep(for: .seconds(5))
                }
            } catch {
                guard !Task.isCancelled, epoch == listEpoch, isCurrentHost(host) else { return }
                loadingAgents = false
                failConnection(error)
            }
        }
    }

    /// Called by the visible question body, never by a list/team load.
    func questionDisplayed(_ ask: ArgoAsk, in key: SessionKey) {
        guard active, seenAdmissionAllowed, status.isConnected, selectedKey == key,
              let state = conversation, !ask.questionID.isEmpty, !ask.text.isEmpty else { return }
        if ArgoRun.isManaged(key.run) {
            guard ask.run == key.run, state.team?.asks.contains(ask) == true else { return }
        } else {
            guard selectedAgent?.run == "unmanaged:" + key.terminal, selectedAgent?.ask == ask else { return }
        }
        state.displayedQuestionIDs.insert(ask.questionID)
        markSelectedConversationSeen()
    }

    private func seenIDs(for card: ArgoAgentCard, in state: ConversationState) -> [String]? {
        guard card.state != "working", card.unread || !card.waitingIDs.isEmpty else { return nil }
        if card.state == "waiting" || !card.waitingIDs.isEmpty {
            let ids = card.waitingIDs.filter { !$0.isEmpty && state.displayedQuestionIDs.contains($0) }
            return ids.isEmpty ? nil : ids
        }
        // Non-waiting read state uses the existing timestamp protocol, with no
        // completion-revision precondition. Never invent a waiting fallback ID.
        return []
    }

    private func markSelectedConversationSeen() {
        guard active, seenAdmissionAllowed, status.isConnected, let connection,
              seenTask == nil, let state = conversation, let card = selectedAgent,
              let ids = seenIDs(for: card, in: state) else { return }
        let managed = ArgoRun.isManaged(card.run)
        let manual = card.run == "unmanaged:" + card.terminal
        guard managed || manual else { return }
        let signature = ([card.state, card.stateStartedAt, card.updated] + ids).joined(separator: "\u{1}")
        guard state.seenSignature != signature else { return }
        let epoch = hostEpoch
        let requestID = UUID()
        seenEpoch = requestID
        seenTask = Task { [weak self] in
            guard let self else { return }
            defer { if seenEpoch == requestID { seenTask = nil } }
            do {
                try Task.checkCancellation()
                // Recheck after scheduling, using the captured connection and full
                // destination. Core also checks cancellation after token acquisition
                // and immediately before transport.send (including a 401 retry).
                guard isCurrentHost(epoch), seenEpoch == requestID,
                      seenAdmissionAllowed, status.isConnected, selectedKey == state.key,
                      state.key.host == hostID, state.key.workspace == workspaceID,
                      connection === self.connection, let current = selectedAgent,
                      let currentIDs = seenIDs(for: current, in: state),
                      ids.isEmpty ? currentIDs.isEmpty : ids.allSatisfy(currentIDs.contains) else { return }
                if managed { try await connection.markAgentSeen(run: card.run, waitingIDs: ids) }
                else { try await connection.markTerminalSeen(terminal: card.terminal, waitingIDs: ids) }
                guard isCurrentHost(epoch), seenEpoch == requestID,
                      seenAdmissionAllowed, selectedKey == state.key, connection === self.connection else { return }
                state.seenSignature = signature
                // Replace the stale card promptly so Unread styling and filters
                // reflect the server's confirmed marker, not a local assumption.
                startAgentPolling()
            } catch {
                // Read failures leave the successful signature unchanged. A later
                // visible refresh retries the exact displayed, still-unread IDs.
            }
        }
    }

    private func startConversationPolling() {
        chatTask?.cancel()
        historyTask?.cancel()
        conversation?.loadingOlder = false
        conversation?.modelRecovery?.refreshing = false
        chatEpoch = UUID()
        guard active, status.isConnected, conversationVisible, let state = conversation, let connection else { return }
        let epoch = chatEpoch
        chatTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0
            do {
                while !Task.isCancelled {
                    if state.followingLatest && !state.loadingOlder {
                        try await readChat(state, from: connection, cursor: state.transcript.nextCursor, epoch: epoch)
                    }
                    try Task.checkCancellation()
                    guard currentChat(state, epoch) else { return }
                    // The team endpoint also reads git; refresh it every 15s, not every chat poll.
                    if ArgoRun.isManaged(state.key.run), tick % 5 == 0 {
                        async let progress = connection.team(run: state.key.run)
                        async let queue = connection.queue(run: state.key.run)
                        let details = try await (progress, queue)
                        try Task.checkCancellation()
                        guard currentChat(state, epoch) else { return }
                        state.team = details.0
                        state.queue = details.1
                    }
                    tick += 1
                    try await Task.sleep(for: .seconds(3))
                }
            } catch {
                guard !Task.isCancelled, currentChat(state, epoch) else { return }
                state.loading = false
                state.problem = L10n.error(error)
                if isConnectionFailure(error) { failConnection(error) }
            }
        }
    }

    private func readChat(_ state: ConversationState, from connection: ArgoConnection,
                          cursor: ArgoChatCursor, epoch: UUID) async throws {
        do {
            let page = try await connection.chat(terminal: state.key.terminal, cursor: cursor,
                                                 session: state.transcript.identity?.session)
            try Task.checkCancellation()
            guard currentChat(state, epoch) else { return }
            if let identity = page.identity,
               identity.run != (ArgoRun.isManaged(state.key.run) ? state.key.run : nil) {
                // Chat reads the terminal's current owner. Its native page must
                // still belong to the selected key, even between list polls.
                cancelSends()
                state.sessionChanged()
                throw ArgoClientError.invalidResponse(.message("The terminal opened a different conversation. Your draft is kept; review the new conversation before sending."))
            }
            if page.waiting != nil, state.transcript.identity != nil {
                // Waiting drops the native identity too; clear display evidence
                // before applying that page, without discarding drafts/receipts.
                cancelSends()
                state.sessionChanged()
            }
            if cursor == .latest, let previous = state.transcript.identity,
               page.waiting == nil, previous != page.identity {
                cancelSends()
                state.sessionChanged()
            }
            // A waiting page has no history cursor and replaces the whole window.
            let change = state.transcript.apply(page, cursor: page.waiting == nil ? cursor : .latest)
            if change == .stalePage {
                throw ArgoClientError.invalidResponse(.message("The history window changed. Refresh the conversation to continue."))
            }
            if case .waiting = change {
                cancelSends()
                state.invalidateModelRecoveryNativeReview()
                state.team = nil
                state.queue = nil
                state.followingLatest = true
            }
            if change == .sessionChanged {
                cancelSends()
                state.sessionChanged()
                try await readChat(state, from: connection, cursor: .latest, epoch: epoch)
            }
            state.loading = false
            state.problem = nil
        } catch let error as ArgoClientError {
            if case .http(status: 404, _, _) = error, currentChat(state, epoch) {
                // Unlike an absent list card, this proves the known terminal is gone.
                _ = newSession.terminalGone(state.key)
                selectSession(nil)
            }
            if case .http(status: 409, _, _) = error, cursor != .latest {
                guard currentChat(state, epoch) else { return }
                cancelSends()
                state.sessionChanged()
                try await readChat(state, from: connection, cursor: .latest, epoch: epoch)
            } else { throw error }
        }
    }

    func loadOlder() {
        guard let state = conversation, let cursor = state.transcript.olderCursor else { return }
        readWindow(cursor, followingLatest: false)
    }

    func loadNewer() {
        guard let state = conversation, state.transcript.newer else { return }
        readWindow(state.transcript.nextCursor, followingLatest: false)
    }

    func showLatest() { readWindow(.latest, followingLatest: true) }

    private func readWindow(_ cursor: ArgoChatCursor, followingLatest: Bool) {
        guard let state = conversation, !state.loadingOlder || cursor == .latest,
              let connection, status.isConnected else { return }
        // Latest can supersede a history read; only the current epoch may merge.
        chatTask?.cancel()
        historyTask?.cancel()
        conversation?.modelRecovery?.refreshing = false
        chatEpoch = UUID()
        let epoch = chatEpoch
        state.followingLatest = followingLatest
        state.loadingOlder = true
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == chatEpoch {
                    state.loadingOlder = false
                    if currentChat(state, epoch) { startConversationPolling() }
                }
            }
            do {
                try await readChat(state, from: connection, cursor: cursor, epoch: epoch)
                guard currentChat(state, epoch) else { return }
                if case .after = cursor, !state.transcript.newer { state.followingLatest = true }
            }
            catch {
                guard !Task.isCancelled, currentChat(state, epoch) else { return }
                state.problem = L10n.error(error)
                if isConnectionFailure(error) { failConnection(error) }
            }
        }
    }

    func sendDraft(for key: SessionKey? = nil) {
        if let key, key != selectedKey { return }
        guard let state = conversation, state.canSendToIdentity, !state.isSending, !state.isInterruptBusy,
              status.isConnected, let connection else { return }
        if !state.attachments.isEmpty { sendAttachments(in: state, using: connection); return }
        guard !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = ArgoOutgoingMessage(run: state.key.run, text: state.draft, target: state.transcript.identity)
        state.draft = ""
        state.followingLatest = true
        deliver(.message(message), in: state, using: connection)
    }

    func addAttachments(_ inputs: [AttachmentInput], to state: ConversationState, identity: ArgoAgentIdentity) {
        guard conversations[state.key] === state else { return }
        state.prepareAttachments(inputs, identity: identity, start: active && selectedKey == state.key && state.transcript.identity == identity)
    }

    private func sendAttachments(in state: ConversationState, using client: ArgoConnection) {
        guard let identity = state.transcript.identity,
              state.attachments.allSatisfy({ $0.identity == identity }) else {
            state.attachmentProblem = L10n.text("These attachments belong to the earlier conversation. Remove them and select them again to send here.")
            return
        }
        let caption = state.draft
        let order = state.attachments.map(\.id)
        let preparations = order.compactMap { state.attachmentPreparations[$0] }
        let host = hostEpoch
        let batch = UUID()
        state.attachmentSendID = batch
        state.attachmentProblem = nil
        state.attachmentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if state.attachmentSendID == batch { state.attachmentSendID = nil; state.attachmentTask = nil }
                pruneConversations()
            }
            do {
                for preparation in preparations {
                    await preparation.value
                    try checkAttachmentDestination(state, identity: identity, batch: batch, host: host)
                }
                for id in order {
                    try checkAttachmentDestination(state, identity: identity, batch: batch, host: host)
                    guard let item = state.attachments.first(where: { $0.id == id }), let file = item.local else {
                        throw ArgoClientError.refusedLocally(.message("An attachment is not ready. Remove failed items or select them again."))
                    }
                    if item.remote != nil { continue }
                    state.updateAttachment(id) { $0.phase = .uploading }
                    let uploaded = try await client.uploadAttachment(file)
                    try checkAttachmentDestination(state, identity: identity, batch: batch, host: host)
                    state.updateAttachment(id) { $0.remote = uploaded; $0.phase = .readyRemote }
                }
                try checkAttachmentDestination(state, identity: identity, batch: batch, host: host)
                var copies: [SentAttachment] = []
                for id in order {
                    guard let item = state.attachments.first(where: { $0.id == id }),
                          item.phase == .readyRemote, let local = item.local, let remote = item.remote else {
                        throw ArgoClientError.refusedLocally(.message("An attachment is not ready. Remove failed items or select them again."))
                    }
                    copies.append(SentAttachment(local: local, remote: remote))
                }
                let text = try ArgoAttachmentMessage.text(caption: caption, files: copies.map { ($0.remote, $0.local.kind) })
                // No queue attempt exists before all four-or-fewer exact upload
                // receipts are ready. Retry thereafter uses only this operation.
                let message = ArgoOutgoingMessage(run: state.key.run, text: text, target: identity)
                if state.draft == caption { state.draft = "" }
                state.attachments.removeAll { order.contains($0.id) }
                state.attachmentSendID = nil
                state.attachmentTask = nil
                state.followingLatest = true
                deliver(.message(message), in: state, using: client, attachments: copies)
            } catch {
                guard state.attachmentSendID == batch else { return }
                state.attachmentProblem = L10n.fileError(error)
                for id in order {
                    state.updateAttachment(id) {
                        if $0.phase == .uploading { $0.phase = .failed(L10n.fileError(error)) }
                    }
                }
            }
        }
    }

    private func checkAttachmentDestination(_ state: ConversationState, identity: ArgoAgentIdentity,
                                            batch: UUID, host: UUID) throws {
        try Task.checkCancellation()
        guard isCurrentHost(host), status.isConnected, selectedKey == state.key,
              conversations[state.key] === state, state.attachmentSendID == batch,
              state.transcript.identity == identity else {
            throw ArgoClientError.refusedLocally(.message("The conversation changed. The message was not sent."))
        }
    }

    enum MessageLinkAction {
        case remote(ArgoFileReference)
        case external
        case discarded
    }

    /// The view supplies its message snapshot, never a session-wide path allowlist.
    /// Resolve against the current native message; a removed/replaced row is stale.
    func messageLink(_ url: URL, item: ArgoChatItem?, key: SessionKey,
                     identity: ArgoAgentIdentity?) throws -> MessageLinkAction {
        if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return .external }
        var references: [ArgoFileReference] = []
        if let item {
            guard active, status.isConnected, key == selectedKey, key.host == hostID,
                  let identity, let state = conversations[key], state.transcript.identity == identity,
                  let current = state.transcript.items.first(where: { $0.id == item.id && $0 == item }) else {
                throw ArgoClientError.refusedLocally(.message("The conversation changed. Open the file from its original conversation."))
            }
            references = current.fileRefs
        }
        if let ref = try ArgoFileReference.link(url, references: references) { return .remote(ref) }
        return .discarded
    }

    private func isCurrentFileReference(_ reference: ArgoFileReference, message: ArgoChatItem?,
                                        state: ConversationState) -> Bool {
        guard let message else { return true } // Validated upload receipts have their own source.
        guard let current = state.transcript.items.first(where: { $0.id == message.id && $0 == message }) else { return false }
        return current.fileRefs.contains { $0.path.utf8.elementsEqual(reference.path.utf8) }
    }

    func downloadAttachment(_ reference: ArgoFileReference, key: SessionKey,
                            identity: ArgoAgentIdentity, message: ArgoChatItem? = nil) async throws -> ArgoLocalAttachment {
        guard active, status.isConnected, key == selectedKey, key.host == hostID,
              let state = conversations[key], state.transcript.identity == identity, let client = connection,
              isCurrentFileReference(reference, message: message, state: state) else {
            throw ArgoClientError.refusedLocally(.message("The conversation changed. Open the file from its original conversation."))
        }
        let epoch = hostEpoch
        let bytes = try await client.downloadAttachment(reference, workspace: key.workspace, terminal: key.terminal)
        try Task.checkCancellation()
        guard isCurrentHost(epoch), selectedKey == key, state.transcript.identity == identity,
              isCurrentFileReference(reference, message: message, state: state) else {
            throw ArgoClientError.refusedLocally(.message("The conversation changed. Open the file from its original conversation."))
        }
        let work = Task.detached(priority: .userInitiated) {
            try ArgoLocalAttachment.create(name: reference.name, mime: "application/octet-stream", kind: .file) {
                try bytes.write(to: $0)
            }
        }
        let file = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard isCurrentHost(epoch), selectedKey == key, state.transcript.identity == identity,
              isCurrentFileReference(reference, message: message, state: state) else {
            throw ArgoClientError.refusedLocally(.message("The conversation changed. Open the file from its original conversation."))
        }
        return file
    }

    func reply(to ask: ArgoAsk) {
        guard let state = conversation, !state.isSending, !state.isInterruptBusy, state.canReply(to: ask),
              ask.run == state.key.run, status.isConnected, let connection else { return }
        let text = state.replyDrafts[ask.uiID] ?? ""
        guard ask.acceptsReply(text, engine: selectedAgent?.engine ?? "") else { return }
        state.replyDrafts[ask.uiID] = ""
        state.followingLatest = true
        deliver(.reply(ask, terminal: state.key.terminal, text: text, attempt: ArgoAttempt.make()),
                in: state, using: connection)
    }

    func retry(_ requested: PendingDelivery) {
        guard let state = conversation, !state.isSending, !state.isInterruptBusy,
              let delivery = state.deliveries.first(where: { $0.id == requested.id }), delivery.status.canRetry,
              status.isConnected, let connection else { return }
        // Only a request explicitly known not to have left the phone can be retried.
        if case .message(let message) = delivery.operation {
            guard message.target == state.transcript.identity, state.canSendToIdentity else {
                state.setStatus(.rejected(L10n.text("The conversation changed. Copy this message into the draft to review it.")), for: delivery.id)
                return
            }
        }
        if case .reply(let ask, let terminal, _, _) = delivery.operation {
            guard !state.hasAnswered(ask), ask.run == state.key.run, terminal == state.key.terminal,
                  state.team?.asks.contains(where: { $0.uiID == ask.uiID }) == true else {
                state.setStatus(.rejected(L10n.text("The question changed. Review the current question before answering.")), for: delivery.id)
                return
            }
        }
        state.setStatus(.sending, for: delivery.id)
        perform(delivery.operation, in: state, using: connection)
    }

    /// One explicit model-error recovery action for the selected managed Claude.
    /// The synchronous operation install is the double-tap guard; the draft is
    /// deliberately retained after every outcome.
    func switchModelAndResume() {
        guard let state = conversation, selectedAgent?.offersModelRecovery == true,
              state.canStartModelRecovery, status.isConnected, let connection else { return }
        guard let id = ArgoModelID.normalized(state.modelRecoveryDraft) else {
            state.modelRecoveryProblem = L10n.text("Enter a model ID using only letters, digits and . : / @ [ ] - _, up to 80 characters.")
            return
        }
        let operationID = UUID()
        state.beginModelRecovery(operationID, model: id)
        let epoch = hostEpoch
        let chat = chatEpoch
        let list = listEpoch
        let identity = state.transcript.identity
        sends[operationID.uuidString] = Task { [weak self] in
            guard let self else { return }
            defer {
                sends[operationID.uuidString] = nil
                pruneConversations()
            }
            do {
                let receipt = try await connection.switchModelAndResume(run: state.key.run, model: id)
                let result = modelRecoveryStatus(receipt)
                state.finishModelRecovery(operationID, status: result)
                // A valid receipt still needs real card/chat readback. Unknown
                // transport results do not read or replay until the user asks.
                // Automatic readback must not take over a newer chat/list owner.
                if isCurrentHost(epoch), selectedKey == state.key, conversationVisible {
                    startModelRecoveryRefresh(claim: ModelRecoveryReadClaim(chat: chat, list: list, native: identity))
                }
            } catch {
                state.finishModelRecovery(operationID, status: modelRecoveryFailure(error))
                if isCurrentHost(epoch), !Task.isCancelled, isConnectionFailure(error) { failConnection(error) }
            }
        }
    }

    private func modelRecoveryStatus(_ receipt: ArgoModelSwitchReceipt) -> ModelRecoveryOperation.Status {
        if !receipt.switched { return .notSwitched(receipt.message) }
        let native = receipt.message
        guard let resume = receipt.resume else {
            return .switchedNotResumed(joinRecoveryDetail([native, L10n.text("The host returned no resume receipt.")]))
        }
        let reason = resume.message.isEmpty ? resume.reason : resume.message
        let detail = joinRecoveryDetail([native, reason])
        return resume.sent ? .switchedAndResumed(detail) : .switchedNotResumed(detail)
    }

    private func joinRecoveryDetail(_ parts: [String]) -> String {
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
    }

    private func modelRecoveryFailure(_ error: Error) -> ModelRecoveryOperation.Status {
        let text = L10n.error(error)
        if (error as? ArgoClientError)?.mayHaveBeenDelivered == true { return .unknown(text) }
        // A 404 can also come from claimResume after Claude accepted /model.
        // Unlike an ordinary queue write, this endpoint cannot call every 404
        // a definite non-delivery. Refresh before any new user action.
        if case ArgoClientError.http(status: 404, _, _) = error { return .unknown(text) }
        switch error {
        case ArgoClientError.notSent, is CancellationError: return .notSent(text)
        default: return .rejected(text)
        }
    }

    /// Reads the actual card and latest native conversation after a receipt,
    /// or on the user's explicit refresh after an unknown result. No POST is
    /// made here. Only native evidence bound to this destination and chat epoch
    /// can unlock another action; waiting and changed native require more review.
    func refreshModelRecovery() { startModelRecoveryRefresh() }

    private func startModelRecoveryRefresh(claim: ModelRecoveryReadClaim? = nil) {
        guard let state = conversation, let operation = state.modelRecovery,
              operation.status != .sending, status.isConnected, let connection else { return }
        // Automatic receipt readback may claim only the ownership captured at
        // the user's POST. An explicit refresh starts a new claim instead.
        if let claim {
            guard currentChat(state, claim.chat), listEpoch == claim.list,
                  conversations[state.key] === state, state.transcript.identity == claim.native else { return }
        }
        guard state.beginModelRecoveryRefresh(operation.id) else { return }
        chatTask?.cancel()
        historyTask?.cancel()
        listTask?.cancel()
        chatEpoch = UUID()
        listEpoch = UUID()
        let epoch = chatEpoch
        let readbackList = listEpoch
        refreshingAgents = true
        state.followingLatest = true
        historyTask = Task { [weak self] in
            guard let self else { return }
            var nativeRead = false
            var readNative: ArgoAgentIdentity?
            var problem: String?
            // The list generation guards cards and proof just as the ordinary
            // poller does. Native pages still follow R2's full-identity rules.
            @MainActor func currentReadback() -> Bool {
                currentChat(state, epoch) && listEpoch == readbackList && conversations[state.key] === state
            }
            defer {
                if listEpoch == readbackList { refreshingAgents = false }
                if epoch == chatEpoch {
                    if currentReadback() {
                        if nativeRead {
                            state.finishModelRecoveryRefresh(operation.id, native: readNative, epoch: epoch, problem: problem)
                        } else {
                            state.failModelRecoveryRefresh(operation.id, problem: problem)
                        }
                        startConversationPolling()
                    } else {
                        // A newer list owns the current view. Do not cancel it
                        // or publish this claim's cards/proof over its state.
                        state.failModelRecoveryRefresh(operation.id, problem: nil)
                        if currentChat(state, epoch), conversations[state.key] === state {
                            startConversationPolling()
                        }
                    }
                }
                resumeAgentPolling(afterReadback: readbackList)
                pruneConversations()
            }
            @MainActor func readCards() async throws -> [ArgoAgentCard] {
                defer { if listEpoch == readbackList { refreshingAgents = false } }
                return try await connection.agents(workspace: state.key.workspace)
            }
            do {
                async let cards = readCards()
                async let team = connection.team(run: state.key.run)
                async let queue = connection.queue(run: state.key.run)
                let current = try await (cards, team, queue)
                try Task.checkCancellation()
                guard currentReadback() else { return }
                agents = current.0
                state.team = current.1
                state.queue = current.2
                try await readChat(state, from: connection, cursor: .latest, epoch: epoch)
                try Task.checkCancellation()
                guard currentReadback() else { return }
                readNative = state.transcript.identity
                problem = state.transcript.waiting
                nativeRead = true
            } catch {
                guard !Task.isCancelled, currentReadback() else { return }
                problem = L10n.error(error)
                if isConnectionFailure(error) { failConnection(error) }
            }
        }
    }

    private func deliver(_ operation: PendingDelivery.Operation, in state: ConversationState, using connection: ArgoConnection,
                         attachments: [SentAttachment] = []) {
        state.append(PendingDelivery(id: operation.attempt, operation: operation, attachments: attachments))
        perform(operation, in: state, using: connection)
    }

    private func perform(_ operation: PendingDelivery.Operation, in state: ConversationState, using connection: ArgoConnection) {
        let epoch = hostEpoch
        sends[operation.attempt] = Task { [weak self] in
            guard let self else { return }
            defer {
                sends[operation.attempt] = nil
                pruneConversations()
            }
            do {
                try Task.checkCancellation()
                switch operation {
                case .message(let message):
                    let receipt = try await connection.send(message)
                    state.record(receipt, for: operation.attempt)
                case .reply(let ask, let terminal, let text, let attempt):
                    let receipt = try await connection.reply(ask, terminal: terminal, text: text, attempt: attempt)
                    guard receipt.status == "sent", receipt.id == ask.questionID else {
                        throw ArgoClientError.deliveryUnknown(.message("The host returned an unrecognized answer receipt."))
                    }
                    state.recordReply(to: ask, for: operation.attempt)
                }
                // Automatic refresh follows the user's current visible window.
                if isCurrentHost(epoch), conversationVisible,
                   selectedKey == state.key, state.followingLatest {
                    showLatest()
                }
            } catch {
                // A late receipt changes only its original conversation, even after a host switch.
                let result: PendingDelivery.Status
                if (error as? ArgoClientError)?.mayHaveBeenDelivered == true {
                    result = .unknown(L10n.error(error))
                } else {
                    switch error {
                    case ArgoClientError.notSent, is CancellationError: result = .notSent(L10n.error(error))
                    default: result = .rejected(L10n.error(error))
                    }
                }
                recordFailure(result, for: operation.attempt, in: state)
                if isCurrentHost(epoch), !Task.isCancelled, isConnectionFailure(error) { failConnection(error) }
            }
        }
    }

    private func recordFailure(_ result: PendingDelivery.Status, for id: String, in state: ConversationState) {
        guard let previous = state.deliveries.first(where: { $0.id == id })?.status else { return }
        state.setStatus(result, for: id)
        guard active, conversationVisible, selectedKey == state.key else { return }
        switch result {
        case .unknown:
            if case .unknown = previous { return }
            announce(L10n.text("Delivery unknown. Open Delivery Receipts to Refresh Conversation or Copy. Refresh before sending again."))
        case .notSent:
            if case .notSent = previous { return }
            announce(L10n.text("Message not sent. Open Delivery Receipts to Retry Sending or Copy."))
        default: break
        }
    }

    func pair(code: String, name: String, deviceName: String) {
        guard pairTask == nil, active else { return }
        pairing = true
        pairingProblem = nil
        pairedHostID = nil
        pairTask = Task { [weak self] in
            guard let self else { return }
            defer { pairing = false; pairTask = nil }
            var replacingHost: UUID?
            do {
                try Task.checkCancellation()
                if let parsed = try? PairingCode(parsing: code),
                   let old = hosts.first(where: { PairingCode.sameHost($0.address, parsed.host) && $0.gatewayPort == parsed.port }) {
                    replacingHost = old.id
                    try await prepareNotificationsForPairing?(old.id)
                    try Task.checkCancellation()
                }
                let paired = try await store.pair(code: code, deviceName: deviceName, name: name)
                try Task.checkCancellation()
                let updatedHosts = try await store.hosts()
                try Task.checkCancellation()
                hosts = updatedHosts
                pairedHostID = paired.id
                if hostID == paired.id { reconnect() } else { selectHost(paired.id) }
            } catch is CancellationError {
                // Persistence may already have completed; cancellation only stops UI completion.
            } catch {
                if !Task.isCancelled, active { pairingProblem = L10n.error(error) }
            }
            // Re-read persisted pairing even after cancellation: it may contain
            // either the original credential or a successfully saved replacement.
            if let replacingHost { await restoreNotificationsAfterPairing?(replacingHost) }
        }
    }

    func cancelPairing() { pairTask?.cancel() }

    private func isCurrentHost(_ epoch: UUID) -> Bool { active && epoch == hostEpoch && !Task.isCancelled }
    private func currentChat(_ state: ConversationState, _ epoch: UUID) -> Bool {
        active && conversationVisible && selectedKey == state.key && epoch == chatEpoch && !Task.isCancelled
    }

    private func isConnectionFailure(_ error: Error) -> Bool {
        switch error {
        case ArgoClientError.gateway, ArgoClientError.closed, ArgoClientError.needsPairing,
             ArgoClientError.unsupportedServer: true
        default: false
        }
    }

    private func failConnection(_ error: Error) {
        let shouldAnnounce = active && status.problem == nil
        let needsPairing: Bool
        if case ArgoClientError.needsPairing = error { needsPairing = true } else { needsPairing = false }
        invalidateConnection()
        status = .failed(L10n.error(error), needsPairing: needsPairing)
        if shouldAnnounce {
            announce(L10n.text(needsPairing ? "Disconnected. Choose Pair Again to reconnect." : "Disconnected. Choose Retry to reconnect."))
        }
    }

    /// Bound host-backed windows across the whole app. User work, answer claims,
    /// unresolved deliveries and in-flight operations keep their original state.
    private func pruneConversations() {
        conversationOrder.removeAll { conversations[$0] == nil }
        var retained = selectedKey == nil ? 0 : 1
        var remove: [SessionKey] = []
        for key in conversationOrder.reversed() where key != selectedKey {
            guard let state = conversations[key], !state.isSending, !state.isInterruptBusy,
                  state.modelRecovery?.refreshing != true else { continue }
            if retained < Self.retainedTranscriptLimit {
                retained += 1
                continue
            }
            if state.hasNonReloadableState {
                if state.transcript.identity != nil || state.transcript.waiting != nil ||
                    state.team != nil || state.queue != nil || state.problem != nil ||
                    state.deliveries.contains(where: { $0.status.isKnownSuccess }) {
                    state.releaseReloadableContent(inFlightDeliveryIDs: Set(sends.keys))
                }
            } else {
                remove.append(key)
            }
        }
        for key in remove { conversations.removeValue(forKey: key) }
        conversationOrder.removeAll { conversations[$0] == nil }
    }

    private func cancelSends() {
        conversation?.cancelAttachmentWork()
        for task in sends.values { task.cancel() }
        cancelSeen()
    }

    private func cancelSeen() {
        seenEpoch = UUID()
        seenTask?.cancel()
        seenTask = nil
    }

    private func cancelConversationRequests() {
        conversation?.closeQueueItem()
        conversation?.closeNativeHistory()
        chatEpoch = UUID()
        chatTask?.cancel()
        historyTask?.cancel()
        conversation?.loadingOlder = false
        conversation?.modelRecovery?.refreshing = false
        cancelSends()
        for task in interrupts.values { task.cancel() }
    }

    private func invalidateConnection() {
        notificationTask?.cancel()
        hostEpoch = UUID()
        listEpoch = UUID()
        connectTask?.cancel()
        listTask?.cancel()
        cancelConversationRequests()
        conversation?.seenSignature = nil
        loadingAgents = false
        refreshingAgents = false
        let old = connection
        connection = nil
        if let old { Task { await old.close() } }
    }
}

/// A token belongs to one actual presentation, optionally to one Chat branch.
/// Releasing an old token never releases a replacement presentation.
struct SeenPresentationOwner: Hashable {
    private let id = UUID()
    let conversation: SessionKey?

    init(conversation: SessionKey? = nil) { self.conversation = conversation }
}

@MainActor @Observable
final class SeenPresentation {
    private(set) var isPresented = false
    private(set) var owner: SeenPresentationOwner?
    private var dismissalRequested = false

    func cover(in model: AppModel, conversation: SessionKey? = nil) {
        guard owner == nil else { return }
        let owner = SeenPresentationOwner(conversation: conversation)
        self.owner = owner
        model.pauseSeen(for: owner)
    }

    func setPresented(_ shown: Bool, in model: AppModel, conversation: SessionKey? = nil) {
        if shown {
            // Wait for the previous presentation's real dismissal callback.
            guard !dismissalRequested else { return }
            cover(in: model, conversation: conversation)
        } else {
            requestDismissal()
            return
        }
        isPresented = shown
    }

    func requestDismissal() {
        dismissalRequested = owner != nil
        isPresented = false
    }

    func didDismiss(in model: AppModel) { didDismiss(owner, in: model) }

    func didDismiss(_ completedOwner: SeenPresentationOwner?, in model: AppModel) {
        guard let completedOwner else { return }
        model.resumeSeen(for: completedOwner)
        guard completedOwner == owner else { return }
        owner = nil
        dismissalRequested = false
        isPresented = false
    }
}

#if canImport(SwiftUI)
extension SeenPresentation {
    func binding(in model: AppModel, conversation: SessionKey? = nil) -> Binding<Bool> {
        Binding(get: { self.isPresented }, set: { self.setPresented($0, in: model, conversation: conversation) })
    }
}
#endif
