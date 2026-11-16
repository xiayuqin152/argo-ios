import ArgoMobileKit
import Foundation
import Glibc

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private enum Scenario: String, CaseIterable, Sendable {
    case accepted, unknown, future, queuedToAccepted, queuedToUnknown
    case getBeforePost, acceptedBeforeUnknownPost, staleUnknownGET, futureAfterAccepted
    case background, lateSession, changedThread, restore, mixed
    case hide, hideFailure, hideLostACK, hideBeforePost, hideLateSession
    case unboundUnknownRemoved, unboundAcceptedRemoved, unboundACKRemoved, unboundOldUnknownRemoved

    var removesBeforeBinding: Bool {
        switch self {
        case .unboundUnknownRemoved, .unboundAcceptedRemoved, .unboundACKRemoved, .unboundOldUnknownRemoved: true
        default: false
        }
    }
}

// The transport is the external boundary. No product delivery/queue algorithm
// is replicated; all state transitions below run in the actual production model.
private actor NativeTransport: ArgoHTTPTransport {
    let scenario: Scenario
    let text = "SYNTHETIC_NATIVE_HANDOFF\n  原文🙂  \n" + String(repeating: "完整正文 ", count: 500)
    private(set) var posts: [HTTPRequest] = []
    private(set) var deletes: [HTTPRequest] = []
    private(set) var queueReads = 0
    private var published = false
    private var hidden = false
    private var nativeState: String?
    private var currentThread = "native-r1"
    private var transcriptWritten = false
    private var postWaiter: CheckedContinuation<HTTPResponse, Never>?
    private var postResponse: HTTPResponse?
    private var hideWaiter: CheckedContinuation<HTTPResponse, Never>?
    var waitingForPost: Bool { postWaiter != nil }
    var waitingForHide: Bool { hideWaiter != nil }

    init(_ scenario: Scenario) {
        self.scenario = scenario
        switch scenario {
        case .queuedToAccepted, .queuedToUnknown, .getBeforePost, .unboundUnknownRemoved, .unboundAcceptedRemoved: nativeState = nil
        case .unknown, .acceptedBeforeUnknownPost, .unboundOldUnknownRemoved: nativeState = "unknown"
        case .future: nativeState = "v2-unrecognized"
        default: nativeState = "accepted"
        }
    }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async {}
    func updateNative(_ state: String) { nativeState = state }
    func removeQueueRecord() { hidden = true }
    func changeThread() { currentThread = "native-r1-new" }
    func writeTranscript() { transcriptWritten = true }
    func releasePost() { if let postResponse { postWaiter?.resume(returning: postResponse) }; postWaiter = nil }
    func releaseHide() { hideWaiter?.resume(returning: HTTPResponse(status: 204, headers: [], body: Data(), reusable: false)); hideWaiter = nil }

    private var target: [String: Any] { ["run": "r1", "engine": "codex", "session": "native-r1"] }
    private func item() -> [String: Any] {
        var item: [String: Any] = ["id": "native-item", "text": text, "source": "ios", "created": "2026-11-16T04:14:00Z", "target": target]
        if let nativeState { item["native"] = ["state": nativeState, "note": "synthetic native handoff note"] }
        return item
    }
    private var pendingCount: Int { (published && !hidden && nativeState == nil ? 1 : 0) + (scenario == .mixed && published ? 1 : 0) }
    private var historyCount: Int { published && !hidden && nativeState != nil ? 1 : 0 }
    private func queue(_ run: String) -> [String: Any] {
        var items: [[String: Any]] = run == "r1" && published && !hidden ? [item()] : []
        if run == "r1", scenario == .mixed, published {
            items.append(["id": "different-item", "text": text, "target": target])
        }
        return ["run": run, "state": "working", "hold": "", "items": items,
                "pending": run == "r1" ? pendingCount : 0, "nativeHistory": run == "r1" ? historyCount : 0]
    }
    private func json(_ object: Any, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")],
                     body: try JSONSerialization.data(withJSONObject: object), reusable: true)
    }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        let url = URLComponents(string: "http://fixture.invalid" + request.target)!
        let path = url.path
        if request.method == "POST" {
            posts.append(request)
            guard path == "/api/agents/r1/queue", !reuse else { throw Failure("wrong/replayed POST") }
            let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            let sentTarget = body["target"] as! [String: Any]
            guard body["text"] as? String == text, body["source"] as? String == "ios", body["when"] as? String == "auto",
                  sentTarget["run"] as? String == "r1", sentTarget["session"] as? String == "native-r1",
                  request.headers.contains(where: { $0.0 == "X-Loom-Attempt" && ArgoAttempt.valid($0.1) }) else { throw Failure("original text/target/attempt changed") }
            published = true
            let response = try json(["delivered": false, "item": item(), "queue": queue("r1")])
            if scenario.removesBeforeBinding || [.getBeforePost, .acceptedBeforeUnknownPost, .background, .lateSession, .hideBeforePost].contains(scenario) {
                postResponse = response
                return await withCheckedContinuation { postWaiter = $0 }
            }
            return response
        }
        if request.method == "DELETE" {
            deletes.append(request)
            guard path == "/api/agents/r1/queue/native-item/native", !reuse, request.body == nil,
                  !request.headers.contains(where: { $0.0 == "X-Loom-Attempt" }) else { throw Failure("hide became an input/ordinary queue mutation") }
            if scenario == .hideFailure { return try json(["error": "synthetic hide rejected"], status: 409) }
            hidden = true
            if scenario == .hideLostACK { throw TransportFailure.noReply("synthetic hide ACK lost") }
            if scenario == .hideLateSession { return await withCheckedContinuation { hideWaiter = $0 } }
            return HTTPResponse(status: 204, headers: [], body: Data(), reusable: false)
        }
        if path == "/api/health" { return try json(["api": 1, "version": "fixture"]) }
        if path == "/api/projects" || path == "/api/agents/profiles" { return try json([]) }
        if path == "/api/workspaces" { return try json([["id": "w1"]]) }
        if path == "/api/agents" {
            return try json((1...2).map { n in ["run": "r\(n)", "terminal": "t\(n)", "ws": "w1", "engine": "codex", "status": "active", "state": "working", "queued": n == 1 ? pendingCount : 0, "nativeHistory": n == 1 ? historyCount : 0] as [String: Any] })
        }
        if path == "/api/terminals" {
            return try json((1...2).map { n in ["id": "t\(n)", "ws": "w1", "alive": true, "agent": ["run": "r\(n)", "engine": "codex"]] as [String: Any] })
        }
        if path.hasSuffix("/chat") {
            let run = path.contains("/t1/") ? "r1" : "r2"
            let thread = run == "r1" ? currentThread : "native-r2"
            if let requested = url.queryItems?.first(where: { $0.name == "session" })?.value, requested != thread {
                return try json(["error": "session changed"], status: 409)
            }
            let after = url.queryItems?.first(where: { $0.name == "after" })?.value ?? "0:0"
            let start = Int(after.split(separator: ":")[0])!
            let size = transcriptWritten && thread == "native-r1" ? 100 : 0
            let items: [[String: Any]] = size == 100 && start == 0 ? [["id": "canonical-user-record", "cursor": "0:0", "offset": 0, "role": "user", "type": "message", "text": text]] : []
            return try json(["bounded": true, "byteLimit": 1_048_576, "identity": ["run": run, "engine": "codex", "session": thread],
                             "items": items, "start": after, "end": "\(size):0", "size": size, "older": false, "newer": false])
        }
        if path.hasSuffix("/queue") { queueReads += 1; return try json(queue(String(path.split(separator: "/")[2]))) }
        if path == "/api/agents/r1" || path == "/api/agents/r2" { return try json(["run": String(path.split(separator: "/").last!), "asks": []]) }
        throw Failure("unexpected request: \(request.method) \(request.target)")
    }
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}
@MainActor private func eventually(_ message: String, _ predicate: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < end {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Failure(message)
}
@MainActor private func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }

