import ArgoMobileKit
import Foundation
import Observation

struct NewSessionDraft {
    var cwd = ""
    var profile = ""
    var permission: ArgoLaunchPermission = .full
    var prompt = ""
}

struct CreatedAgentReceipt: Codable {
    let terminal: String
    let run: String
    let alive: Bool
    let exitCode: Int?
}

/// Only recovery metadata reaches disk. Prompts and credentials never do.
struct PendingAgentCreation: Codable, Identifiable {
    let host: UUID
    let workspace: String
    let cwd: String
    let profile: String
    let engine: String
    let permission: ArgoLaunchPermission
    let context: String
    let started: Date
    var receipt: CreatedAgentReceipt?
    var id: String { context }

    func matches(_ terminal: ArgoTerminalView) -> Bool {
        terminal.matches(workspace: workspace, cwd: cwd, profile: profile, context: context) && terminal.agent?.engine == engine
    }
    var key: SessionKey? {
        guard let receipt else { return nil }
        return SessionKey(host: host, workspace: workspace, run: receipt.run, terminal: receipt.terminal)
    }
}

@MainActor protocol PendingCreationStoring {
    func load() throws -> [PendingAgentCreation]
    func save(_ pending: [PendingAgentCreation]) throws
}

struct PendingCreationFile: PendingCreationStoring {
    let url: URL?
    init(url: URL? = nil) { self.url = url }
    private func location() throws -> URL {
        if let url { return url }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false).appendingPathComponent("Argo/pending-agents.json")
    }
    func load() throws -> [PendingAgentCreation] {
        let data: Data
        do { data = try Data(contentsOf: location()) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try JSONDecoder().decode([PendingAgentCreation].self, from: data)
    }
    func save(_ pending: [PendingAgentCreation]) throws {
        let url = try location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
    }
}

/// Owns a launch beyond the lifetime of its sheet, connection or selected host.
/// A persisted unresolved intent always resumes as unknown, never as a POST.
@MainActor @Observable
final class NewSessionModel {
    var draft = NewSessionDraft()
    private(set) var pending: [PendingAgentCreation] = []
    private(set) var currentContext: String?
    private(set) var busyContext: String?
    private(set) var checking: Set<String> = []
    private(set) var candidates: [String: [ArgoTerminalView]] = [:]
    private(set) var profiles: [ArgoAgentProfile] = []
    private(set) var profilesLoading = false
    private(set) var profilesProblem: String?
    private(set) var problem: String?
    private(set) var storageProblem: String?
    @ObservationIgnored private let store: any PendingCreationStoring
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var profileHost: UUID?
    @ObservationIgnored private var profileEpoch = UUID()
    @ObservationIgnored private var prompts: [String: (host: UUID, text: String)] = [:]
    @ObservationIgnored private var presentedHost: UUID?
    @ObservationIgnored private var presentedWorkspace: String?

    init(store: any PendingCreationStoring = PendingCreationFile()) {
        self.store = store
        retryStorage()
    }

    var current: PendingAgentCreation? { pending.first { $0.context == currentContext } }
    var creating: Bool { busyContext != nil }
    var canEdit: Bool { current == nil && !creating && storageProblem == nil }
    private var hasDraftInput: Bool {
        !draft.cwd.isEmpty || !draft.profile.isEmpty || draft.permission != .full || !draft.prompt.isEmpty
    }
    var selectedProfile: ArgoAgentProfile? { profiles.first { $0.name == draft.profile } }
    var originalPrompt: String? { currentContext.flatMap { prompts[$0]?.text } }

    func present(host: UUID?, workspace: ArgoWorkspace?) {
        let previous = current
        // An edited new draft (including Start Another) must not be replaced
        // merely because this destination also has an intent to recover.
        let preserveNewDraft = previous == nil && hasDraftInput
        presentedHost = host
        presentedWorkspace = workspace?.id
        let recovered = pending.last { $0.host == host && $0.workspace == workspace?.id }
        if recovered != nil && preserveNewDraft {
            currentContext = nil
        } else {
            currentContext = recovered?.context
            if let current { restoreDraft(current) }
            // A reviewed first message belongs to its old destination; it must
            // not become an editable new draft somewhere else.
            else if previous != nil { draft.prompt = "" }
        }
        problem = nil
        if workspace?.roots.contains(where: { !$0.missing && $0.path == draft.cwd }) != true {
            if current == nil { draft.cwd = "" }
        }
    }

