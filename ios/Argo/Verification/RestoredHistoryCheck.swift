import ArgoMobileKit
import Foundation
import Glibc

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
private let original = "  SYNTHETIC original body\n 原文🙂 \\ \"  "
private enum Scenario: String, CaseIterable {
    case basic, receipt, multiSource, legacy, missing, wrongWorkspace, wrongCurrentWorkspace, wrongRun, wrongIdentity, sourceIdentitySession, wrongSourceSession, noMatchingRows
    case fullRevision, fullWorkspace, fullIdentity, fullTarget, fullLater
    case sourceClose, sourceHost, sourceRun, sourceReconnect, sourceRepair, sourceRevoked, sourceRefresh, ownerIdentityChanged
    case fullClose, fullSheetClose, fullHost, fullRun, fullReconnect, hideDuplicate, hideClose, hideUnknown, cleanup
    case warningZero, warningPartial, warningRecovery, warningCard
    case ordinaryUnknown, ordinaryFullRevision, ordinaryFullOwner, ordinaryFullClose, ordinaryRepair, ordinaryCleanup
    case sourceFullIdentityDrift, ordinaryOldTarget
    case ordinaryRemove, ordinaryRemoveUnknown, ordinaryRemoveClose, ordinaryRemoveRepair
    case ordinaryRemoveWorkspace, ordinaryRemoveIdentity, ordinaryRemoveStillPresent

    var ordinaryRemoval: Bool { [.ordinaryRemove, .ordinaryRemoveUnknown, .ordinaryRemoveClose, .ordinaryRemoveRepair, .ordinaryRemoveWorkspace, .ordinaryRemoveIdentity, .ordinaryRemoveStillPresent].contains(self) }
    var ordinarySource: Bool { ordinaryRemoval || [.ordinaryUnknown, .ordinaryFullRevision, .ordinaryFullOwner, .ordinaryFullClose, .ordinaryRepair, .ordinaryCleanup, .ordinaryOldTarget].contains(self) }
    var sourceIdentityMoved: Bool { ordinaryRemoval || [.sourceIdentitySession, .sourceFullIdentityDrift, .ordinaryOldTarget].contains(self) }
    var sourceWarning: Bool { [.warningZero, .warningPartial, .warningRecovery].contains(self) }
}

