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
    case delivered, queued, held, notSent, rejected, queueConflictUnknown, serverUnknown, lostReceipt, cancelledAfterWrite, malformed, lateResult
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
            if outcome == .rejected { return try json(["error": "synthetic access denied", "code": "denied"], status: 403) }
            // A matching native GET after a conflict is not a delivery receipt.
            if outcome == .queueConflictUnknown { native.append(text) }
            if [.queueConflictUnknown, .replyRejected].contains(outcome) { return try json(["error": "目标已变化，没有写入", "code": "target_changed"], status: 409) }
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
    if outcome == .composerNativeSwitch {
        try await checkComposerNativeOwner(model: model, state: state, transport: transport)
        return
    }
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
    if [.staleQueuedReceipt, .unboundUnknownRemoved].contains(outcome) {
        try await eventually("Await delayed queued receipt") { await transport.waiting }
        await transport.markQueueUnknown()
        let reads = await transport.queueReads
        model.refreshConversation()
        try await eventually("Queue refresh precedes receipt") { await transport.queueReads > reads && state.queue?.hold.contains("未知") == true }
        if outcome == .unboundUnknownRemoved {
            // The desktop can remove this item while its original queued POST
            // response is still in flight. Keep the GET evidence through that gap.
            guard state.deliveries.last?.queueItemID == nil,
                  state.queue?.items.first?.id == "fixture-item",
                  state.queue?.items.first?.deliveryUnknown == transport.unknownReason else { throw CheckFailure("Fixture did not observe unknown before ID binding") }
            await transport.removeQueueRecord()
            let nextRead = await transport.queueReads
            model.refreshConversation()
            try await eventually("Read removal before receipt") { await transport.queueReads > nextRead && state.queue?.items.isEmpty == true }
            // This request is actually held at the transport boundary. A cold
            // window must retain evidence until that attempt can bind its ID.
            state.releaseReloadableContent(inFlightDeliveryIDs: [state.deliveries.last!.id])
        }
        await transport.releaseLate()
    }
    try await eventually("Delivery finished") { state.deliveries.last?.status != .sending }
    guard let first = state.deliveries.last, first.operation.text == text else { throw CheckFailure("Operation text lost") }
    if outcome == .unboundUnknownRemoved {
        model.refreshConversation()
        try await eventually("Empty queue after late receipt") { state.queue?.items.isEmpty == true }
        guard let final = state.deliveries.last, final.id == first.id else { throw CheckFailure("Receipt ownership changed") }
        model.retry(final)
        try await Task.sleep(for: .milliseconds(20))
        guard await transport.requests.count == 1 else { throw CheckFailure("Unsafe retry generated POST") }
        print("OBSERVED unboundUnknownRemoved: status=\(final.status), boundID=\(final.queueItemID ?? "nil"), writes=\(await transport.requests.count), queueCount=\(state.queue?.items.count ?? -1)")
        guard case .unknown = final.status else { throw CheckFailure("observed_unknown_erased_after_id_binding") }
        print("PASS unboundUnknownRemoved: GET unknown, GET empty, late POST preserves warning")
        return
    }
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
    let queueReadsBeforeRefresh = await transport.queueReads
    model.refreshConversation()
    let expected = [.held, .rejected, .replyRejected, .unrelatedUnknown].contains(outcome) ? 0 : 1
    try await eventually("Native readback count") { state.transcript.items.count == expected && !state.loading }
    guard await transport.nativeCount == expected, state.transcript.items.allSatisfy({ $0.role == "user" && $0.text == text }),
          state.transcript.identity?.session == "native-r1" else { throw CheckFailure("Native text/identity/count mismatch") }
    if outcome == .queueConflictUnknown {
        try await eventually("Queue conflict read-only refresh") { await transport.queueReads > queueReadsBeforeRefresh }
        guard let refreshed = state.deliveries.last, refreshed.id == first.id,
              case .unknown(let reason) = refreshed.status, reason.contains("目标已变化，没有写入"),
              !refreshed.status.canRetry, !refreshed.status.isKnownSuccess,
              state.deliveries.count == 1, state.draft.isEmpty,
              case .message(let original) = first.operation, case .message(let retained) = refreshed.operation,
              retained.text == original.text, retained.target == original.target, retained.attempt == original.attempt,
              await transport.requests.count == 1 else { throw CheckFailure("Queue conflict refresh changed the unknown receipt or submitted another POST") }
        print("OBSERVED queueConflictUnknown: unknown retained after queue GET; original text/target/attempt, canRetry=false, writes=1")
    }
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
    if outcome == .lostReceipt {
        let original = state.deliveries.last!
        guard original.queueItemID == nil, case .unknown = original.status else {
            throw CheckFailure("Fixture did not terminate the request without an item ID")
        }
        var ids: [String] = []
        for generation in 1...8 {
            await transport.replaceUnknownBatch(generation)
            let reads = await transport.queueReads
            model.refreshConversation()
            try await eventually("Unrelated unknown batch") {
                await transport.queueReads > reads && state.queue?.items.first?.id == "unrelated-\(generation)-1"
            }
            ids += (1...20).map { "unrelated-\(generation)-\($0)" }
            state.releaseReloadableContent()
            for id in ids {
                let item = try JSONDecoder().decode(ArgoQueuedMessage.self, from: JSONSerialization.data(withJSONObject: ["id": id]))
                guard state.deliveryUnknown(for: item) == nil else {
                    throw CheckFailure("Terminal request retained unrelated evidence after cold cleanup")
                }
            }
        }
        guard state.deliveries.count == 1, let retained = state.deliveries.last,
              retained.id == original.id, retained.queueItemID == nil, retained.status == original.status,
              retained.operation.attempt == original.operation.attempt, retained.operation.text == text else {
            throw CheckFailure("Cold cleanup changed the original unknown receipt")
        }
        model.retry(retained)
        try await Task.sleep(for: .milliseconds(20))
        guard await transport.requests.count == 1 else { throw CheckFailure("Cold cleanup enabled a resend") }
        print("OBSERVED CE-1: 0/\(ids.count) unrelated evidence retained, original unknown/text/attempt unchanged, writes=1")
    }
    print("PASS \(outcome.rawValue): original text, target, native-count=\(expected), writes=\(await transport.requests.count)")
}


