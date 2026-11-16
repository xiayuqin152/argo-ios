import ArgoMobileKit
import Foundation
import Glibc

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private enum Outcome: String, CaseIterable, Sendable {
    case delivered, queued, held, notSent, rejected, serverUnknown, lostReceipt, cancelledAfterWrite, malformed, lateResult
    case nativeUnknown, ptyUnknown, queuedThenUnknown, unrelatedUnknown, lateUnknown, backgroundUnknown, staleQueuedReceipt
    case replySent, replyRejected, replyUnknown, replyWrongID, replyNotSent
    var isReply: Bool { rawValue.hasPrefix("reply") }
}

// Fixture native content is a controlled GET boundary, not PTY output and not
// evidence of real CLI behavior. Actual server/CLI evidence is recorded separately.
private actor DeliveryTransport: ArgoHTTPTransport {
    let outcome: Outcome
    let text = "SYNTHETIC_PHONE_VISIBILITY_20261116\n  保留原文🙂  "
    private(set) var requests: [HTTPRequest] = []
    private var native: [String] = []
    private var pending = false
    private var unknown = false
    private(set) var queueReads = 0
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
    func removeQueueRecord() { pending = false }
    func markQueueUnknown() { unknown = true; if native.isEmpty { native.append(text) } }
    func deliverQueued() { if pending { native.append(text); pending = false } }
    private func json(_ value: Any, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")],
                     body: try JSONSerialization.data(withJSONObject: value), reusable: true)
    }
    private func item() -> [String: Any] {
        var value: [String: Any] = ["id": "fixture-item", "text": text, "submit": true, "source": "ios", "created": "2026-11-16T03:20:00Z"]
        if unknown { value["deliveryUnknown"] = unknownReason }
        return value
    }
    private func queue(run: String) -> [String: Any] {
        var items: [[String: Any]] = run == "r1" && pending ? [item()] : []
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
                      target["engine"] as? String == "codex", target["session"] as? String == "native-r1",
                      body["source"] as? String == "ios", body["submit"] as? Bool == true,
                      body["when"] as? String == "auto" else { throw CheckFailure("Message target or queue contract changed") }
            }
            if [.notSent, .replyNotSent].contains(outcome), requests.count == 1 { throw TransportFailure.notSent("synthetic before-write failure") }
            if [.rejected, .replyRejected].contains(outcome) { return try json(["error": "目标已变化，没有写入", "code": "target_changed"], status: 409) }
            if [.queued, .held, .queuedThenUnknown, .unrelatedUnknown, .staleQueuedReceipt].contains(outcome) {
                pending = true
                let response = try json(["delivered": false, "item": item(), "queue": queue(run: "r1")])
                if outcome == .staleQueuedReceipt {
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
            let run = path.contains("/t1/") ? "r1" : "r2"
            let texts = run == "r1" ? native : []
            let after = url.queryItems?.first(where: { $0.name == "after" })?.value ?? "0:0"
            let start = Int(after.split(separator: ":")[0])!
            let items = texts.enumerated().filter { $0.offset * 100 >= start }.map { index, text in
                ["id": "fixture-native-\(index)", "offset": index * 100, "cursor": "\(index * 100):0", "type": "message", "role": "user", "text": text] as [String: Any]
            }
            return try json(["bounded": true, "byteLimit": 1_048_576,
                             "identity": ["run": run, "engine": "codex", "session": "native-\(run)"],
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

@MainActor private func check(_ outcome: Outcome) async throws {
    let directory = URL(fileURLWithPath: "research/mobile-delivery-221c/fixtures/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
        GatewayCredential(device: "fixture-device", token: String(repeating: "b", count: 43))
    }
    let host = try await store.pair(code: "argo1:fixture.invalid:6779:\(Base64URL.encode(Data(repeating: 1, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))", deviceName: "fixture")
    let transport = DeliveryTransport(outcome)
    let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in ArgoConnection(host: host, transport: transport) }
    defer { model.setActive(false) }
    await model.loadHosts()
    model.setActive(true)
    try await eventually("Initial agent list") { model.agents.count == 2 }
    let key = SessionKey(host: host.id, workspace: "w1", run: "r1", terminal: "t1")
    model.selectSession(key)
    model.showConversation(key, visible: true)
    try await eventually("Initial native identity/team") { model.conversation?.canSendToIdentity == true && model.conversation?.team != nil }
    let state = model.conversation!
    let text = transport.text
    let ask = state.team?.asks.first
    if let ask { state.replyDrafts[ask.uiID] = text; model.reply(to: ask) }
    else { state.draft = text; model.sendDraft(for: key) }
    if [.lateResult, .lateUnknown].contains(outcome) {
        try await eventually("Delayed receipt") { await transport.waiting }
        let next = SessionKey(host: host.id, workspace: "w1", run: "r2", terminal: "t2")
        model.selectSession(next)
        model.showConversation(next, visible: true)
        try await eventually("Second conversation") { model.conversation?.canSendToIdentity == true }
        model.conversation?.draft = "keep second draft"
        await transport.releaseLate()
    }
    if outcome == .backgroundUnknown {
        try await eventually("Await background cancellation") { await transport.waiting }
        model.setActive(false)
        await transport.releaseLate()
        try await eventually("Late receipt while suspended") { state.deliveries.last?.status != .sending }
        model.setActive(true)
        try await eventually("Reconnect after suspension") { model.status.isConnected && state.canSendToIdentity }
    }
    if outcome == .staleQueuedReceipt {
        try await eventually("Await delayed queued receipt") { await transport.waiting }
        await transport.markQueueUnknown()
        let reads = await transport.queueReads
        model.refreshConversation()
        try await eventually("Queue refresh precedes receipt") { await transport.queueReads > reads && state.queue?.hold.contains("未知") == true }
        await transport.releaseLate()
    }
    try await eventually("Delivery finished") { state.deliveries.last?.status != .sending }
    guard let first = state.deliveries.last, first.operation.text == text else { throw CheckFailure("Operation text lost") }
    switch outcome {
    case .delivered, .lateResult: guard first.status == .delivered else { throw CheckFailure("Success not recorded") }
    case .replySent: guard first.status == .answered else { throw CheckFailure("Answer not recorded") }
    case .queued, .held, .queuedThenUnknown, .unrelatedUnknown:
        guard case .queued = first.status, !first.status.isKnownSuccess, state.transcript.items.isEmpty,
              state.queue?.items.last?.text == text, state.queue?.hold.isEmpty == false else { throw CheckFailure("Queue became native success") }
        model.refreshAgents()
        try await eventually("Queued count on session list") { model.agents.first?.queued == (outcome == .unrelatedUnknown ? 2 : 1) }
    case .notSent, .replyNotSent:
        guard first.status.canRetry, await transport.nativeCount == 0 else { throw CheckFailure("Not-sent classification") }
    case .rejected, .replyRejected:
        guard case .rejected = first.status, !first.status.canRetry, await transport.nativeCount == 0 else { throw CheckFailure("Rejection classification") }
    default:
        guard case .unknown = first.status, !first.status.canRetry, !first.status.isKnownSuccess else { throw CheckFailure("Unknown became success/retry") }
    }
    if outcome == .staleQueuedReceipt {
        // The automatic post-receipt refresh may already have replaced the
        // stale snapshot. Check the actual row projection with that old item.
        let item = try JSONDecoder().decode(ArgoQueuedMessage.self, from: Data(#"{"id":"fixture-item"}"#.utf8))
        guard state.deliveryUnknown(for: item)?.contains("synthetic acknowledgement lost") == true else {
            throw CheckFailure("Stale receipt removed the queue row's unknown presentation")
        }
    }
    // Calls through the real UI action boundary, including a programmatic attempt
    // to retry statuses for which the view hides its Retry Sending button.
    model.retry(first)
    if [.notSent, .replyNotSent].contains(outcome) {
        try await eventually("Explicit safe retry") { state.deliveries.last?.status.isKnownSuccess == true }
        let requests = await transport.requests
        guard requests.count == 2, requests[0].body == requests[1].body,
              requests[0].headers.first(where: { $0.0 == "X-Loom-Attempt" })?.1 == requests[1].headers.first(where: { $0.0 == "X-Loom-Attempt" })?.1,
              state.deliveries.count == 1 else { throw CheckFailure("Retry changed body/attempt or created another receipt") }
    } else {
        try await Task.sleep(for: .milliseconds(20))
        guard await transport.requests.count == 1 else { throw CheckFailure("Unsafe retry submitted another POST") }
    }
    if [.lateResult, .lateUnknown].contains(outcome) {
        guard model.conversation?.key.run == "r2", model.conversation?.deliveries.isEmpty == true,
              model.conversation?.transcript.items.isEmpty == true, model.conversation?.draft == "keep second draft" else { throw CheckFailure("Late result crossed conversation ownership") }
        model.selectSession(key)
        model.showConversation(key, visible: true)
    }
    if outcome == .queued { await transport.deliverQueued() }
    if outcome == .queuedThenUnknown { await transport.markQueueUnknown() }
    model.refreshConversation()
    let expected = [.held, .rejected, .replyRejected, .unrelatedUnknown].contains(outcome) ? 0 : 1
    try await eventually("Native readback count") { state.transcript.items.count == expected && !state.loading }
    guard await transport.nativeCount == expected, state.transcript.items.allSatisfy({ $0.role == "user" && $0.text == text }),
          state.transcript.identity?.session == "native-r1" else { throw CheckFailure("Native text/identity/count mismatch") }
    if let ask, [.replyUnknown, .replyWrongID].contains(outcome) {
        guard !state.canReply(to: ask), !state.hasAnswered(ask) else { throw CheckFailure("Unknown reply unlocked question or marked it answered") }
    }
    if [.serverUnknown, .lostReceipt, .cancelledAfterWrite, .malformed, .replyUnknown, .replyWrongID].contains(outcome) {
        guard case .unknown = state.deliveries.last!.status else { throw CheckFailure("Matching transcript guessed a receipt") }
    }
    if [.nativeUnknown, .ptyUnknown, .queuedThenUnknown, .lateUnknown, .backgroundUnknown, .staleQueuedReceipt].contains(outcome) {
        try await eventually("Typed queue unknown updates original receipt") {
            if case .unknown(let reason) = state.deliveries.last?.status { return reason.contains("synthetic acknowledgement lost") }
            return false
        }
        guard state.draft.isEmpty, state.deliveries.last?.queueItemID == "fixture-item",
              state.deliveries.last?.operation.attempt == first.operation.attempt else { throw CheckFailure("Unknown recreated draft or changed attempt") }
        model.retry(first) // stale UI snapshot must not authorize a repeat.
        model.sendDraft(for: key) // no recovery code may rebuild an ordinary-send draft.
        try await Task.sleep(for: .milliseconds(20))
        guard await transport.requests.count == 1 else { throw CheckFailure("Unknown generated another ordinary send") }
        try await eventually("Fresh server unknown snapshot") { state.queue?.items.first?.deliveryUnknown.isEmpty == false }
        if let queue = state.queue {
            let restored = ConversationState(key: key)
            restored.queue = queue
            guard let item = restored.queue?.items.first,
                  restored.deliveryUnknown(for: item)?.contains("synthetic acknowledgement lost") == true else {
                throw CheckFailure("Server unknown not visible without in-memory phone receipts")
            }
        }
        // Explicit server removal is not a delivery acknowledgement.
        await transport.removeQueueRecord()
        model.refreshConversation()
        try await eventually("Retained queue record removed") { state.queue?.items.isEmpty == true }
        guard case .unknown = state.deliveries.last?.status else { throw CheckFailure("Queue removal guessed delivery success") }
    }
    if outcome == .unrelatedUnknown {
        guard case .queued = state.deliveries.last?.status else { throw CheckFailure("Same-text other item contaminated receipt") }
    }
    print("PASS \(outcome.rawValue): original text, target, native-count=\(expected), writes=\(await transport.requests.count)")
}

@main private struct MobileDeliveryCheck {
    @MainActor static func main() async {
        var failures = 0
        for outcome in Outcome.allCases {
            do { try await check(outcome) }
            catch { failures += 1; print("FAIL \(outcome.rawValue): \(error)") }
        }
        print("Mobile delivery: \(Outcome.allCases.count - failures)/\(Outcome.allCases.count) passed")
        if failures > 0 { exit(1) }
    }
}