// Synthetic external I/O. These fixtures execute the actual ArgoConnection,
// AppModel Task registration and ConversationState, not a second state machine.
private actor Network {
    let scenario: Scenario
    private var holdPath: String?
    private var held: HTTPResponse?
    private var waiter: CheckedContinuation<HTTPResponse, Never>?
    private var hidden = false
    private var posted = false
    private var revoked = false
    private var ownerSession = "native-shared"
    private var warningCleared = false
    private(set) var writes: [(String, String)] = []
    private(set) var sendAttempts: [String] = []
    private(set) var sourceGets = 0
    private(set) var cancelled = false
    var waiting: Bool { waiter != nil }
    init(_ scenario: Scenario) { self.scenario = scenario }
    func hold(_ path: String) { holdPath = path }
    func revoke() { revoked = true }
    func changeOwner() { ownerSession = "new-owner-native-session" }
    func clearWarning() { warningCleared = true }
    func release() { if let held { waiter?.resume(returning: held) }; waiter = nil; held = nil }
    private func identity(_ run: String, session: String = "native-shared") -> [String: Any] {
        ["run": run, "engine": scenario.ordinarySource ? "claude" : "codex", "session": session]
    }
    private func sources() -> [[String: Any]] {
        if revoked { return [] }
        if scenario.ordinarySource { return hidden ? [] : [["sourceRun": "r0", "target": identity("r0"), "nativeHistory": 1]] }
        if scenario.sourceWarning && !warningCleared {
            if scenario != .warningPartial { return [] }
            return [["sourceRun": "r0", "target": identity("r0"), "nativeHistory": 3]]
        }
        return [["sourceRun": "r0", "target": identity("r0", session: scenario == .wrongSourceSession ? "other-native" : "native-shared"), "nativeHistory": hidden ? 2 : 3],
                ["sourceRun": "r-old", "target": identity("r-old"), "nativeHistory": 1]]
    }
    private func row(_ run: String, id: String = "same", native: String? = "accepted", full: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["id": id, "text": full ? original : "short preview…", "source": "ios",
            "created": "2026-11-16T08:00:00Z", "updated": "2026-11-16T08:00:01Z", "submit": true,
            "target": identity(run)]
        if let native { row["native"] = ["state": native, "note": "synthetic handoff"] }
        if !full { row["truncatedFields"] = ["text"] }
        if native == nil && posted && ["r1", "r2"].contains(run) { row["deliveryUnknown"] = "synthetic unknown" }
        if scenario.ordinarySource && run == "r0" && id == "same" {
            row.removeValue(forKey: "native")
            row["deliveryUnknown"] = "synthetic PTY input may have arrived"
        }
        return row
    }
    private func queue(_ run: String) -> [String: Any] {
        let source = run == "r0" || run == "r-old"
        var items = source ? [row(run), row(run, id: "unknown", native: "unknown"), row(run, id: "ordinary", native: nil)] :
            [row(run, native: posted && scenario == .receipt ? "accepted" : nil), row(run, id: "current-native")]
        if source {
            var foreign = row(run, id: "foreign")
            foreign["target"] = identity(run, session: "other-native")
            items.append(foreign)
            if scenario == .noMatchingRows { items = [foreign] }
            if hidden { items.removeAll { $0["id"] as? String == "same" } }
        }
        var value: [String: Any] = ["bounded": true, "byteLimit": 8_388_608, "run": run, "ws": "w1", "identity": identity(run),
            "state": source ? "stopped" : "working", "ended": source, "hold": "", "items": items,
            "later": source && scenario != .noMatchingRows ? [row(run, id: "future", native: "future-host-state")] : [],
            "pending": source ? 1 : (posted && scenario == .receipt ? 0 : 1), "nativeHistory": source ? (hidden ? 3 : 4) : (scenario == .legacy ? 1 : (posted && scenario == .receipt ? 6 : 5) - (hidden ? 1 : 0))]
        if !source && scenario != .legacy { value["nativeSources"] = sources() }
        if scenario.sourceWarning && !warningCleared {
            value["nativeSourcesError"] = "synthetic earlier source unavailable"
            if !source {
                value["nativeHistory"] = scenario == .warningPartial ? 4 : 0
                if scenario != .warningPartial { value["items"] = [row(run, native: nil)] }
                if scenario == .warningZero { value["items"] = []; value["pending"] = 0 }
            }
        }
        if scenario.ordinarySource {
            if source {
                var foreign = row(run, native: nil)
                foreign["deliveryUnknown"] = "synthetic other session unknown"
                foreign["target"] = identity(run, session: "other-native")
                foreign["id"] = "foreign"
                value["items"] = [row(run), row(run, id: "pending", native: nil), row(run, id: "sent", native: nil), foreign]
                if hidden { value["items"] = (value["items"] as! [[String: Any]]).filter { $0["id"] as? String != "same" } }
                value["later"] = []
                value["pending"] = 4
                value["nativeHistory"] = 0
            } else {
                value["items"] = [row(run, native: nil)]
                value["nativeHistory"] = hidden ? 0 : 1
            }
        }
        if !source { value["identity"] = identity(run, session: ownerSession) }
        if run == "r-old" {
            value["items"] = [row(run)]
            value["later"] = []
            value["pending"] = 0
            value["nativeHistory"] = 1
        }
        if !source && scenario == .wrongCurrentWorkspace { value["ws"] = "other-workspace" }
        if source {
            if scenario == .wrongWorkspace { value["ws"] = "other-workspace" }
            if scenario == .wrongRun { value["run"] = "r-wrong" }
            if scenario == .wrongIdentity { value["identity"] = identity("r-wrong") }
            if scenario.sourceIdentityMoved { value["identity"] = identity(run, session: "source-current-session") }
        }
        return value
    }
    private func json(_ object: Any, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")],
                     body: try JSONSerialization.data(withJSONObject: object), reusable: true)
    }
    func send(_ request: HTTPRequest, host: LoomHost, credential: GatewayCredential, reuse: Bool) async throws -> HTTPResponse {
        try require(host.deviceID == credential.device, "Mixed pairing owner")
        let url = URLComponents(string: "http://synthetic.invalid" + request.target)!
        let path = url.path
        if request.method == "POST" {
            try require(path == "/api/agents/r1/queue" && !reuse, "Source became a send or automatic replay")
            let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            try require(body["text"] as? String == original, "Local send text was replaced by a preview")
            try require((body["target"] as? [String: Any])?["run"] as? String == "r1", "Send rebound to original run")
            let attempt = request.headers.first { $0.0 == "X-Loom-Attempt" }?.1 ?? ""
            try require(!attempt.isEmpty, "Missing send attempt")
            sendAttempts.append(attempt)
            writes.append((request.method, path)); posted = true
            if scenario == .warningZero { return try json(["bounded": true, "byteLimit": 8_388_608, "delivered": true, "queue": queue("r1")]) }
            if scenario == .receipt { return try json(["bounded": true, "byteLimit": 8_388_608, "delivered": false, "item": row("r1"), "queue": queue("r1")]) }
            throw TransportFailure.noReply("synthetic unknown after POST")
        }
        let response: HTTPResponse
        if request.method == "DELETE" {
            try require(path == (scenario.ordinarySource ? "/api/agents/r0/queue/same" : "/api/agents/r0/queue/same/native") &&
                        !reuse && request.body == nil && url.queryItems == [URLQueryItem(name: "bounded", value: "1")], "Removal used wrong run/endpoint/body or write replay")
            writes.append((request.method, path))
            hidden = scenario != .ordinaryRemoveStillPresent
            if scenario == .hideUnknown || scenario == .ordinaryRemoveUnknown { throw TransportFailure.noReply("synthetic lost removal ACK") }
            var remaining = queue("r0")
            if scenario == .ordinaryRemoveWorkspace { remaining["ws"] = "other-workspace" }
            if scenario == .ordinaryRemoveIdentity { remaining["identity"] = identity("r0", session: "source-after-delete-session") }
            response = try json(remaining)
        } else {
            try require(request.method == "GET", "Unexpected mutation")
            if path == "/api/health" { return try json(["api": 1, "version": "synthetic"]) }
            if path == "/api/projects" || path == "/api/agents/profiles" { return try json([]) }
            if path == "/api/workspaces" { return try json([["id": "w1"]]) }
            if path == "/api/agents" {
                return try json((1...2).map { index -> [String: Any] in
                    var card: [String: Any] = ["run": "r\(index)", "terminal": "t\(index)", "ws": "w1", "engine": scenario.ordinarySource ? "claude" : "codex", "status": "active", "state": "working"]
                    if scenario == .warningCard { card["nativeSourcesError"] = "synthetic earlier source unavailable"; card["nativeHistory"] = 0 }
                    return card
                })
            }
            if path == "/api/terminals" { return try json((1...2).map { ["id": "t\($0)", "ws": "w1", "alive": true, "agent": ["run": "r\($0)", "engine": scenario.ordinarySource ? "claude" : "codex"]] as [String: Any] }) }
            if path.hasSuffix("/chat") {
                let run = path.contains("/t1/") ? "r1" : "r2"
                if url.queryItems?.contains(where: { $0.name == "after" && $0.value == "1:0" }) == true {
                    return try json(["bounded": true, "byteLimit": 1_048_576, "identity": identity(run, session: ownerSession), "items": [],
                        "start": "1:0", "end": "1:0", "size": 1, "older": true, "newer": false])
                }
                return try json(["bounded": true, "byteLimit": 1_048_576, "identity": identity(run, session: ownerSession),
                    "items": [["type": "message", "role": "user", "text": original, "offset": 0, "cursor": "0:0", "id": "native-only-once"]],
                    "start": "0:0", "end": "1:0", "size": 1, "older": false, "newer": false])
            }
            let parts = path.split(separator: "/")
            if parts.count == 3, parts[1] == "agents" { return try json(["run": String(parts[2]), "asks": []]) }
            try require(parts.count >= 4 && parts[1] == "agents" && parts[3] == "queue", "Unexpected path: " + path)
            let run = String(parts[2])
            if parts.count == 4 {
                try require(url.queryItems == [URLQueryItem(name: "bounded", value: "1")], "Queue read was not bounded")
                if run == "r0" { sourceGets += 1 }
                response = scenario == .missing && run == "r0" ? try json(["error": "synthetic original source unavailable"], status: 404) : try json(queue(run))
            } else {
                try require(parts.count == 5 && ["r0", "r-old"].contains(run) && url.queryItems == nil, "Full read used the current run or preview endpoint")
                let id = String(parts[4])
                var item = row(run, id: id, native: id == "future" ? "future-host-state" : (id == "unknown" ? "unknown" : "accepted"), full: true)
                if scenario == .fullRevision || scenario == .ordinaryFullRevision { item["updated"] = "2026-11-16T08:00:02Z" }
                if scenario == .fullTarget { item["target"] = identity(run, session: "other-native") }
                response = try json(["run": run, "ws": scenario == .fullWorkspace ? "other-workspace" : "w1",
                    "identity": identity(scenario == .fullIdentity || scenario == .ordinaryFullOwner ? "r-wrong" : run,
                                         session: scenario == .sourceFullIdentityDrift ? "source-after-full-session" : scenario.sourceIdentityMoved ? "source-current-session" : "native-shared"),
                    "state": "stopped", "ended": true,
                    "later": scenario == .fullLater ? true : id == "future", "item": item])
            }
        }
        if holdPath == path {
            holdPath = nil; held = response
            let result = await withCheckedContinuation { waiter = $0 }
            cancelled = Task.isCancelled
            return result
        }
        return response
    }
}

