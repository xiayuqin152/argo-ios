import ArgoMobileKit
import Foundation
import Glibc
import Observation
import Synchronization

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private enum Outcome: String, CaseIterable, Sendable {
    case delivered, queued, held, notSent, rejected, serverUnknown, lostReceipt, cancelledAfterWrite, malformed, lateResult
    case unboundUnknownRemoved, nativeUnknown, ptyUnknown, queuedThenUnknown, unrelatedUnknown, lateUnknown, backgroundUnknown, staleQueuedReceipt
    case replySent, replyRejected, replyUnknown, replyWrongID, replyNotSent
    case composerNativeSwitch
    var isReply: Bool { rawValue.hasPrefix("reply") }
}

// Fixture native content is a controlled GET boundary, not PTY output and not
// evidence of real CLI behavior. Actual server/CLI evidence is recorded separately.
private actor DeliveryTransport: ArgoHTTPTransport {
    let outcome: Outcome
    let text = "SYNTHETIC_PHONE_VISIBILITY_20261116\n  保留原文🙂  "
    private(set) var requests: [HTTPRequest] = []
    private var native: [String] = []
    private var nativeSession = "native-r1"
    private var pending = false
    private var evidenceGeneration = 0
    private var unknown = false
    private(set) var queueReads = 0
    private(set) var chatReads = 0
    private var holdChat = false
    private var heldChat: CheckedContinuation<Void, Never>?
    var chatWaiting: Bool { heldChat != nil }
    func holdInitialChat() { holdChat = true }
    func releaseChat() { holdChat = false; heldChat?.resume(); heldChat = nil }
    let unknownReason = "synthetic acknowledgement lost after native acceptance"
    private var late: CheckedContinuation<HTTPResponse, Never>?
    private var lateResponse: HTTPResponse?
    var waiting: Bool { late != nil }
    var nativeCount: Int { native.count }
    init(_ outcome: Outcome) { self.outcome = outcome }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async {}
    func releaseLate() {
        if let lateResponse { late?.resume(returning: lateResponse) }
        late = nil; lateResponse = nil
    }
    func switchNative(to session: String) { nativeSession = session }
    func removeQueueRecord() { pending = false }
    func replaceUnknownBatch(_ generation: Int) { evidenceGeneration = generation; pending = true; unknown = true }
    func markQueueUnknown() { unknown = true; if native.isEmpty { native.append(text) } }
    func deliverQueued() { if pending { native.append(text); pending = false } }
    private func json(_ value: Any, status: Int = 200) throws -> HTTPResponse {
        var payload = value
        if var object = value as? [String: Any], object["queue"] != nil || (object["items"] != nil && object["hold"] != nil) {
            object["bounded"] = true; object["byteLimit"] = 8_388_608
            payload = object
        }
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")],
                            body: try JSONSerialization.data(withJSONObject: payload), reusable: true)
    }
    private func item() -> [String: Any] {
        var value: [String: Any] = ["id": "fixture-item", "text": text, "submit": true, "source": "ios", "created": "2026-11-16T03:20:00Z"]
        if unknown { value["deliveryUnknown"] = unknownReason }
        return value
    }
    private func queue(run: String) -> [String: Any] {
        var items: [[String: Any]] = run == "r1" && pending ? [item()] : []
        if run == "r1", evidenceGeneration > 0 {
            items = (1...20).map { n in
                ["id": "unrelated-\(evidenceGeneration)-\(n)", "text": text,
                 "deliveryUnknown": unknownReason] as [String: Any]
            }
        }
        if outcome == .unrelatedUnknown, pending, run == "r1" {
            // Same original text, different item: the unknown head must not taint our receipt.
            items.insert(["id": "other-item", "text": text, "deliveryUnknown": unknownReason], at: 0)
        }
        return ["run": run, "state": "working", "hold": unknown || outcome == .unrelatedUnknown ? "这条消息的投递结果未知，已停止自动重试和再次发送" : pending ? "Agent 正在工作" : "", "items": items]
    }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        let url = URLComponents(string: "http://fixture.invalid" + request.target)!
        let path = url.path
        if request.method == "POST" {
            guard path == "/api/agents/r1/queue" || path == "/api/agents/r1/reply" else { throw CheckFailure("Unexpected POST") }
            guard !reuse else { throw CheckFailure("Write allowed transport replay") }
            requests.append(request)
            let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            guard body["text"] as? String == text else { throw CheckFailure("Original message text changed") }
            guard let attempt = request.headers.first(where: { $0.0 == "X-Loom-Attempt" })?.1, ArgoAttempt.valid(attempt) else { throw CheckFailure("Attempt missing") }
            if outcome.isReply {
                guard body["terminal"] as? String == "t1", body["questionID"] as? String == "q1", body["agent"] as? String == "" else { throw CheckFailure("Wrong reply destination") }
            } else {
                guard let target = body["target"] as? [String: Any], target["run"] as? String == "r1",
                      target["engine"] as? String == "codex", target["session"] as? String == nativeSession,
                      body["source"] as? String == "ios", body["submit"] as? Bool == true,
                      body["when"] as? String == "auto" else { throw CheckFailure("Message target or queue contract changed") }
            }
            if [.notSent, .replyNotSent].contains(outcome), requests.count == 1 { throw TransportFailure.notSent("synthetic before-write failure") }
            if [.rejected, .replyRejected].contains(outcome) { return try json(["error": "目标已变化，没有写入", "code": "target_changed"], status: 409) }
            if [.queued, .held, .queuedThenUnknown, .unrelatedUnknown, .staleQueuedReceipt, .unboundUnknownRemoved].contains(outcome) {
                pending = true
                let response = try json(["delivered": false, "item": item(), "queue": queue(run: "r1")])
                if [.staleQueuedReceipt, .unboundUnknownRemoved].contains(outcome) {
                    lateResponse = response
                    return await withCheckedContinuation { late = $0 }
                }
                return response
            }
            if [.nativeUnknown, .ptyUnknown, .lateUnknown, .backgroundUnknown].contains(outcome) {
                pending = true; unknown = true
                native.append(text)
                var value: [String: Any] = ["delivered": false, "item": item(), "queue": queue(run: "r1")]
                if outcome == .ptyUnknown { value["note"] = "终端服务没响应，输入结果未知" }
                let response = try json(value)
                if [.lateUnknown, .backgroundUnknown].contains(outcome) {
                    lateResponse = response
                    return await withCheckedContinuation { late = $0 }
                }
                return response
            }
            native.append(text)
            switch outcome {
            case .serverUnknown: return try json(["error": "synthetic uncertain native write"], status: 500)
            case .lostReceipt, .replyUnknown: throw TransportFailure.noReply("synthetic lost ACK")
            case .cancelledAfterWrite: throw TransportFailure.cancelled(afterWrite: true)
            case .malformed: return try json([:])
            case .replyWrongID: return try json(["status": "sent", "id": "other-question"])
            default: break
            }
            let response = outcome.isReply ? try json(["status": "sent", "id": "q1"]) : try json(["delivered": true, "queue": queue(run: "r1")])
            if [.lateResult, .lateUnknown].contains(outcome) {
                lateResponse = response
                return await withCheckedContinuation { late = $0 }
            }
            return response
        }
        if path == "/api/health" { return try json(["api": 1, "version": "fixture"]) }
        if path == "/api/projects" || path == "/api/agents/profiles" { return try json([]) }
        if path == "/api/workspaces" { return try json([["id": "w1"]]) }
        if path == "/api/agents" {
            return try json((1...2).map { n in
                ["run": "r\(n)", "terminal": "t\(n)", "ws": "w1", "engine": "codex", "status": "active", "state": "working", "queued": n == 1 && pending ? (outcome == .unrelatedUnknown ? 2 : 1) : 0] as [String: Any]
            })
        }
        if path == "/api/terminals" {
            return try json((1...2).map { n in ["id": "t\(n)", "ws": "w1", "alive": true, "agent": ["run": "r\(n)", "engine": "codex"]] as [String: Any] })
        }
        if path.hasSuffix("/chat") {
            chatReads += 1
            if holdChat { await withCheckedContinuation { heldChat = $0 } }
            let run = path.contains("/t1/") ? "r1" : "r2"
            let texts = run == "r1" ? native : []
            let after = url.queryItems?.first(where: { $0.name == "after" })?.value ?? "0:0"
            let start = Int(after.split(separator: ":")[0])!
            let items = texts.enumerated().filter { $0.offset * 100 >= start }.map { index, text in
                ["id": "fixture-native-\(index)", "offset": index * 100, "cursor": "\(index * 100):0", "type": "message", "role": "user", "text": text] as [String: Any]
            }
            return try json(["bounded": true, "byteLimit": 1_048_576,
                             "identity": ["run": run, "engine": "codex", "session": run == "r1" ? nativeSession : "native-\(run)"],
                             "items": items, "start": after, "end": "\(texts.count * 100):0", "size": texts.count * 100,
                             "older": false, "newer": false])
        }
        if path.hasSuffix("/queue") { queueReads += 1; return try json(queue(run: String(path.split(separator: "/")[2]))) }
        if path == "/api/agents/r1" || path == "/api/agents/r2" {
            let run = String(path.split(separator: "/").last!)
            let asks: [[String: Any]] = outcome.isReply && run == "r1" ? [["run": run, "questionID": "q1", "kind": "question", "text": "fixture question", "agent": "", "questions": 1]] : []
            return try json(["run": run, "asks": asks])
        }
        throw CheckFailure("Unexpected read: \(request.target)")
    }
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}

