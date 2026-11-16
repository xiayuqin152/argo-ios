@testable import ArgoMobileKit
import Foundation
import Glibc

private struct Failure: Error { let reason: String }
private enum Scenario: String, CaseIterable, Sendable {
    case complete, text, sourceCopy, sourceView, unknownMarker, nativeAccepted, nativeUnknown, nativeFuture, scheduled
    case cachedAcceptedOldUnknown, cachedAcceptedOldOrdinary
    case missing, failed, transportFailed, wrongID, wrongRun, wrongWorkspace, wrongTarget, wrongIdentity, wrongState, wrongLater, wrongNative, wrongUpdated, wrongScheduleTime, wrongPasted, truncatedFull
    case closeLate, sessionLate, workspaceLate, hostLate, backgroundLate, threadLate, initialIdentityLate, rowLate, nativeLate, laterLate, refreshLate, replacementLate
    var delayed: Bool { rawValue.hasSuffix("Late") }
    var fails: Bool { [.missing, .failed, .transportFailed, .wrongID, .wrongRun, .wrongWorkspace, .wrongTarget, .wrongIdentity, .wrongState, .wrongLater, .wrongNative, .wrongUpdated, .wrongScheduleTime, .wrongPasted, .truncatedFull].contains(self) }
}

private actor QueueTransport: ArgoHTTPTransport {
    let scenario: Scenario
    let original = "  SYNTHETIC_FULL_QUEUE🙂\n\"\\<html>&\u{2028}\n" + String(repeating: "完整原文 ", count: 4000)
    private(set) var reads: [HTTPRequest] = []
    private(set) var writes: [HTTPRequest] = []
    private var thread = "original-thread"
    private var rowChanged = false
    private var changedNative = false
    private var changedLater = false
    private var stale = false
    private var waiter: CheckedContinuation<HTTPResponse, Never>?
    private var lateResponse: HTTPResponse?
    var waiting: Bool { waiter != nil }
    init(_ scenario: Scenario) { self.scenario = scenario }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async {}
    func release() { if let lateResponse { waiter?.resume(returning: lateResponse) }; waiter = nil; lateResponse = nil }
    func mutate() {
        if scenario == .threadLate { thread = "replacement-thread" }
        else if scenario == .nativeLate { changedNative = true }
        else if scenario == .laterLate { changedLater = true }
        else { rowChanged = true }
    }
    func useStalePreview() { stale = true }
    private func identity(_ run: String = "r1", original: Bool = false) -> [String: Any] {
        ["run": run, "engine": "codex", "session": run == "r1" ? (original ? "original-thread" : thread) : "other-thread",
         "pid": 0, "start": "", "started": "0001-01-01T00:00:00Z"]
    }
    private var isLater: Bool { scenario == .scheduled || changedLater }
    private func item(full: Bool, id: String = "q1") -> [String: Any] {
        let hasFullText = full || [.complete, .sourceCopy, .sourceView].contains(scenario)
        var value: [String: Any] = ["id": id, "text": hasFullText ? original : "  SYNTHETIC_FULL…", "submit": true,
            "source": full || ![.sourceCopy, .sourceView].contains(scenario) ? "ios" : "i…",
            "created": "2026-11-16T04:53:00Z", "target": identity(original: true),
            "updated": rowChanged ? "2026-11-16T04:54:00Z" : "2026-11-16T04:53:01Z"]
        if isLater || scenario == .wrongScheduleTime { value["not_before"] = "2026-11-17T00:00:00Z" }
        if !full, scenario != .complete {
            value["truncatedFields"] = [.sourceCopy, .sourceView].contains(scenario) ? ["source"] : scenario == .unknownMarker ? ["future.field"] : ["text"]
        }
        if [.nativeAccepted, .nativeUnknown, .nativeFuture, .wrongNative, .nativeLate].contains(scenario) {
            let state = scenario == .nativeFuture ? "future-native" : scenario == .nativeUnknown || changedNative ? "unknown" : "accepted"
            value["native"] = ["state": state, "note": "synthetic native note"]
        }
        if [.cachedAcceptedOldUnknown, .cachedAcceptedOldOrdinary].contains(scenario) {
            if full || !stale { value["native"] = ["state": "accepted", "note": "synthetic accepted"] }
            else if scenario == .cachedAcceptedOldUnknown { value["native"] = ["state": "unknown", "note": "synthetic earlier unknown"] }
        }
        return value
    }
    private func queue(_ run: String) -> [String: Any] {
        let rows = run == "r1" ? (scenario == .replacementLate ? [item(full: false), item(full: false, id: "q2")] : [item(full: false)]) : []
        return ["bounded": true, "byteLimit": 8_388_608, "run": run, "ws": "w1", "identity": identity(run),
                "state": "working", "ended": false, "hold": "", "items": isLater ? [] : rows, "later": isLater ? rows : [],
                "pending": run == "r1" ? 1 : 0, "nativeHistory": item(full: false)["native"] == nil ? 0 : 1]
    }
    private func json(_ value: Any, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [], body: try JSONSerialization.data(withJSONObject: value), reusable: true)
    }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        if request.method != "GET" { writes.append(request); throw Failure(reason: "Full read attempted a write") }
        let url = URLComponents(string: "http://fixture.invalid" + request.target)!
        let path = url.path
        if path == "/api/agents/r1/queue/q1" || path == "/api/agents/r1/queue/q2" {
            reads.append(request)
            guard url.queryItems == nil, request.body == nil, !request.headers.contains(where: { $0.0 == "X-Loom-Attempt" }) else { throw Failure(reason: "full GET carries a query/body/attempt") }
            if scenario == .missing || scenario == .failed { return try json(["error": "synthetic full read error"], status: scenario == .missing ? 404 : 500) }
            if scenario == .transportFailed { throw TransportFailure.noReply("synthetic read lost") }
            var full = item(full: true, id: path.hasSuffix("q2") ? "q2" : "q1")
            var envelope: [String: Any] = ["run": "r1", "ws": "w1", "identity": identity(), "state": "working", "ended": false, "later": isLater]
            switch scenario {
            case .wrongID: full["id"] = "different"
            case .wrongRun: envelope["run"] = "r2"
            case .wrongWorkspace: envelope["ws"] = "w2"
            case .wrongTarget: full["target"] = identity("r2")
            case .wrongIdentity: envelope["identity"] = identity("r2")
            case .wrongState: envelope["state"] = "idle"
            case .wrongLater: envelope["later"] = true
            case .wrongNative: full["native"] = ["state": "unknown", "note": "changed"]
            case .wrongUpdated: full["updated"] = "2026-11-16T04:54:00Z"
            case .wrongScheduleTime: full["not_before"] = "2026-11-18T00:00:00Z"
            case .wrongPasted: full["pasted"] = ["at": "2026-11-16T05:30:00Z"]
            case .truncatedFull: full["truncatedFields"] = ["future.field"]
            default: break
            }
            envelope["item"] = full
            let response = try json(envelope)
            if scenario.delayed, path.hasSuffix("q1") {
                lateResponse = response
                return await withCheckedContinuation { waiter = $0 }
            }
            return response
        }
        if path.hasSuffix("/queue") {
            guard url.queryItems == [URLQueryItem(name: "bounded", value: "1")] else { throw Failure(reason: "queue GET missing/excess bounded query") }
            return try json(queue(String(path.split(separator: "/")[2])))
        }
        if path == "/api/health" { return try json(["api": 1, "version": "synthetic"]) }
        if path == "/api/projects" || path == "/api/agents/profiles" { return try json([]) }
        if path == "/api/workspaces" { return try json([["id": "w1"], ["id": "w2"]]) }
        if path == "/api/agents" { return try json((1...2).map { ["run": "r\($0)", "terminal": "t\($0)", "ws": "w1", "state": "working", "status": "active", "engine": "codex"] }) }
        if path == "/api/terminals" { return try json((1...2).map { ["id": "t\($0)", "ws": "w1", "alive": true, "agent": ["run": "r\($0)", "engine": "codex"]] as [String: Any] }) }
        if path.hasSuffix("/chat") {
            let run = path.contains("/t1/") ? "r1" : "r2"
            return try json(["bounded": true, "byteLimit": 1_048_576, "identity": identity(run), "items": [], "start": "0:0", "end": "0:0", "size": 0, "older": false, "newer": false])
        }
        if path == "/api/agents/r1" || path == "/api/agents/r2" { return try json(["run": String(path.split(separator: "/").last!), "asks": []]) }
        throw Failure(reason: "unexpected read \(path)")
    }
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}
@MainActor private func eventually(_ label: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Failure(reason: label)
}
@MainActor private func require(_ value: Bool, _ label: String) throws { if !value { throw Failure(reason: label) } }