@MainActor private func checkComposerNativeOwner(model: AppModel, state: ConversationState, transport: DeliveryTransport) async throws {
    let key = state.key
    let original = transport.text
    state.draft = original
    let chat = ComposerChatProbe(state: state, model: model)
    chat.renewInputOwner()
    guard let old = chat.inputOwner else { throw CheckFailure("Missing initial composer owner") }
    let page = ComposerPageProbe(input: old, send: chat.sendAction(for: old))
    page.selection = NSRange(location: 4, length: 2)
    page.appear()
    page.finish()
    guard page.cursor == NSRange(location: 4, length: 2), page.selection == page.cursor, state.draft == original else {
        throw CheckFailure("Normal page completion changed draft/selection")
    }
    let prompt = ComposerPromptProbe(input: old, model: model, renew: { chat.renewInputOwner() })
    prompt.pagePresentation.setPresented(true, in: model, conversation: key)
    let cover = prompt.pagePresentation.owner
    let changeObserved = Mutex(false)
    withObservationTracking { _ = old.canCommit } onChange: { changeObserved.withLock { $0 = true } }
    TypedText.shown = original
    defer { TypedText.shown = nil }
    await transport.switchNative(to: "native-r1-next")
    model.showLatest()
    try await eventually("Native N2 applied") { state.transcript.identity?.session == "native-r1-next" && !state.loadingOlder }
    guard model.selectedKey == key, model.conversation === state,
          state.sessionNotice?.contains("Your draft is kept") == true, state.draft == original else {
        throw CheckFailure("Native transition did not retain state/key/draft/notice")
    }
    page.sendOnce()
    try await Task.sleep(for: .milliseconds(40))
    let writes = await transport.requests
    if !writes.isEmpty {
        let body = try JSONSerialization.jsonObject(with: writes[0].body!) as! [String: Any]
        let target = body["target"] as! [String: Any]
        print("OBSERVED COMPOSER_NATIVE_RETARGET: same-key=true same-state=true target=\(target["session"]!) original-text=\(body["text"] as? String == original) writes=\(writes.count) draft-consumed=\(state.draft.isEmpty)")
        throw CheckFailure("COMPOSER_NATIVE_RETARGET: N1 page sent its retained draft to N2")
    }

    guard !old.canCommit, !old.acceptsInput, state.draft == original, !page.submission.claimed,
          changeObserved.withLock({ $0 }) else {
        throw CheckFailure("Old owner accepted native target change or failed observation tracking")
    }
    old.text = "late native edit"
    old.commit("late IME commit")
    chat.sendAction(for: old)()
    let field = ComposerTextInput(original)
    field.selection = NSRange(location: 4, length: 2)
    field.acceptsInput = { old.acceptsInput }
    field.send = chat.sendAction(for: old)
    let coordinator = Coordinator(field)
    let native = ComposerTextView()
    native.text = "stale first responder"
    native.selectedRange = NSRange(location: 0, length: 0)
    native.acceptsInput = { old.acceptsInput }
    native.sendsOnReturn = true
    native.submit = { coordinator.submit($0) }
    coordinator.textViewDidChange(native)
    coordinator.textViewDidChangeSelection(native)
    coordinator.submit(native)
    native.insertText("\n")
    _ = native.textPasteConfigurationSupporting(native, performPasteOf: NSAttributedString(string: "\n"),
                                                to: UITextRange(0, 0))
    native.wantsFocus = true
    native.updateFocus()
    guard state.draft == original, field.text == original, field.selection == NSRange(location: 4, length: 2),
          !native.isFirstResponder, await transport.requests.isEmpty else {
        throw CheckFailure("Stale owner/native responder edited, changed selection or submitted")
    }
    // Identity returning before any UI revocation callback must not revive
    // the original owner: native-session generations remain distinct.
    await transport.switchNative(to: "native-r1")
    model.showLatest()
    try await eventually("N1 returned before UI revocation") {
        state.transcript.identity?.session == "native-r1" && !state.loadingOlder
    }
    old.commit("late callback after identity round trip")
    page.sendOnce()
    guard old.valid, !old.canCommit, state.draft == original, await transport.requests.isEmpty else {
        throw CheckFailure("Identity round trip revived the owner before UI revocation")
    }
    await transport.switchNative(to: "native-r1-next")
    model.showLatest()
    try await eventually("N2 restored before UI revocation") {
        state.transcript.identity?.session == "native-r1-next" && !state.loadingOlder
    }
    page.inputChanged(old.canCommit)
    prompt.inputRevoked()
    guard !old.valid, !page.focused, !prompt.focused, !prompt.pagePresentation.isPresented,
          prompt.pagePresentation.owner == cover, chat.inputOwner === old else {
        throw CheckFailure("Revocation did not close the page before renewal")
    }
    page.disappear()
    guard state.draft == original else { throw CheckFailure("Old page disappearance restored stale text") }
    prompt.pageDismissed()
    guard prompt.pagePresentation.owner == nil, !prompt.focused,
          let replacement = chat.inputOwner, replacement !== old, replacement.acceptsInput,
          state.sessionNotice?.contains("review the new conversation") == true else {
        throw CheckFailure("Real sheet dismissal did not release coverage and renew the current native owner")
    }
    // A revoked owner remains revoked even if its original identity returns.
    await transport.switchNative(to: "native-r1")
    model.showLatest()
    try await eventually("Original identity returned") { state.transcript.identity?.session == "native-r1" && !state.loadingOlder }
    old.commit("revived old callback")
    page.sendOnce()
    guard !old.canCommit, !replacement.canCommit, state.draft == original, await transport.requests.isEmpty else {
        throw CheckFailure("Old owner revived on native identity return")
    }
    let currentPrompt = ComposerPromptProbe(input: replacement, model: model, renew: { chat.renewInputOwner() })
    currentPrompt.inputRevoked()
    guard let current = chat.inputOwner, current !== replacement, current.acceptsInput else {
        throw CheckFailure("Shell-only native change did not renew its owner")
    }
    // Existing cancellation behavior: an unchanged destination restores focus
    // and preserves the selected UTF-16 range, without renewing its owner.
    let cancelled = ComposerPromptProbe(input: current, model: model, renew: { chat.renewInputOwner() })
    cancelled.focused = false
    cancelled.pagePresentation.setPresented(true, in: model, conversation: key)
    cancelled.pagePresentation.requestDismissal()
    cancelled.pageDismissed()
    guard cancelled.focused, chat.inputOwner === current, state.draft == original else {
        throw CheckFailure("Ordinary page cancellation changed owner/draft/focus")
    }
    // Background only rejects new input; the original lifecycle commit remains
    // available until the existing explicit invalidation runs.
    model.setActive(false)
    current.text = "inactive edit"
    current.commit(original)
    chat.renewInputOwner()
    guard !current.acceptsInput, current.canCommit, chat.inputOwner === current, state.draft == original else {
        throw CheckFailure("Background changed owner or discarded the lifecycle draft")
    }
    model.setActive(true)
    try await eventually("Foreground") { model.status.isConnected && current.acceptsInput }
    let nextKey = SessionKey(host: key.host, workspace: key.workspace, run: "r2", terminal: "t2")
    model.selectSession(nextKey)
    model.showConversation(nextKey, visible: true)
    try await eventually("Adjacent conversation") { model.conversation?.canSendToIdentity == true }
    current.text = "wrong key edit"
    current.commit("wrong key IME")
    chat.sendAction(for: current)()
    chat.renewInputOwner()
    guard !current.canCommit, chat.inputOwner === current, state.draft == original,
          model.conversation?.draft.isEmpty == true, await transport.requests.isEmpty else {
        throw CheckFailure("Old ChatView renewed or submitted across a key switch")
    }
    cancelled.inputRevoked()
    await transport.switchNative(to: "native-r1-next")
    model.selectSession(key)
    model.showConversation(key, visible: true)
    model.showLatest()
    try await eventually("Original key at N2 restored") {
        model.conversation === state && state.transcript.identity?.session == "native-r1-next" && !state.loadingOlder
    }
    chat.renewInputOwner()
    guard let fresh = chat.inputOwner, fresh !== current, fresh.acceptsInput, !current.valid else {
        throw CheckFailure("Returning to a key reused its revoked owner")
    }
    let newPage = ComposerPageProbe(input: fresh, send: chat.sendAction(for: fresh))
    newPage.sendOnce()
    newPage.sendOnce()
    try await eventually("New owner delivered once") { await transport.requests.count == 1 && !state.isSending }
    newPage.disappear()
    let sent = await transport.requests
    let body = try JSONSerialization.jsonObject(with: sent[0].body!) as! [String: Any]
    let target = body["target"] as! [String: Any]
    guard state.draft.isEmpty, newPage.submission.claimed, await transport.nativeCount == 1,
          target["session"] as? String == "native-r1-next", body["text"] as? String == original,
          !replacement.canCommit, !current.canCommit, !old.canCommit else {
        throw CheckFailure("New-owner single-send or old-page draft preservation changed")
    }
    print("PASS composerNativeSwitch: same-key/state native change observed; old page/IME/native responder/selection/paste writes=0; close-before-renew and notice retained; ordinary cancel/background/key switch preserved; fresh N2 owner sends once")

}

@main private struct MobileDeliveryCheck {
    @MainActor static func main() async {
        var failures = 0
        let outcomes: [Outcome] = CommandLine.arguments.contains("--composer-owner-only") ? [.composerNativeSwitch] : Outcome.allCases
        for outcome in outcomes {
            do { try await check(outcome) }
            catch { failures += 1; print("FAIL \(outcome.rawValue): \(error)") }
        }
        print("Mobile delivery: \(outcomes.count - failures)/\(outcomes.count) passed")
        if failures > 0 { exit(1) }
    }
}