    func selectHost(_ host: UUID?) {
        // Recovery text remains available through prompts[intent.context].
        // Do not carry it into the next host as a fresh launch draft.
        if current != nil { draft = NewSessionDraft() }
        presentedHost = host
        presentedWorkspace = nil
        currentContext = nil
        problem = nil
        profileEpoch = UUID()
        profileHost = host
        profiles = []
        profilesLoading = false
        profilesProblem = nil
        draft.profile = ""
        draft.cwd = ""
    }

    func loadProfiles(from connection: ArgoConnection) {
        let host = connection.host.id
        guard profileHost == host, !profilesLoading else { return }
        profilesLoading = true
        profilesProblem = nil
        let epoch = profileEpoch
        Task {
            do {
                let result = try await connection.profiles()
                guard profileEpoch == epoch else { return }
                profiles = result.filter { !$0.hidden }
                profilesLoading = false
            } catch {
                guard profileEpoch == epoch else { return }
                profilesLoading = false
                profilesProblem = L10n.error(error)
            }
        }
    }

    func retryStorage() {
        do {
            if !loaded {
                pending = try store.load()
                loaded = true
                currentContext = pending.last { $0.host == presentedHost && $0.workspace == presentedWorkspace }?.context
                if let current { restoreDraft(current) }
            } else { try store.save(pending) }
            storageProblem = nil
        } catch { storageProblem = L10n.error(error) }
    }

    /// Called synchronously by the button, before a Task can re-enter the model.
    func start(host: UUID, workspace: ArgoWorkspace, using connection: ArgoConnection,
               onCreated: @escaping @MainActor (PendingAgentCreation) -> Void) {
        guard canEdit, connection.host.id == host else { return }
        guard let profile = selectedProfile, profile.canLaunch,
              workspace.roots.contains(where: { !$0.missing && $0.path == draft.cwd }),
              !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.prompt.utf8.count <= 256 * 1024 else {
            problem = L10n.text("Choose an available launcher, an existing folder and a first message.")
            return
        }
        guard profile.fixedPermission.isEmpty || draft.permission == .full else {
            problem = profile.fixedPermission
            return
        }
        let intent = PendingAgentCreation(host: host, workspace: workspace.id, cwd: draft.cwd,
                                          profile: profile.name, engine: profile.engine, permission: draft.permission,
                                          context: "ios:new:" + UUID().uuidString, started: Date())
        // Save before scheduling any network work. A failed first save sends nothing.
        do { try store.save(pending + [intent]) }
        catch { storageProblem = L10n.error(error); return }
        pending.append(intent)
        currentContext = intent.context
        busyContext = intent.context
        problem = nil
        prompts[intent.context] = (host, draft.prompt)
        let request = ArgoCreateAgentRequest(workspace: intent.workspace, cwd: intent.cwd, profile: intent.profile,
                                            context: intent.context, autonomy: intent.permission, prompt: draft.prompt)
        Task {
            defer { busyContext = nil }
            do {
                let terminal = try await connection.createAgent(request)
                guard intent.matches(terminal) else {
                    throw ArgoClientError.deliveryUnknown(.message("The creation receipt does not match the original intent."))
                }
                accept(terminal, for: intent, onCreated: onCreated)
            } catch {
                let wasCurrent = currentContext == intent.context
                if Self.allowsManualRetry(error) {
                    let remaining = pending.filter { $0.context != intent.context }
                    pending = remaining
                    if wasCurrent { currentContext = nil }
                    do {
                        try store.save(remaining)
                    } catch { storageProblem = L10n.error(error) }
                }
                if wasCurrent { problem = L10n.error(error) }
            }
        }
    }

    /// Only explicit proof of no creation allows editing/retrying. Closed,
    /// cancellation, 5xx and malformed receipts remain unknown.
    static func allowsManualRetry(_ error: Error) -> Bool {
        switch error {
        // needsPairing comes from token retrieval or the pre-HTTP stream open.
        case ArgoClientError.notSent, ArgoClientError.refusedLocally, ArgoClientError.needsPairing: return true
        case ArgoClientError.http(let status, _, _): return [400, 401, 403, 404, 409, 413].contains(status)
        default: return false
        }
    }

    func reconcile(_ intent: PendingAgentCreation, using connection: ArgoConnection,
                   onCreated: @escaping @MainActor (PendingAgentCreation) -> Void) {
        guard intent.host == connection.host.id, intent.receipt == nil,
              busyContext != intent.context, !checking.contains(intent.context) else { return }
        checking.insert(intent.context)
        Task {
            defer { checking.remove(intent.context) }
            do {
                let terminals = try await connection.terminals(workspace: intent.workspace)
                let matches = terminals.filter { intent.matches($0) }
                candidates[intent.context] = matches
                if matches.count == 1 { accept(matches[0], for: intent, onCreated: onCreated) }
                if currentContext == intent.context {
                    problem = matches.isEmpty ? L10n.text("No exact match yet. The previous creation result is still unknown.") : nil
                }
            } catch {
                if currentContext == intent.context { problem = L10n.error(error) }
            }
        }
    }