private struct Transport: ArgoHTTPTransport {
    let network: Network
    let host: LoomHost
    let credential: GatewayCredential
    func loomdToken() async throws -> String { String(repeating: "d", count: 64) }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        try await network.send(request, host: host, credential: credential, reuse: reuse)
    }
    func close() async {} // Deliberately leave old I/O alive to verify owner guards.
}
@MainActor private final class Creations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}
private actor Pairing {
    private var count = 0
    func pair() -> GatewayCredential { count += 1; return GatewayCredential(device: "synthetic-\(count)", token: String(repeating: "b", count: 43)) }
}
@MainActor private func eventually(_ reason: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Failure("Timeout: " + reason)
}
@MainActor private struct Fixture {
    let directory: URL
    let model: AppModel
    let network: Network
    let a: LoomHost
    let b: LoomHost
    static func code(_ name: String) -> String { "argo1:\(name).fixture.invalid:6779:\(Base64URL.encode(Data(repeating: 1, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))" }
    func select(_ host: LoomHost, run: String = "r1") async throws -> ConversationState {
        model.selectHost(host.id)
        try await eventually("Host connected") { model.hostID == host.id && model.status.isConnected && model.agents.count == 2 }
        let key = SessionKey(host: host.id, workspace: "w1", run: run, terminal: run == "r1" ? "t1" : "t2")
        model.selectSession(key); model.showConversation(key, visible: true)
        try await eventually("Native owner and queue") { model.conversation?.key == key && model.conversation?.canSendToIdentity == true && model.conversation?.queue != nil }
        return model.conversation!
    }
    func open(_ state: ConversationState) throws -> NativeHistoryRead {
        guard let source = state.nativeHistorySources.first else { throw Failure("Missing actual decoded source") }
        model.openNativeHistory(source, for: state.key)
        guard let read = state.nativeHistoryRead else { throw Failure("Source presentation did not open") }
        return read
    }
    func finish() async {
        model.setActive(false); await network.release()
        try? FileManager.default.removeItem(at: directory)
    }
    static func make(_ scenario: Scenario) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("restored-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let network = Network(scenario), pairing = Pairing()
        let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in await pairing.pair() }
        let a = try await store.pair(code: code("a"), deviceName: "synthetic")
        let b = try await store.pair(code: code("b"), deviceName: "synthetic")
        let model = AppModel(store: store, pendingCreations: Creations()) { host, credential in
            ArgoConnection(host: host, transport: Transport(network: network, host: host, credential: credential))
        }
        await model.loadHosts(); model.selectHost(a.id); model.setActive(true)
        let fixture = Fixture(directory: directory, model: model, network: network, a: a, b: b)
        _ = try await fixture.select(a)
        return fixture
    }
}