@MainActor private func check(_ scenario: Scenario) async throws {
    let directory = URL(fileURLWithPath: "research/queue-wire-v2/fixtures/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
        GatewayCredential(device: "fixture-device", token: String(repeating: "b", count: 43))
    }
    let host = try await store.pair(code: "argo1:fixture.invalid:6779:\(Base64URL.encode(Data(repeating: 1, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))", deviceName: "fixture")
    let transport = QueueTransport(scenario)
    let connection = ArgoConnection(host: host, transport: transport)
    let model = AppModel(store: store, pendingCreations: MemoryCreations()) { _, _ in connection }
    defer { model.setActive(false) }
    await model.loadHosts(); model.setActive(true)
    try await eventually("agents") { model.agents.count == 2 }
    let key = SessionKey(host: host.id, workspace: "w1", run: "r1", terminal: "t1")
    model.selectSession(key); model.showConversation(key, visible: true)
    try await eventually("queue and identity") { model.conversation?.queue != nil && model.conversation?.transcript.identity != nil }
    let state = model.conversation!
    if [.cachedAcceptedOldUnknown, .cachedAcceptedOldOrdinary].contains(scenario) {
        await transport.useStalePreview()
        state.queue = try await connection.queue(run: "r1")
        try require(state.nativeQueueItems.first?.native?.state == .accepted, "stale preview erased accepted evidence")
    }
    let originalRow = (state.nativeQueueItems + state.ordinaryQueueItems)[0]
    if scenario == .initialIdentityLate { state.transcript.reset() }
    model.openQueueItem(originalRow, for: key, copy: scenario != .sourceView)
    guard let read = state.queueItemRead else { throw Failure(reason: "read presentation did not open") }
    if scenario.delayed {
        try await eventually("full read pending") { await transport.waiting }
        switch scenario {
        case .closeLate: model.closeQueueItem(read)
        case .sessionLate: model.selectSession(SessionKey(host: host.id, workspace: "w1", run: "r2", terminal: "t2"))
        case .workspaceLate: model.selectWorkspace("w2")
        case .hostLate: model.selectHost(nil)
        case .backgroundLate: model.setActive(false)
        case .refreshLate: model.refreshConversation()
        case .initialIdentityLate:
            let page = try await connection.chat(terminal: key.terminal, cursor: .latest)
            _ = state.transcript.apply(page, cursor: .latest)
        case .replacementLate:
            model.openQueueItem(state.ordinaryQueueItems.first(where: { $0.id == "q2" })!, for: key, copy: true)
            try await eventually("replacement full item") { state.queueItemRead?.item?.id == "q2" }
        default:
            await transport.mutate()
            state.queue = try await connection.queue(run: "r1")
        }
        await transport.release()
        try await eventually("late read completed") { read.task == nil }
        try require(read.item == nil && model.queueItemText(read) == nil, "late response applied to a closed/replaced owner")
        if scenario == .replacementLate {
            try require(state.queueItemRead?.item?.id == "q2", "old completion overwrote replacement item")
        } else { try require(state.queueItemRead == nil, "stale read left a stuck loading presentation") }
    } else {
        try await eventually("full read terminal state") { read.item != nil || read.problem != nil }
        if scenario.fails {
            try require(read.problem != nil && read.item == nil && model.queueItemText(read) == nil, "failed/mismatched full response exposed preview text")
            try require(state.allQueueItems.first?.id == originalRow.id, "failed read removed original row")
        } else {
            try require(read.item?.text == transport.original && model.queueItemText(read) == transport.original, "copy/view lost original bytes")
            try require(read.item?.target == originalRow.target && read.source.id == originalRow.id, "full text rebound item/target")
            let reads = await transport.reads.count
            try require(reads == ([.complete, .sourceCopy, .sourceView].contains(scenario) ? 0 : 1), "untruncated field fetched or truncated field skipped fetch")
        }
    }
    try require(await transport.writes.isEmpty && state.transcript.items.isEmpty && state.deliveries.isEmpty, "read created an input/receipt/native chat projection")
    print("PASS \(scenario.rawValue): original text/identity or explicit read error; writes=0")
}

