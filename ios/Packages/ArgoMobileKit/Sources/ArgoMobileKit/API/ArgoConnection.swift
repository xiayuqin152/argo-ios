import Foundation

/// A message for an Agent's conversation (`POST /api/agents/{run}/queue`).
public struct ArgoOutgoingMessage: Equatable, Sendable {
    public let run: String
    public let text: String
    /// The chat identity the user was looking at (`ArgoChatPage.identity`).
    /// With it loomd refuses (409) a message for a terminal that now runs
    /// another process or session instead of typing it there.
    public let target: ArgoAgentIdentity?
    /// loomd's idempotency key (X-Loom-Attempt). A message the user sends
    /// again after `deliveryUnknown` keeps its attempt: loomd replays the
    /// first result for 10 minutes instead of delivering it twice.
    public let attempt: String

    public init(run: String, text: String, target: ArgoAgentIdentity?, attempt: String = ArgoAttempt.make()) {
        self.run = run
        self.text = text
        self.target = target
        self.attempt = attempt
    }
}

/// Attempt ids in loomd's format (`^[A-Za-z0-9_-]{8,64}$`, attempts.go).
public enum ArgoAttempt {
    public static func make() -> String {
        let uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: uuid) { Data($0) }
        return "ios-" + Base64URL.encode(bytes)
    }

    public static func valid(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_-]{8,64}\\z", options: .regularExpression) != nil
    }
}

/// Run handles loomd's managed endpoints take. `/api/attention` also lists
/// hand-started CLIs (`unmanaged:<terminal>`), background jobs
/// (`background:[…]`) and external sessions; those have no run queue or team
/// view, only their terminal's chat.
public enum ArgoRun {
    public static func isManaged(_ run: String) -> Bool {
        !run.isEmpty && run.count <= 128 && !run.contains(":") && !run.contains("/")
            && run.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }
}