@MainActor private func eventually(_ message: String, _ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < end {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CheckFailure(message)
}

@MainActor private final class LoadFixture {
    let directory: URL
    let transport = DeliveryTransport(.composerNativeSwitch)
    let store: ArgoHostStore
    let model: AppModel
    let key: SessionKey
    let state: ConversationState
    init(holdFirst: Bool) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-load-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
            GatewayCredential(device: "fixture-device", token: String(repeating: "b", count: 43))
        }
        let host = try await store.pair(code: "argo1:fixture.invalid:6779:\(Base64URL.encode(Data(repeating: 1, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))", deviceName: "fixture")
        let transport = transport
        let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in ArgoConnection(host: host, transport: transport) }
        self.model = model
        await model.loadHosts()
        model.setActive(true)
        try await eventually("Real host/agent directory ready") { model.agents.count == 2 && model.status.isConnected }
        key = SessionKey(host: host.id, workspace: "w1", run: "r1", terminal: "t1")
        model.selectSession(key)
        guard let selected = model.conversation else { throw CheckFailure("No actual selected ConversationState") }
        state = selected
        if holdFirst { await transport.holdInitialChat() }
        model.showConversation(key, visible: true)
        if holdFirst {
            try await eventually("First actual chat GET held") { await transport.chatWaiting }
            guard state.transcript.identity == nil else { throw CheckFailure("First-load control already had a native identity") }
        } else {
            try await eventually("N1 ready") { self.state.transcript.identity?.session == "native-r1" && self.state.team != nil }
        }
    }
    func finish() async {
        model.setActive(false)
        await transport.releaseChat()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private func initialLoad(_ f: LoadFixture) async throws {
    let model = f.model, state = f.state
    let original = f.transport.text
    state.draft = original
    let chat = ComposerChatProbe(state: state, model: model)
    chat.renewInputOwner()
    guard let owner = chat.inputOwner, owner.acceptsInput, state.transcript.identity == nil else {
        throw CheckFailure("Fresh nil-identity owner was unavailable while first GET was held")
    }
    let prompt = ComposerPromptProbe(input: owner, model: model, renew: { chat.renewInputOwner() })
    prompt.pagePresentation.setPresented(true, in: model, conversation: state.key)
    let cover = prompt.pagePresentation.owner
    let page = ComposerPageProbe(input: owner, send: chat.sendAction(for: owner))
    page.canSend = false
    page.appear()
    guard prompt.pagePresentation.isPresented && page.focused else { throw CheckFailure("Initial full editor control did not open") }
    let oldCanCommit = owner.canCommit
    await f.transport.releaseChat()
    try await eventually("First N1 response actually applied") { state.transcript.identity?.session == "native-r1" && state.team != nil }
    if oldCanCommit != owner.canCommit {
        page.inputChanged(owner.canCommit)
        if !owner.canCommit { prompt.inputRevoked() }
    }
    let posts = await f.transport.requests.count
    print("OBSERVED initial-load: nil->N1, sameState=\(model.conversation === state), sameKey=\(model.selectedKey == state.key), noticeNil=\(state.sessionNotice == nil), canCommit=\(owner.canCommit), pagePresented=\(prompt.pagePresentation.isPresented), pageFocused=\(page.focused), draftKept=\(state.draft == original), ownerAwaitingDismissal=\(prompt.pagePresentation.owner == cover), POST=\(posts)")
    guard state.sessionNotice == nil && owner.canCommit && owner.valid && page.focused &&
          prompt.pagePresentation.isPresented && chat.inputOwner === owner && state.draft == original && posts == 0 else {
        throw CheckFailure("INITIAL_NATIVE_LOAD_REVOKED: first nil->N1 load revoked the valid editor and requested dismissal without a target-change notice")
    }
}

@MainActor private func stableRefresh(_ f: LoadFixture) async throws {
    let model = f.model, state = f.state
    let original = f.transport.text
    state.draft = original
    let chat = ComposerChatProbe(state: state, model: model)
    chat.renewInputOwner()
    guard let owner = chat.inputOwner, owner.acceptsInput else { throw CheckFailure("No N1 owner") }
    let prompt = ComposerPromptProbe(input: owner, model: model, renew: { chat.renewInputOwner() })
    prompt.pagePresentation.setPresented(true, in: model, conversation: state.key)
    let cover = prompt.pagePresentation.owner
    let page = ComposerPageProbe(input: owner, send: chat.sendAction(for: owner))
    page.appear()
    for index in 0..<3 {
        let prior = await f.transport.chatReads
        if index == 1 { model.showLatest() } else { model.refreshConversation() }
        try await eventually("Real unchanged-identity refresh applied") {
            let reads = await f.transport.chatReads
            return reads > prior && !state.loading && !state.loadingOlder && state.transcript.identity?.session == "native-r1"
        }
        guard owner.canCommit && owner.acceptsInput && chat.inputOwner === owner &&
              prompt.pagePresentation.isPresented && prompt.pagePresentation.owner == cover && page.focused &&
              state.sessionNotice == nil && state.draft == original else {
            throw CheckFailure("Unchanged native identity refresh revoked or closed the editor")
        }
    }
    prompt.pagePresentation.requestDismissal()
    prompt.pageDismissed()
    let posts = await f.transport.requests
    guard prompt.focused && prompt.pagePresentation.owner == nil && chat.inputOwner === owner && state.draft == original &&
          posts.isEmpty else { throw CheckFailure("Normal cancellation after steady refresh changed the current owner/draft or made a POST") }
    print("OBSERVED stable-refresh: three actual reads, identity=N1, sameOwner=true, pageRemainsPresented=true, draftKept=true, normalCancelRenews=false, POST=0")
}

@main private enum LoadBoundaryCheck {
    @MainActor static func main() async {
        let name = CommandLine.arguments.dropFirst().first ?? ""
        do {
            let f = try await LoadFixture(holdFirst: name == "initial-nil-to-valid")
            do {
                if name == "initial-nil-to-valid" { try await initialLoad(f) }
                else if name == "stable-refresh" { try await stableRefresh(f) }
                else { throw CheckFailure("Unknown boundary") }
                await f.finish()
            } catch { await f.finish(); throw error }
            print("PASS \(name): actual fixed ComposerInputOwner/view callbacks and AppModel GET lifecycle")
        } catch { print("FAIL \(name): \(error)"); exit(1) }
    }
}