@MainActor private func checkReceiptPreviews() throws {
    func decode<T: Decodable>(_ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    var checked = 0
    for kind in ["ordinary", "accepted", "unknown", "future-native"] {
        for getFirst in [false, true] {
            let key = SessionKey(host: UUID(), workspace: "w1", run: "r1", terminal: "t1")
            let state = ConversationState(key: key)
            let original = "SYNTHETIC_ORIGINAL_RECEIPT\n  完整原文🙂  "
            let message = ArgoOutgoingMessage(run: key.run, text: original, target: nil)
            state.append(PendingDelivery(id: message.attempt, operation: .message(message)))
            var row: [String: Any] = ["id": "q1", "text": "SYNTHETIC…"]
            let markers = ["text", kind == "ordinary" ? "deliveryUnknown" : "native.note"]
            row["truncatedFields"] = markers
            if kind == "ordinary" { row["deliveryUnknown"] = "partial…" }
            else { row["native"] = ["state": kind, "note": "partial…"] }
            let item: ArgoQueuedMessage = try decode(row)
            let empty: ArgoQueue = try decode(["run": key.run, "items": []])
            if getFirst {
                state.queue = try decode(["run": key.run, "items": [row]])
                state.queue = empty
            }
            let ordinary: ArgoQueuedMessage = try decode(["id": "q1", "text": original])
            let receipt = ArgoSendReceipt(run: key.run, attempt: message.attempt, delivered: false,
                queued: getFirst ? ordinary : item, queue: empty, pasted: false, note: "partial…", duplicate: false,
                truncatedFields: ["note"])
            state.record(receipt, for: message.attempt)
            let delivery = state.deliveryReceipts[0]
            try require(delivery.receiptTruncatedFields == ["note"] && delivery.receiptItemTruncatedFields == markers,
                        "receipt lost per-object preview evidence after queue removal/binding")
            try require(delivery.operation.text == original && delivery.operation.attempt == message.attempt &&
                        !delivery.status.canRetry && !delivery.status.isKnownSuccess && state.transcript.items.isEmpty,
                        "preview changed original message/attempt or became success/retry/chat")
            checked += 1
        }
    }
    print("Receipt previews: \(checked)/\(checked) passed; original body/attempt and root/item markers retained")
}

@main private struct QueuePreviewCheck {
    @MainActor static func main() async {
        var failed = 0
        for scenario in Scenario.allCases {
            do { try await check(scenario) }
            catch { failed += 1; print("FAIL \(scenario.rawValue): \(error)") }
        }
        print("Queue preview model: \(Scenario.allCases.count - failed)/\(Scenario.allCases.count) passed")
        do { try checkReceiptPreviews() }
        catch { failed += 1; print("FAIL receipt previews: \(error)") }
        if failed > 0 { exit(1) }
    }
}