@MainActor private func check(_ scenario: Scenario) async throws {
    let directory = URL(fileURLWithPath: "research/native-handoff-wire-v1/fixtures/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
        GatewayCredential(device: "fixture-device", token: String(repeating: "b", count: 43))
    }
    let host = try await store.pair(code: "argo1:fixture.invalid:6779:\(Base64URL.encode(Data(repeating: 1, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))", deviceName: "fixture")
    let transport = NativeTransport(scenario)
    let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in ArgoConnection(host: host, transport: transport) }
    defer { model.setActive(false) }
    await model.loadHosts()
    model.setActive(true)
    try await eventually("agent list loaded") { model.agents.count == 2 }
    let key = SessionKey(host: host.id, workspace: "w1", run: "r1", terminal: "t1")
    let other = SessionKey(host: host.id, workspace: "w1", run: "r2", terminal: "t2")
    model.selectSession(key); model.showConversation(key, visible: true)
    try await eventually("original identity loaded") { model.conversation?.canSendToIdentity == true && model.conversation?.queue != nil }
    let state = model.conversation!
    state.draft = transport.text
    model.sendDraft(for: key)

    if scenario.removesBeforeBinding {
        try await eventually("unbound POST pending") { await transport.waitingForPost }
        await transport.updateNative([.unboundUnknownRemoved, .unboundACKRemoved].contains(scenario) ? "unknown" : "accepted")
        model.refreshConversation()
        try await eventually("native GET before binding") { state.nativeQueueItems.count == 1 }
        try expect(state.deliveries.first?.queueItemID == nil, "fixture bound item ID too early")
        let originalItem = state.nativeQueueItems[0]
        await transport.removeQueueRecord()
        model.refreshConversation()
        try await eventually("removed before binding") { state.queue?.items.isEmpty == true }
        await transport.releasePost()
        try await eventually("unbound POST finished") { state.deliveries.first?.status != .sending }
        model.refreshConversation()
        try await eventually("removed after binding") { state.queue?.items.isEmpty == true }
        let receipt = state.deliveries[0]
        guard case .native(let native) = receipt.status else { throw Failure("native evidence erased before binding") }
        try expect(native.state == (scenario == .unboundUnknownRemoved ? .unknown : .accepted), "removed native evidence lost ACK precedence")
        try expect(!receipt.status.canRetry && !receipt.status.isKnownSuccess && receipt.queueItemID == originalItem.id, "removed native evidence became sendable/success or changed ID")
        let post = await transport.posts[0]
        try expect(post.headers.first(where: { $0.0 == "X-Loom-Attempt" })?.1 == receipt.operation.attempt && receipt.id == receipt.operation.attempt, "removed native evidence changed attempt")
        if case .message(let original) = receipt.operation {
            try expect(original.target == originalItem.target && original.text == originalItem.text, "removed native evidence changed original text/target")
        }
        try expect(state.transcript.items.isEmpty && state.deliveryReceipts.count == 1 && state.pendingQueueCount == 0, "removed evidence projected another message or queued count")
        model.retry(receipt)
        try await Task.sleep(for: .milliseconds(20))
        try expect(await transport.posts.count == 1, "removed native evidence caused another POST")
        print("PASS \(scenario.rawValue): GET native, GET empty, late POST, one original receipt/write")
        return
    }

    if [.getBeforePost, .acceptedBeforeUnknownPost, .background, .lateSession, .hideBeforePost].contains(scenario) {
        try await eventually("POST pending") { await transport.waitingForPost }
        if [.getBeforePost, .acceptedBeforeUnknownPost, .hideBeforePost].contains(scenario) {
            await transport.updateNative("accepted")
            model.refreshConversation()
            try await eventually("GET native precedes POST") { state.nativeQueueItems.count == 1 }
        }
        if scenario == .background { model.setActive(false) }
        if scenario == .lateSession {
            model.selectSession(other); model.showConversation(other, visible: true)
            try await eventually("other session") { model.conversation?.transcript.identity?.session == "native-r2" }
            model.conversation?.draft = "keep other draft"
        }
        if scenario == .hideBeforePost {
            let item = state.nativeQueueItems[0]
            model.hideNativeHandoff(item, for: key)
            try await eventually("hidden before POST receipt") { state.nativeQueueItems.isEmpty && state.hidingNativeIDs.isEmpty }
        }
        await transport.releasePost()
        if scenario == .background {
            try await eventually("suspended receipt") { state.deliveries.first?.status != .sending }
            model.setActive(true)
            try await eventually("reconnected") { model.status.isConnected }
        }
    }
    try await eventually("POST finished") { !state.deliveries.contains(where: { $0.status == .sending }) }
    if scenario == .hideBeforePost {
        try expect(state.deliveries.isEmpty && state.nativeQueueItems.isEmpty, "late receipt restored hidden record")
        let postCount = await transport.posts.count
        let deleteCount = await transport.deletes.count
        try expect(postCount == 1 && deleteCount == 1, "hidden late receipt resent input")
        print("PASS \(scenario.rawValue)"); return
    }
    if scenario == .lateSession {
        try expect(model.conversation?.key == other && model.conversation?.draft == "keep other draft" && model.conversation?.deliveries.isEmpty == true && model.conversation?.nativeQueueItems.isEmpty == true, "late native receipt crossed SessionKey")
        model.selectSession(key); model.showConversation(key, visible: true)
    }
    if [.queuedToAccepted, .queuedToUnknown].contains(scenario) {
        try expect(state.deliveries.first?.queueItemID == "native-item", "ordinary receipt lost ID")
        await transport.updateNative(scenario == .queuedToAccepted ? "accepted" : "unknown")
        model.refreshConversation()
    }
    let expected: ArgoNativeHandoff.State = [.unknown, .future, .queuedToUnknown].contains(scenario) ? .unknown : .accepted
    try await eventually("one typed handoff receipt") {
        guard case .native(let native) = state.deliveries.first?.status else { return false }
        return native.state == expected && state.nativeQueueItems.count == 1
    }
    let receipt = state.deliveries[0]
    try expect(!receipt.status.canRetry && !receipt.status.isKnownSuccess && receipt.operation.text == transport.text, "native receipt exposed retry/success or changed body")
    let originalPost = await transport.posts[0]
    try expect(receipt.id == receipt.operation.attempt && originalPost.headers.first(where: { $0.0 == "X-Loom-Attempt" })?.1 == receipt.operation.attempt, "receipt replaced the original attempt")
    if case .message(let original) = receipt.operation {
        try expect(original.target == state.nativeQueueItems[0].target, "handoff changed the captured destination")
    }
    try expect(state.transcript.items.isEmpty && state.deliveryReceipts.isEmpty, "handoff duplicated native chat or its status row")
    try expect(state.nativeQueueItems[0].target?.session == "native-r1" && state.nativeQueueItems[0].text == transport.text, "original body/identity lost")
    try expect(state.pendingQueueCount == (scenario == .mixed ? 1 : 0) && state.nativeHistoryCount == 1, "native history counted as pending")
    if scenario == .mixed { try expect(state.ordinaryQueueItems.first?.id == "different-item", "same-text ordinary item joined native record") }
    model.refreshAgents()
    try await eventually("native-only list badge") { model.agents.first?.nativeHistory == 1 && model.agents.first?.queued == (scenario == .mixed ? 1 : 0) }
    model.retry(receipt); model.sendDraft(for: key)
    try await Task.sleep(for: .milliseconds(20))
    try expect(await transport.posts.count == 1, "native state generated another POST")

    if [.staleUnknownGET, .futureAfterAccepted].contains(scenario) {
        await transport.updateNative(scenario == .staleUnknownGET ? "unknown" : "future-v2")
        model.refreshConversation()
        try await eventually("changed wire snapshot consumed") { state.queue?.items.first?.native?.state == .unknown }
        guard case .native(let native) = state.deliveries[0].status else { throw Failure("lost typed native") }
        try expect(native.state == (scenario == .staleUnknownGET ? .accepted : .unknown), "wrong stale/future status precedence")
    }
    if scenario == .changedThread {
        await transport.changeThread()
        model.refreshConversation()
        try await eventually("new native thread") { state.transcript.identity?.session == "native-r1-new" && state.nativeQueueItems.count == 1 }
        try expect(state.nativeQueueItems[0].target?.session == "native-r1" && state.transcript.items.isEmpty, "old handoff became a new-thread message")
    } else {
        await transport.writeTranscript()
        model.refreshConversation()
        try await eventually("canonical native readback") { state.transcript.items.count == 1 }
        try expect(state.transcript.items[0].text == transport.text, "native body changed")
        try expect(!state.deliveries[0].status.isKnownSuccess, "same text guessed completion")
    }
    if scenario == .restore {
        model.setActive(false)
        let restored = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in ArgoConnection(host: host, transport: transport) }
        defer { restored.setActive(false) }
        await restored.loadHosts(); restored.setActive(true)
        try await eventually("restored list") { restored.agents.count == 2 }
        restored.selectSession(key); restored.showConversation(key, visible: true)
        try await eventually("history without local receipts") { restored.conversation?.nativeQueueItems.count == 1 }
        try expect(restored.conversation?.deliveries.isEmpty == true && restored.conversation?.pendingQueueCount == 0, "restore requires local receipt or miscounts")
    }
    if [.hide, .hideFailure, .hideLostACK, .hideLateSession, .changedThread, .mixed].contains(scenario) {
        if scenario == .mixed {
            model.hideNativeHandoff(state.ordinaryQueueItems[0], for: key)
            try expect(await transport.deletes.isEmpty, "ordinary item used the native hide action")
        }
        let item = state.nativeQueueItems[0]
        model.hideNativeHandoff(item, for: key)
        model.hideNativeHandoff(item, for: key) // immediate double tap
        if scenario == .hideLateSession {
            try await eventually("DELETE pending") { await transport.waitingForHide }
            model.selectSession(other); model.showConversation(other, visible: true)
            try await eventually("other session during hide") { model.conversation?.transcript.identity?.session == "native-r2" }
            model.conversation?.draft = "keep hide destination"
            await transport.releaseHide()
        }
        try await eventually("hide completed") { state.hidingNativeIDs.isEmpty }
        if [.hideFailure, .hideLostACK].contains(scenario) {
            try expect(state.nativeHideProblem != nil && !state.deliveries.isEmpty, "hide failure swallowed or claimed success")
        } else {
            try expect(state.nativeQueueItems.isEmpty && state.deliveries.isEmpty && state.nativeHideProblem == nil, "hide did not remove only its status")
            try expect(state.transcript.items.count == (scenario == .changedThread ? 0 : 1), "hide retracted native transcript")
            if scenario == .mixed { try expect(state.ordinaryQueueItems.first?.id == "different-item", "native hide removed the ordinary same-text item") }
        }
        if scenario == .hideLateSession {
            try expect(model.conversation?.draft == "keep hide destination" && model.conversation?.deliveries.isEmpty == true, "late hide affected new session")
        }
        try expect(await transport.deletes.count == 1, "hide double tap repeated DELETE")
    }
    try expect(await transport.posts.count == 1, "recovery/hide resent input")
    print("PASS \(scenario.rawValue): original body/identity, one POST, no duplicate native projection")
}

@main private struct NativeHandoffCheck {
    @MainActor static func main() async {
        var failed = 0
        for scenario in Scenario.allCases {
            do { try await check(scenario) }
            catch { failed += 1; print("FAIL \(scenario.rawValue): \(error)") }
        }
        print("Native handoff: \(Scenario.allCases.count - failed)/\(Scenario.allCases.count) passed")
        if failed != 0 { exit(1) }
    }
}