@MainActor private func run(_ scenario: Scenario, _ f: Fixture) async throws {
    let state = f.model.conversation!
    if scenario == .warningCard {
        try require(f.model.selectedAgent?.nativeHistory == 0 && f.model.selectedAgent?.nativeSourcesError != nil &&
                    f.model.sourceHistoryProblem == nil, "Fresh queue did not own its warning over stale card data")
        state.releaseReloadableContent()
        try require(f.model.sourceHistoryProblem == "synthetic earlier source unavailable" &&
                    AgentSession(f.model.selectedAgent!).state == .working, "Card-only zero-count warning became a current Agent failure or disappeared")
        f.model.refreshConversation()
        try await eventually("Fresh queue clears card fallback") { state.queue != nil && state.canSendToIdentity && f.model.sourceHistoryProblem == nil }
        return
    }
    if scenario.sourceWarning {
        try require(f.model.sourceHistoryProblem == "synthetic earlier source unavailable" && state.problem == nil &&
                    f.model.status.isConnected && state.canSendToIdentity, "Source warning invalidated current queue/native owner")
        if scenario == .warningZero {
            try require(state.queue?.nativeHistory == 0 && state.nativeHistorySources.isEmpty && state.pendingQueueCount == 0, "Zero-count fixture did not retain the independent warning")
            for index in 1...2 {
                state.draft = original
                f.model.sendDraft(for: state.key)
                try await eventually("Current send succeeds despite source warning") { state.deliveries.count == index && state.deliveries.allSatisfy { $0.status == .delivered } }
                try require(f.model.sourceHistoryProblem != nil && state.problem == nil && state.deliveries.last?.operation.text == original,
                            "Successful current receipt was hidden by a source failure")
            }
            let writes = await f.network.writes, attempts = await f.network.sendAttempts
            try require(writes.count == 2 && Set(attempts).count == 2 && state.deliveries.allSatisfy { $0.queueItemID == nil },
                        "Source warning blocked a new draft, retried an old attempt or fabricated an item binding")
        } else if scenario == .warningRecovery {
            state.draft = "preserve draft while source reads recover"
            await f.network.clearWarning(); f.model.refreshConversation()
            try await eventually("Source warning recovers independently") { f.model.sourceHistoryProblem == nil && state.nativeHistorySources.count == 2 }
            try require(state.draft == "preserve draft while source reads recover" && state.problem == nil, "Source recovery consumed a current draft")
        } else {
            let read = try f.open(state)
            try await eventually("Available partial source remains readable") { !read.loading && read.rows.count == 3 }
            try require(state.allQueueItems.count == 2 && state.pendingQueueCount == 1 && state.nativeHistoryCount == 1 &&
                        read.problem == nil && read.queue?.nativeSourcesError != nil, "Partial warning discarded usable current/source rows")
            f.model.openNativeHistoryItem(read.rows[0], in: read, copy: true)
            let full = read.queueItemRead!
            await full.task?.value
            try require(f.model.queueItemText(full) == original && f.model.sourceHistoryProblem != nil, "Partial warning invalidated a validated full read")
        }
        return
    }
    if scenario.ordinarySource {
        if scenario == .ordinaryUnknown || scenario == .ordinaryCleanup || scenario.ordinaryRemoval {
            state.draft = original; f.model.sendDraft(for: state.key)
            try await eventually("Original current attempt unknown") {
                if case .unknown = state.deliveries.first?.status { return true }; return false
            }
        }
        let read = try f.open(state)
        try await eventually("Stable Claude source loaded") { !read.loading && read.rows.count == 1 }
        let row = read.rows[0]
        try require(row.id == "same" && row.native == nil && !row.deliveryUnknown.isEmpty &&
                    row.target == read.source.target && row.target?.engine == "claude" && state.nativeHistoryCount == 0,
                    "Plain unknown was forged into Native or pending/foreign rows leaked into its source")
        f.model.hideNativeHistoryItem(row, in: read)
        try require(read.hideTasks.isEmpty && read.hidingIDs.isEmpty, "Plain unknown used native-hide")
        if scenario.ordinaryRemoval {
            let delayed = scenario == .ordinaryRemoveClose || scenario == .ordinaryRemoveRepair
            if delayed { await f.network.hold("/api/agents/r0/queue/same") }
            f.model.removeUnknownHistoryItem(row, in: read)
            f.model.removeUnknownHistoryItem(row, in: read)
            guard let task = read.hideTasks[row.id] else { throw Failure("Ordinary DELETE was not registered") }
            if delayed {
                try await eventually("Ordinary DELETE held") { await f.network.waiting }
                if scenario == .ordinaryRemoveRepair {
                    f.model.pair(code: Fixture.code("a"), name: "synthetic", deviceName: "synthetic")
                    try await eventually("Removal owner re-paired") { !f.model.pairing && f.model.selectedHost?.deviceID != f.a.deviceID && f.model.status.isConnected }
                } else { f.model.closeNativeHistory(read) }
                await f.network.release()
            }
            await task.value
            if delayed {
                try require(task.isCancelled && read.queue == nil && read.hideProblem == nil && read.hiddenIDs.isEmpty,
                            "Late DELETE receipt restored a closed/retired owner")
            } else if [.ordinaryRemoveUnknown, .ordinaryRemoveWorkspace, .ordinaryRemoveIdentity, .ordinaryRemoveStillPresent].contains(scenario) {
                try require(read.hideProblem?.contains("Removal was not confirmed.") == true && read.rows.count == 1 && read.hiddenIDs.isEmpty,
                            "Unknown/invalid DELETE response implied removal or crossed its source identity")
                f.model.removeUnknownHistoryItem(row, in: read)
            } else {
                try await eventually("Current source summary refreshed after ordinary removal") { state.nativeHistorySources.isEmpty && state.nativeHistoryRead == nil }
                try require(state.allQueueItems.contains { $0.id == row.id }, "Ordinary removal touched the same ID in the current run")
            }
            let writes = await f.network.writes
            try require(writes.count == 2 && writes[0].0 == "POST" && writes[1].0 == "DELETE" && writes[1].1 == "/api/agents/r0/queue/same",
                        "Ordinary removal duplicated POST/DELETE or used native-hide")
            guard case .unknown = state.deliveries.first?.status else { throw Failure("Ordinary removal promoted the original current receipt") }
            try require(state.deliveries[0].operation.text == original && !state.deliveries[0].status.canRetry && state.deliveries[0].queueItemID == nil,
                        "Ordinary removal changed current operation/body/retry state")
            return
        }
        let delayed = scenario == .ordinaryFullClose || scenario == .ordinaryRepair
        if delayed { await f.network.hold("/api/agents/r0/queue/same") }
        f.model.openNativeHistoryItem(row, in: read, copy: true)
        let full = read.queueItemRead!, task = read.queueItemRead!.task!
        if delayed {
            try await eventually("Plain source full GET held") { await f.network.waiting }
            if scenario == .ordinaryRepair {
                f.model.pair(code: Fixture.code("a"), name: "synthetic", deviceName: "synthetic")
                try await eventually("Real ordinary-source same-host re-pair") { !f.model.pairing && f.model.selectedHost?.deviceID != f.a.deviceID && f.model.status.isConnected }
            } else { f.model.closeNativeHistory(read) }
            await f.network.release(); await task.value
            try require(task.isCancelled && full.item == nil && read.queue == nil && f.model.queueItemText(full) == nil, "Late plain source full read crossed its presentation/pairing owner")
        } else {
            await task.value
            if scenario == .ordinaryFullRevision || scenario == .ordinaryFullOwner {
                try require(full.problem != nil && full.item == nil && f.model.queueItemText(full) == nil, "Changed plain unknown full revision/identity authorized copy")
            } else {
                try require(full.item?.native == nil && full.item?.deliveryUnknown == row.deliveryUnknown && full.run == "r0" &&
                            full.key == state.key && f.model.queueItemText(full) == original, "Plain unknown full read lost original run/target/body/status")
            }
        }
        if scenario == .ordinaryCleanup {
            state.releaseReloadableContent()
            try require(state.nativeHistoryRead == nil && read.queue == nil && read.queueItemRead == nil && read.hideTasks.isEmpty,
                        "Cold state retained plain unknown source content")
        }
        let writes = await f.network.writes
        try require(writes.allSatisfy { $0.0 == "POST" } && writes.count == (scenario == .ordinaryUnknown || scenario == .ordinaryCleanup ? 1 : 0),
                    "Plain source reading posted, removed or automatically retried input")
        if !state.deliveries.isEmpty {
            guard case .unknown = state.deliveries[0].status else { throw Failure("Plain source promoted a current unknown receipt") }
            try require(!state.deliveries[0].status.canRetry && state.deliveries[0].operation.text == original && state.deliveries[0].queueItemID == nil,
                        "Plain source rebound the current operation or retry rule")
        }
        return
    }
    if scenario == .legacy {
        try require(state.nativeHistorySources.isEmpty && state.ordinaryQueueItems.count == 1, "Old host lost queue functionality or fabricated sources")
        return
    }
    if scenario == .basic || scenario == .receipt || scenario == .cleanup {
        state.draft = original
        f.model.sendDraft(for: state.key)
        try await eventually("Actual send terminated") { state.deliveries.first?.status != .sending }
        let delivery = state.deliveries.first!
        try require(delivery.operation.text == original && !delivery.status.canRetry, "Original operation or retry rule changed")
        if scenario == .receipt {
            guard case .native(let native) = delivery.status else { throw Failure("Native receipt lost typed status") }
            try require(native.state == .accepted && !delivery.status.isKnownSuccess && delivery.queueItemID == "same", "Accepted became completion or lost ID")
        }
    }
    let sourceLate = [Scenario.sourceClose, .sourceHost, .sourceRun, .sourceReconnect, .sourceRepair, .sourceRevoked, .sourceRefresh, .ownerIdentityChanged].contains(scenario)
    if sourceLate { await f.network.hold("/api/agents/r0/queue") }
    let read = try f.open(state)
    if sourceLate {
        guard let task = read.task else { throw Failure("No real source read Task") }
        try await eventually("Source GET paused") { await f.network.waiting }
        switch scenario {
        case .sourceClose: f.model.closeNativeHistory(read)
        case .sourceHost: _ = try await f.select(f.b)
        case .sourceRun: _ = try await f.select(f.a, run: "r2")
        case .sourceReconnect: f.model.reconnect()
        case .sourceRepair:
            f.model.pair(code: Fixture.code("a"), name: "synthetic", deviceName: "synthetic")
            try await eventually("Real same-ID re-pair") { !f.model.pairing && f.model.selectedHost?.deviceID != f.a.deviceID && f.model.status.isConnected }
        case .sourceRevoked:
            await f.network.revoke(); f.model.showConversation(state.key, visible: true)
            try await eventually("Source descriptor removed by current queue") { state.nativeHistorySources.isEmpty }
        case .sourceRefresh:
            f.model.refreshNativeHistory(read)
            try await eventually("Replacement source GET completed") { !read.loading && read.rows.count == 3 }
        case .ownerIdentityChanged:
            await f.network.changeOwner(); f.model.showLatest()
            try await eventually("Actual native owner changed") { state.transcript.identity?.session == "new-owner-native-session" }
        default: break
        }
        try require(task.isCancelled && (scenario == .sourceRefresh || state.nativeHistoryRead == nil), "Owner transition did not cancel source Task")
        await f.network.release(); await task.value
        if scenario == .sourceRefresh {
            try require(state.nativeHistoryRead === read && read.rows.count == 3 && read.problem == nil, "Old source GET overwrote replacement read")
        } else {
            try require(read.queue == nil && read.rows.isEmpty && read.problem == nil && read.task == nil, "Late source result restored released content")
        }
        if scenario == .sourceReconnect || scenario == .sourceRepair {
            try await eventually("Reconnected owner ready") { f.model.status.isConnected && state.queue != nil && state.canSendToIdentity }
            let current = try f.open(state)
            try await eventually("Source usable after connection replacement") { !current.loading && current.rows.count == 3 }
        }
        return
    }
    try await eventually("Source loaded or explicit error") { !read.loading && (read.queue != nil || read.problem != nil) }
    if [.missing, .wrongWorkspace, .wrongCurrentWorkspace, .wrongRun, .wrongIdentity, .wrongSourceSession, .noMatchingRows].contains(scenario) {
        try require(read.problem != nil && read.rows.isEmpty && state.queue?.run == "r1", "Missing/invalid source was presented as usable history")
        if scenario == .wrongSourceSession { let gets = await f.network.sourceGets; try require(gets == 0, "Cross-session descriptor authorized an original queue GET") }
        return
    }
    try require(read.rows.count == 3 && read.rows.allSatisfy { $0.native != nil && $0.target == read.source.target }, "Source target/native filter leaked unrelated rows")
    try require(state.nativeHistoryCount == (scenario == .receipt ? 2 : 1) && state.allQueueItems.count == 2 && state.queue?.later.isEmpty == true, "Source became current pending/history rows")
    try require(state.transcript.items.count == 1, "Handoff duplicated the provider chat message")
    if scenario == .multiSource {
        f.model.openNativeHistory(state.nativeHistorySources[1], for: state.key)
        let other = state.nativeHistoryRead!
        try await eventually("Second source loaded") { !other.loading && other.rows.count == 1 }
        try require(read.queue == nil && other.source.sourceRun == "r-old" && other.rows[0].id == "same", "Switching source retained old rows or changed original ID")
        f.model.openNativeHistoryItem(other.rows[0], in: other, copy: true)
        let full = other.queueItemRead!
        await full.task?.value
        try require(full.run == "r-old" && full.key == state.key && f.model.queueItemText(full) == original, "Same item ID crossed original runs")
        return
    }
    let item = read.rows.first { $0.id == "same" }!
    if scenario == .hideDuplicate || scenario == .hideClose || scenario == .hideUnknown {
        if scenario != .hideUnknown { await f.network.hold("/api/agents/r0/queue/same/native") }
        f.model.hideNativeHistoryItem(item, in: read); f.model.hideNativeHistoryItem(item, in: read)
        guard let task = read.hideTasks[item.id] else { throw Failure("No real hide Task") }
        if scenario != .hideUnknown { try await eventually("Native DELETE paused") { await f.network.waiting } }
        if scenario == .hideClose { f.model.closeNativeHistory(read) }
        await f.network.release(); await task.value
        if scenario == .hideUnknown {
            try require(read.hideProblem?.contains("Hiding was not confirmed.") == true && read.rows.count == 3, "Unknown hide implied success or lost explicit failure")
            f.model.hideNativeHistoryItem(item, in: read)
            f.model.refreshNativeHistory(read)
            try await eventually("Explicit hide readback") { !read.loading && read.hideProblem == nil && read.rows.count == 2 }
        }
        let writes = await f.network.writes
        try require(writes.count == 1 && writes[0].0 == "DELETE", "Duplicate hide or conversation POST")
        if scenario == .hideClose { try require(task.isCancelled && read.queue == nil && read.hiddenIDs.isEmpty, "Late hide resurrected closed state") }
        else if scenario != .hideUnknown {
            try await eventually("Current source count refreshed after hide") { state.nativeHistorySources.first?.nativeHistory == 2 && state.nativeHistoryRead == nil }
            try require(read.queue == nil && state.allQueueItems.contains { $0.id == item.id }, "Hide used current-run ID or retained stale source data")
        }
        return
    }
    if scenario == .cleanup {
        var closed: [NativeHistoryRead] = [read]
        for _ in 0..<20 {
            f.model.closeNativeHistory(closed.last!)
            let next = try f.open(state)
            try await eventually("Next source read") { !next.loading && next.queue != nil }
            closed.append(next)
        }
        state.releaseReloadableContent()
        try require(state.nativeHistoryRead == nil && closed.allSatisfy { $0.queue == nil && $0.queueItemRead == nil && $0.task == nil && $0.hideTasks.isEmpty }, "Cold state retained history content or tasks")
        try require(state.deliveries.first?.operation.text == original && state.deliveries.first?.status.canRetry == false, "Cleanup changed unresolved operation")
        return
    }
    let fullLate = [Scenario.fullClose, .fullSheetClose, .fullHost, .fullRun, .fullReconnect].contains(scenario)
    if fullLate { await f.network.hold("/api/agents/r0/queue/same") }
    f.model.openNativeHistoryItem(item, in: read, copy: true)
    guard let full = read.queueItemRead, let task = full.task else { throw Failure("No actual source full GET") }
    if fullLate {
        try await eventually("Full GET paused") { await f.network.waiting }
        switch scenario {
        case .fullHost: _ = try await f.select(f.b)
        case .fullRun: _ = try await f.select(f.a, run: "r2")
        case .fullReconnect: f.model.reconnect()
        case .fullSheetClose: f.model.closeQueueItem(full)
        default: f.model.closeNativeHistory(read)
        }
        await f.network.release(); await task.value
        try require(task.isCancelled && read.queueItemRead == nil && f.model.queueItemText(full) == nil && full.item == nil, "Late full read authorized stale copy")
        if scenario == .fullSheetClose {
            f.model.openNativeHistoryItem(item, in: read)
            let replacement = read.queueItemRead!
            await replacement.task?.value
            try require(f.model.queueItemText(replacement) == original, "Closing a full sheet broke its source window")
        }
        return
    }
    await task.value
    if [.fullRevision, .fullWorkspace, .fullIdentity, .fullTarget, .fullLater, .sourceFullIdentityDrift].contains(scenario) {
        try require(full.problem != nil && f.model.queueItemText(full) == nil, "Changed full revision/owner/target/later authorized copy")
        return
    }
    try require(full.problem == nil && f.model.queueItemText(full) == original && full.run == "r0" && full.key == state.key,
                "Full source text lost original run or current presentation owner")
    for id in ["unknown", "future"] {
        let row = read.rows.first { $0.id == id }!
        f.model.openNativeHistoryItem(row, in: read)
        let next = read.queueItemRead!
        await next.task?.value
        try require(next.item?.native?.state == .unknown && f.model.queueItemText(next) == original, "Unknown/future native state became editable or lost full read")
    }
    if scenario == .basic || scenario == .receipt {
        let writes = await f.network.writes
        let attempts = await f.network.sendAttempts
        try require(writes.count == 1 && writes[0].0 == "POST" && state.deliveries.first?.operation.text == original && !state.deliveries.first!.status.canRetry,
                    "Source read retried unknown, changed local original, or changed receipt ownership")
        let delivery = state.deliveries.first!
        try require(attempts == [delivery.operation.attempt], "History read changed the actual send attempt")
        if scenario == .basic {
            guard case .unknown = delivery.status else { throw Failure("Source record upgraded an unbound unknown receipt") }
            try require(delivery.queueItemID == nil, "Source same-ID record bound a current-run receipt")
        } else {
            guard case .native(let native) = delivery.status else { throw Failure("Original accepted receipt lost native status") }
            try require(native.state == .accepted && delivery.queueItemID == "same", "Source unknown changed the current accepted receipt")
        }
    }
}

@main private enum RestoredHistoryCheck {
    @MainActor static func main() async {
        var passed = 0
        for scenario in Scenario.allCases {
            do {
                let fixture = try await Fixture.make(scenario)
                do { try await run(scenario, fixture); await fixture.finish() }
                catch { await fixture.finish(); throw error }
                print("PASS \(scenario.rawValue)")
                passed += 1
            } catch { print("FAIL \(scenario.rawValue): \(error)") }
        }
        print("Restored history: \(passed)/\(Scenario.allCases.count) passed")
        if passed != Scenario.allCases.count { exit(1) }
    }
}