    func choose(_ terminal: ArgoTerminalView, for intent: PendingAgentCreation,
                onCreated: @escaping @MainActor (PendingAgentCreation) -> Void) {
        guard candidates[intent.context]?.contains(terminal) == true, intent.matches(terminal) else { return }
        accept(terminal, for: intent, onCreated: onCreated)
    }

    private func accept(_ terminal: ArgoTerminalView, for intent: PendingAgentCreation,
                        onCreated: @MainActor (PendingAgentCreation) -> Void) {
        guard let index = pending.firstIndex(where: { $0.context == intent.context }),
              pending[index].receipt == nil, let agent = terminal.agent, let alive = terminal.alive else { return }
        // Titles can later be derived from prompts. Persist only the real ids
        // and lifecycle bits, never titles, native history or native session ids.
        pending[index].receipt = CreatedAgentReceipt(terminal: terminal.id, run: agent.run,
                                                     alive: alive, exitCode: terminal.exitCode)
        candidates[intent.context] = nil
        do { try store.save(pending) }
        catch { storageProblem = L10n.error(error) }
        onCreated(pending[index])
    }

    func prompt(for context: String) -> String? { prompts[context]?.text }

    func review(_ intent: PendingAgentCreation) {
        guard !creating else { return }
        currentContext = intent.context
        restoreDraft(intent)
        problem = nil
    }

    private func restoreDraft(_ intent: PendingAgentCreation) {
        draft.cwd = intent.cwd
        draft.profile = intent.profile
        draft.permission = intent.permission
        draft.prompt = prompts[intent.context]?.text ?? ""
    }

    /// An explicit new intent keeps the old unresolved record available for recovery.
    func startAnother() {
        guard !creating, storageProblem == nil else { return }
        currentContext = nil
        draft.prompt = ""
        problem = nil
    }

    /// Return only keys whose captured terminal positively ended or changed
    /// owner. Missing cards/terminals keep a receipt waiting for list takeover.
    func observed(_ cards: [ArgoAgentCard], terminals: [ArgoTerminalView], host: UUID, workspace: String) -> Set<SessionKey> {
        var retired: Set<SessionKey> = []
        let remaining = pending.filter { intent in
            guard intent.host == host, intent.workspace == workspace, let key = intent.key else { return true }
            guard let terminal = terminals.first(where: {
                $0.id == key.terminal && $0.ws == key.workspace && $0.context == intent.context && $0.cwd == intent.cwd
            }) else { return true }
            if terminal.alive == false || (terminal.alive == true && (terminal.agent == nil ||
                terminal.agent.map { ArgoRun.isManaged($0.run) && $0.run != key.run } == true)) {
                retired.insert(key)
                return false
            }
            return !cards.contains { $0.ws == key.workspace && $0.run == key.run && $0.terminal == key.terminal }
        }
        guard remaining.count != pending.count else { return retired }
        let finishedCurrent = currentContext != nil && !remaining.contains { $0.context == currentContext }
        pending = remaining
        if finishedCurrent { currentContext = nil; draft.prompt = "" }
        do {
            try store.save(remaining)
        } catch { storageProblem = L10n.error(error) }
        return retired
    }

    func terminalGone(_ key: SessionKey) -> Bool {
        let remaining = pending.filter { $0.key != key }
        guard remaining.count != pending.count else { return false }
        let finishedCurrent = currentContext != nil && !remaining.contains { $0.context == currentContext }
        pending = remaining
        if finishedCurrent { currentContext = nil; draft.prompt = "" }
        do {
            try store.save(remaining)
        } catch { storageProblem = L10n.error(error) }
        return true
    }

    func forgetHost(_ host: UUID) {
        prompts = prompts.filter { $0.value.host != host }
        if presentedHost == host { draft.prompt = "" }
        let forgotten = pending.filter { $0.host == host }
        guard !forgotten.isEmpty else { return }
        for intent in forgotten {
            prompts[intent.context] = nil
            candidates[intent.context] = nil
            if currentContext == intent.context { currentContext = nil; draft.prompt = "" }
        }
        pending.removeAll { $0.host == host }
        // A late create/read has no pending record to adopt after forgetting.
        do { try store.save(pending) }
        catch { storageProblem = L10n.error(error) }
    }
}