/// The phone's connection to one paired dev machine: loomd's HTTP API over
/// the gateway. One per host; switching hosts or leaving the foreground
/// closes it and a new one is made. Every method is async and throws
/// `ArgoClientError` (or `CancellationError` when the calling task was
/// cancelled before anything could have reached loomd).
///
/// Reads may run concurrently. Message, reply and interrupt writes are attempted once:
/// they are never retried here, and a failure says whether they could have
/// arrived (`notSent` / `deliveryUnknown`).
public actor ArgoConnection {
    public nonisolated let host: LoomHost
    private let transport: any ArgoHTTPTransport
    private var token: String?
    private struct TokenFetch {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<String, Error>]
    }
    private var tokenFetch: TokenFetch?
    private var closed = false

    /// The phone's source label in loomd's queue records (free text, ≤ 32 bytes).
    public static let source = "ios"

    public init(host: LoomHost, transport: any ArgoHTTPTransport) {
        self.host = host
        self.transport = transport
    }

    #if canImport(Network)
    /// The real connection: pinned TLS gateway streams with the device
    /// credential from pairing.
    public init(host: LoomHost, credential: GatewayCredential) throws {
        do {
            self.init(host: host, transport: try GatewayHTTPTransport(host: host, credential: credential))
        } catch let error as GatewayError {
            throw ArgoClientError.needsPairing(.gateway(error))
        } catch {
            throw ArgoClientError.needsPairing(.detail(error.localizedDescription))
        }
    }
    #endif

    /// Reads the loomd token again and checks loomd answers with a protocol
    /// this app speaks. The UI's 「重试」 calls it.
    public func connect() async throws -> ArgoServerInfo {
        try checkOpen()
        token = nil
        let health: ArgoHealth = try await get("/api/health")
        let hello = GatewayHello(version: health.version, commit: health.commit, ptyd: nil, arch: nil, api: health.api)
        if LoomdAPI.refusal(hello: hello, hostName: host.displayName) != nil {
            throw ArgoClientError.unsupportedServer(.message(
                "Argo on %@ uses protocol %@; this app requires %@ or later. Connect with Argo for Mac to update the host.",
                arguments: [host.displayName, String(health.api ?? 0), String(LoomdAPI.minimum)]))
        }
        return ArgoServerInfo(host: host.id, version: health.version, commit: health.commit,
                              api: health.api ?? 0, machine: health.host)
    }

    /// Ends every stream. Later calls throw `.closed`; requests in flight end
    /// with `.closed` (a send in flight with `deliveryUnknown`).
    public func close() async {
        guard !closed else { return }
        closed = true
        if let fetch = tokenFetch {
            tokenFetch = nil
            fetch.task.cancel()
            for waiter in fetch.waiters.values { waiter.resume(throwing: ArgoClientError.closed) }
        }
        token = nil
        await transport.close()
    }

    public var isClosed: Bool { closed }

    // MARK: Reads

    public func projects() async throws -> [ArgoProject] {
        // A store with no projects answers null.
        let list: [ArgoProject]? = try await get("/api/projects")
        return list ?? []
    }

    public func workspaces() async throws -> [ArgoWorkspace] {
        let list: [ArgoWorkspace]? = try await get("/api/workspaces")
        return list ?? []
    }

    /// Questions waiting for the user and every run's state, all workspaces.
    public func attention() async throws -> AttentionSnapshot {
        try await get("/api/attention")
    }

    /// The Agent sessions of one workspace (`GET /api/agents?ws=`), newest run first.
    /// The terminal list owns current chat destinations; `/agents` also contains
    /// released-shell history, which cannot reopen that run via current `/chat`.
    public func agents(workspace: String) async throws -> [ArgoAgentCard] {
        guard !workspace.isEmpty else { throw ArgoClientError.refusedLocally(.message("Choose a workspace first.")) }
        let query = Self.query(["ws": workspace])
        async let managed: [ArgoAgentCard]? = get("/api/agents" + query)
        async let terminals = self.terminals(workspace: workspace)
        let (list, terminalList) = try await (managed, terminals)
        let currentTerminals = terminalList.filter { $0.ws == workspace }
        let currentRuns = Dictionary(uniqueKeysWithValues: currentTerminals.compactMap { terminal in
            terminal.agent.map { (terminal.id, $0.run) }
        })
        // These GETs are independent snapshots. A managed card must agree with
        // terminal ownership; a missing/mismatched run waits for the next poll.
        // Never suppress the current manual CLI because of an old managed card.
        let cards = (list ?? []).filter { $0.ws == workspace && currentRuns[$0.terminal] == $0.run }
        let manual = currentTerminals.compactMap(ArgoAgentCard.init(manual:))
        return cards + manual
    }

    /// One run's progress: plan, team tasks, recent steps, pending asks.
    public func team(run: String) async throws -> ArgoTeamView {
        try await get("/api/agents/\(try Self.managedSegment(run))")
    }

    /// A bounded (1 MiB) block page of a terminal's native conversation.
    /// Older servers without the bounded marker require an update.
    /// With `session` (the
    /// identity's session from an earlier page) loomd answers 409 when the
    /// terminal moved to another session; that surfaces as `.http(409…)`
    /// and the caller reloads `.latest`.
    public func chat(terminal: String, cursor: ArgoChatCursor = .latest, session: String? = nil) async throws -> ArgoChatPage {
        guard !terminal.isEmpty else { throw ArgoClientError.refusedLocally(.message("This session has no terminal to read.")) }
        var query: [String: String] = ["bounded": "1"]
        switch cursor {
        case .latest: break
        case .before(let position), .after(let position), .around(let position):
            guard position.isValid else { throw ArgoClientError.refusedLocally(.message("The chat cursor is invalid. Refresh the conversation.")) }
            switch cursor {
            case .before: query["before"] = position.description
            case .after: query["after"] = position.description
            case .around: query["around"] = position.description
            case .latest: break
            }
        }
        if let session, !session.isEmpty, cursor != .latest { query["session"] = session }
        let request = HTTPRequest(method: "GET", target: "/api/terminals/\(Self.segment(terminal))/chat" + Self.query(query),
                                  maxResponseBodyBytes: ArgoChatPage.responseByteLimit)
        let response = try await perform(request, authRetry: true)
        guard response.body.count <= ArgoChatPage.responseByteLimit else { throw Self.chatUpgradeRequired }
        return try decode(response)
    }

    /// One turn of the main Agent: the latest, or `turn` (1-based) for older ones.
    public func answer(run: String, turn: Int? = nil) async throws -> ArgoTurnAnswer {
        if let turn, turn < 1 { throw ArgoClientError.refusedLocally(.message("Turn numbers start at 1.")) }
        let q = turn.map { Self.query(["turn": String($0)]) } ?? ""
        return try await get("/api/agents/\(try Self.managedSegment(run))/answer" + q)
    }

    public func queue(run: String) async throws -> ArgoQueue {
        try await get("/api/agents/\(try Self.managedSegment(run))/queue")
    }

    // MARK: Read markers

    /// Marks the managed run viewed, acknowledging only the question identities
    /// in the snapshot the user opened. Repeating the same exact marker is safe.
    public func markAgentSeen(run: String, waitingIDs: [String]) async throws {
        try await markSeen("/api/agents/\(try Self.managedSegment(run))/seen", waitingIDs: waitingIDs)
    }

    /// The corresponding read marker for a hand-started CLI's terminal.
    public func markTerminalSeen(terminal: String, waitingIDs: [String]) async throws {
        guard !terminal.isEmpty else { throw ArgoClientError.refusedLocally(.message("This session has no terminal to read.")) }
        try await markSeen("/api/terminals/\(Self.segment(terminal))/seen", waitingIDs: waitingIDs)
    }

    private func markSeen(_ target: String, waitingIDs: [String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["waitingIDs": waitingIDs], options: [.sortedKeys])
        let request = HTTPRequest(method: "POST", target: target, headers: [("Content-Type", "application/json")], body: data)
        // Authentication rejects the request before its handler. Unlike an Agent
        // message, an exact read marker is idempotent and may be resent after 401.
        _ = try await perform(request, authRetry: true)
    }

    /// Uploads one private staged file through this same paired connection.
    /// Uploads have no server idempotency key and are never retried here.
    public func uploadAttachment(_ file: ArgoLocalAttachment) async throws -> ArgoUploadedFile {
        let work = Task.detached(priority: .userInitiated) { try ArgoAttachmentMultipart(file: file) }
        let multipart = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        let request = HTTPRequest(method: "POST", target: "/api/upload",
                                  headers: [("Content-Type", "multipart/form-data; boundary=\(multipart.boundary)")],
                                  body: multipart.body, maxResponseBodyBytes: 64 * 1024)
        let response = try await perform(request, authRetry: false)
        try Task.checkCancellation()
        guard response.body.count <= request.maxResponseBodyBytes else {
            throw ArgoClientError.invalidResponse(.message("The host returned an invalid upload receipt."))
        }
        let files: [ArgoUploadedFile] = try decode(response)
        guard files.count == 1, let file = files.first else {
            throw ArgoClientError.invalidResponse(.message("The host returned an invalid upload receipt."))
        }
        try file.validate(expectedSize: multipart.size)
        return file
    }

    /// A fresh, bounded read from the original host/workspace/terminal. Redirects
    /// are refused by perform; no external request ever receives this token.
    public func downloadAttachment(_ reference: ArgoFileReference, workspace: String, terminal: String) async throws -> Data {
        guard !workspace.isEmpty, !terminal.isEmpty else {
            throw ArgoClientError.refusedLocally(.message("Choose a workspace and terminal before opening a file."))
        }
        let request = HTTPRequest(method: "GET", target: "/api/download" + Self.query([
            "ws": workspace, "path": reference.path, "terminal": terminal
        ]), maxResponseBodyBytes: ArgoAttachmentPolicy.byteLimit)
        let response = try await perform(request, authRetry: true)
        try Task.checkCancellation()
        guard response.body.count <= ArgoAttachmentPolicy.byteLimit else { throw ArgoAttachmentPolicy.tooLarge }
        return response.body
    }

    // MARK: Writes (never retried)

    public func profiles() async throws -> [ArgoAgentProfile] {
        try await get("/api/agents/profiles")
    }

    public func terminals(workspace: String) async throws -> [ArgoTerminalView] {
        let list: [ArgoTerminalView]? = try await get("/api/terminals" + Self.query(["ws": workspace]))
        return list ?? []
    }

    /// Exactly one POST. `context` is for recovery, never an idempotency key.
    public func createAgent(_ intent: ArgoCreateAgentRequest) async throws -> ArgoTerminalView {
        guard !intent.ws.isEmpty, !intent.cwd.isEmpty, !intent.profile.isEmpty,
              !intent.context.isEmpty, intent.context.utf8.count <= 4096,
              !intent.context.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ArgoClientError.refusedLocally(.message("Choose a workspace, folder and launcher first."))
        }
        guard !intent.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArgoClientError.refusedLocally(.message("Enter a first message."))
        }
        guard intent.prompt.utf8.count <= 256 * 1024 else {
            throw ArgoClientError.refusedLocally(.message("The message exceeds 256 KiB."))
        }
        let data = try JSONEncoder().encode(intent)
        guard data.count <= 1 << 20 else { throw ArgoClientError.refusedLocally(.message("The request exceeds 1 MiB.")) }
        let request = HTTPRequest(method: "POST", target: "/api/agents",
                                  headers: [("Content-Type", "application/json")], body: data)
        let response = try await perform(request, authRetry: false)
        guard response.status == 200 else {
            throw ArgoClientError.deliveryUnknown(.message("The creation result is unknown. Check the original intent before starting another Agent."))
        }
        let terminal: ArgoTerminalView = try receipt(response)
        guard terminal.matches(workspace: intent.ws, cwd: intent.cwd, profile: intent.profile, context: intent.context) else {
            throw ArgoClientError.deliveryUnknown(.message("The creation receipt does not match the original intent."))
        }
        return terminal
    }

    /// Stops the managed run's current turn, keeping its CLI alive. This endpoint
    /// has no attempt cache or turn/target precondition: never replay it, including
    /// after 401, a timeout or an unknown response. A later click is a new action
    /// against the run's then-current turn. Refresh state and queue afterwards.
    public func interrupt(run: String) async throws -> ArgoInterruptReceipt {
        let segment = try Self.managedSegment(run)
        let response = try await perform(HTTPRequest(method: "POST", target: "/api/agents/\(segment)/interrupt"), authRetry: false)
        let result: ArgoInterruptReceipt = try receipt(response)
        guard result.run == run,
              (result.sent && result.stopped && result.reason == nil) ||
              (result.sent && !result.stopped && result.reason == "timeout") ||
              (!result.sent && !result.stopped && ["not_working", "idle"].contains(result.reason ?? "")) else {
            throw ArgoClientError.deliveryUnknown(.message("The host returned an unrecognized stop receipt."))
        }
        return result
    }

    /// Claude's model-error recovery: one `/model ID`, then one resume claim
    /// after the host observes Claude's answer. Unlike message sends this
    /// endpoint has no attempt replay contract, so no attempt header is sent.
    public func switchModelAndResume(run: String, model rawID: String) async throws -> ArgoModelSwitchReceipt {
        let segment = try Self.managedSegment(run)
        guard let id = ArgoModelID.normalized(rawID) else {
            throw ArgoClientError.refusedLocally(.message("Model IDs may contain only letters, digits and . : / @ [ ] - _, up to 80 characters."))
        }
        // The host waits up to 30 seconds for Claude's local-command output.
        // Only this request gets a longer finite window; the global default
        // remains 30 seconds. A timeout is deliveryUnknown, never a replay.
        let response = try await write("/api/agents/\(segment)/model", body: ["model": id], attempt: nil, timeout: 45)
        return try receipt(response)
    }

    /// Continues a conversation through loomd's queue (`when: auto`):
    /// written now when the Agent is idle, queued while it works or waits.
    public func send(_ message: ArgoOutgoingMessage) async throws -> ArgoSendReceipt {
        let segment = try Self.managedSegment(message.run)
        let text = message.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArgoClientError.refusedLocally(.message("The message is empty."))
        }
        guard text.utf8.count <= 256 * 1024 else { throw ArgoClientError.refusedLocally(.message("The message exceeds 256 KiB.")) }
        guard ArgoAttempt.valid(message.attempt) else { throw ArgoClientError.refusedLocally(.message("The send identifier is invalid.")) }
        if let target = message.target, target.run != message.run {
            throw ArgoClientError.refusedLocally(.message("The conversation changed. The message was not sent."))
        }
        var body: [String: Any] = ["text": text, "submit": true, "source": Self.source, "when": "auto"]
        if let target = message.target {
            body["target"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
        }
        let response = try await write("/api/agents/\(segment)/queue", body: body, attempt: message.attempt)
        let result: DeliverResult = try receipt(response)
        return ArgoSendReceipt(run: message.run, attempt: message.attempt, delivered: result.delivered,
                               queued: result.item, queue: result.queue, pasted: result.pasted, note: result.note,
                               duplicate: response.header("X-Loom-Duplicate") == "1")
    }

    /// Answers one waiting question with the CLI's own keys
    /// (`POST /api/agents/{run}/reply`). Text equal to an option label picks
    /// that option. `attempt` as for `send`.
    public func reply(run: String, terminal: String, agent: String, questionID: String, text: String,
                      attempt: String = ArgoAttempt.make()) async throws -> AgentDeliveryReceipt {
        let segment = try Self.managedSegment(run)
        guard !terminal.isEmpty else { throw ArgoClientError.refusedLocally(.message("This question has no terminal. Answer it on your computer.")) }
        guard !questionID.isEmpty else { throw ArgoClientError.refusedLocally(.message("This question has no identifier. Refresh before answering.")) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArgoClientError.refusedLocally(.message("The answer is empty."))
        }
        guard text.utf8.count <= 64 * 1024 else { throw ArgoClientError.refusedLocally(.message("The answer exceeds 64 KiB.")) }
        guard ArgoAttempt.valid(attempt) else { throw ArgoClientError.refusedLocally(.message("The send identifier is invalid.")) }
        let body: [String: Any] = ["terminal": terminal, "agent": agent, "questionID": questionID, "text": text]
        let response = try await write("/api/agents/\(segment)/reply", body: body, attempt: attempt)
        return try receipt(response)
    }

    /// A question from `/api/attention`. One only the terminal can answer is
    /// refused here without a request.
    public func reply(_ question: AttentionQuestion, text: String, attempt: String = ArgoAttempt.make()) async throws -> AgentDeliveryReceipt {
        guard question.acceptsReply else {
            throw ArgoClientError.refusedLocally(question.terminalOnly.map { .detail($0) } ?? .message("Answer this question in the terminal on your computer."))
        }
        return try await reply(run: question.run, terminal: question.terminal, agent: question.agent,
                               questionID: question.questionID ?? "", text: text, attempt: attempt)
    }

    /// A pending ask from a card or the team view, on `terminal`.
    public func reply(_ ask: ArgoAsk, terminal: String, text: String, attempt: String = ArgoAttempt.make()) async throws -> AgentDeliveryReceipt {
        guard ask.acceptsReply else {
            throw ArgoClientError.refusedLocally(ask.terminalOnly.map { .detail($0) } ?? .message("Answer this question in the terminal on your computer."))
        }
        return try await reply(run: ask.run, terminal: terminal, agent: ask.agent, questionID: ask.questionID,
                               text: text, attempt: attempt)
    }

    // MARK: Requests

    private func checkOpen() throws {
        if closed { throw ArgoClientError.closed }
    }

    private func loomdToken() async throws -> String {
        try Task.checkCancellation()
        if let token { return token }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var fetch = tokenFetch {
                    fetch.waiters[waiterID] = continuation
                    tokenFetch = fetch
                } else {
                    let fetchID = UUID()
                    let task = Task { [transport] in
                        let result: Result<String, Error>
                        do { result = .success(try await transport.loomdToken()) }
                        catch { result = .failure(error) }
                        finishToken(fetchID, result: result)
                    }
                    tokenFetch = TokenFetch(id: fetchID, task: task, waiters: [waiterID: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelTokenWaiter(waiterID) }
        }
    }

    private func cancelTokenWaiter(_ id: UUID) {
        guard var fetch = tokenFetch, let waiter = fetch.waiters.removeValue(forKey: id) else { return }
        if fetch.waiters.isEmpty {
            tokenFetch = nil
            fetch.task.cancel()
        } else {
            tokenFetch = fetch
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finishToken(_ id: UUID, result: Result<String, Error>) {
        // A cancelled fetch may finish after a replacement has started.
        guard let fetch = tokenFetch, fetch.id == id else { return }
        tokenFetch = nil
        if case .success(let value) = result { token = value }
        for waiter in fetch.waiters.values { waiter.resume(with: result) }
    }

    private func get<T: Decodable>(_ target: String) async throws -> T {
        try decode(try await perform(HTTPRequest(method: "GET", target: target), authRetry: true))
    }

    private func write(_ target: String, body: [String: Any], attempt: String?, timeout: TimeInterval? = nil) async throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var headers = [("Content-Type", "application/json")]
        if let attempt { headers.append(("X-Loom-Attempt", attempt)) }
        let request = HTTPRequest(method: "POST", target: target, headers: headers, body: data)
        return try await perform(request, authRetry: false, timeout: timeout)
    }

    private func perform(_ base: HTTPRequest, authRetry: Bool, timeout: TimeInterval? = nil) async throws -> HTTPResponse {
        try checkOpen()
        try Task.checkCancellation()
        let write = !base.idempotent
        let token: String
        do {
            token = try await loomdToken()
        } catch {
            throw mapTokenFailure(error, write: write)
        }
        try checkOpen()
        try Task.checkCancellation()
        var request = base
        request.headers = [("Authorization", "Bearer \(token)"), ("Accept", "application/json")] + base.headers
        let response: HTTPResponse
        do {
            response = try await transport.send(request, reuse: base.idempotent, timeout: timeout)
        } catch {
            if case HTTPError.tooLarge = error, base.maxResponseBodyBytes == ArgoAttachmentPolicy.byteLimit {
                throw ArgoAttachmentPolicy.tooLarge
            }
            if case HTTPError.tooLarge = error, base.maxResponseBodyBytes == ArgoChatPage.responseByteLimit {
                throw Self.chatUpgradeRequired
            }
            throw mapSendFailure(error, write: write)
        }
        if response.status == 401 {
            // loomd's token changed (argo token rotation): forget it. A read
            // goes once more with the new one; a write was refused by the
            // guard before its handler and is reported, not repeated.
            if self.token == token { self.token = nil }
            if authRetry, !closed { return try await perform(base, authRetry: false, timeout: timeout) }
        }
        guard (200..<300).contains(response.status) else {
            throw Self.httpError(response)
        }
        return response
    }

    private func mapTokenFailure(_ error: Error, write: Bool) -> Error {
        if closed { return ArgoClientError.closed }
        // Only the token stream has been opened: no HTTP write can have
        // reached loomd, regardless of how token retrieval failed.
        let mapped = mapSendFailure(error, write: false)
        guard write else { return mapped }
        switch mapped {
        case ArgoClientError.gateway(let gateway): return ArgoClientError.notSent(.gateway(gateway))
        case ArgoClientError.deliveryUnknown(let reason): return ArgoClientError.notSent(reason)
        default: return mapped
        }
    }

    private func mapSendFailure(_ error: Error, write: Bool) -> Error {
        switch error {
        case let failure as TransportFailure:
            switch failure {
            case .open(let gateway):
                if gateway.isFatal { return ArgoClientError.needsPairing(.gateway(gateway)) }
                return write ? ArgoClientError.notSent(.gateway(gateway)) : ArgoClientError.gateway(gateway)
            case .notSent(let reason):
                return write ? ArgoClientError.notSent(reason) : ArgoClientError.gateway(.network(reason.description))
            case .noReply(let reason):
                return write ? ArgoClientError.deliveryUnknown(reason) : ArgoClientError.gateway(.network(reason.description))
            case .cancelled(let afterWrite):
                if write, afterWrite { return ArgoClientError.deliveryUnknown(.message(closed ? "The connection is closed." : "Sending was cancelled.")) }
                return closed ? ArgoClientError.closed : CancellationError()
            case .closed:
                return ArgoClientError.closed
            }
        case let http as HTTPError:
            if case .invalidRequest = http { return ArgoClientError.refusedLocally(.message("The request is invalid.")) }
            return write ? ArgoClientError.deliveryUnknown(.message("The host returned an invalid response.")) : ArgoClientError.invalidResponse(.message("The host returned an invalid response."))
        case is CancellationError:
            return closed ? ArgoClientError.closed : error
        default:
            return write ? ArgoClientError.deliveryUnknown(.detail(error.localizedDescription)) : ArgoClientError.gateway(.network(error.localizedDescription))
        }
    }

    static func httpError(_ response: HTTPResponse) -> ArgoClientError {
        let message = LoomError.responseMessage(response.body, fallback: "")
        let code = ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["code"] as? String
        return .http(status: response.status, message: message, code: code?.isEmpty == false ? code : nil)
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch let error as ArgoClientError {
            throw error
        } catch {
            throw ArgoClientError.invalidResponse(.message("The host response could not be decoded (%@). The Argo versions may not match.", arguments: [String(describing: T.self)]))
        }
    }

    private static var chatUpgradeRequired: ArgoClientError {
        .unsupportedServer(.message("Update Argo on the host to read bounded 1 MiB chat pages."))
    }

    private func receipt<T: Decodable>(_ response: HTTPResponse) throws -> T {
        do { return try decode(response) }
        catch { throw ArgoClientError.deliveryUnknown(.message("The host processed the request, but its delivery receipt could not be decoded.")) }
    }

    // MARK: Paths

    /// A path segment with everything but unreserved characters escaped.
    static func segment(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func managedSegment(_ run: String) throws -> String {
        guard ArgoRun.isManaged(run) else {
            throw ArgoClientError.refusedLocally(.message("This session was not started by Argo. You can only view its conversation."))
        }
        return segment(run)
    }

    /// `?a=b&c=d`, keys sorted, values escaped; "" for no parameters.
    static func query(_ items: [String: String]) -> String {
        guard !items.isEmpty else { return "" }
        return "?" + items.keys.sorted().map { "\(segment($0))=\(segment(items[$0]!))" }.joined(separator: "&")
    }
}
