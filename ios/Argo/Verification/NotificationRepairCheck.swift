import ArgoMobileKit
import Foundation
import Glibc

private struct Failure: Error, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ text: String) { description = text }
}
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
private let originalText = "SYNTHETIC_NOTIFICATION_PENDING\n  原文🙂  "
private let unknownReason = "synthetic notification pending result unknown"
private enum Scenario: String {
    case pushB, sameHostRun, userB, forget, repair, reconnect, pairFailed, pairRollback, newerRoute, missingAgent
    case pairCancelEmpty, pairCancelExisting, pairCancelRepair, pairBackgroundEmpty, pairBackgroundExisting
    case pairCancelBeforeSave, pairCancelLate, pairBackgroundLate, pairDuplicate, pairForgetLate, pairForgetDuringRestore, pairNewFailed

    var checksPairingLifecycle: Bool {
        switch self {
        case .pairCancelEmpty, .pairCancelExisting, .pairCancelRepair, .pairBackgroundEmpty, .pairBackgroundExisting,
             .pairCancelBeforeSave, .pairCancelLate, .pairBackgroundLate, .pairDuplicate, .pairForgetLate,
             .pairForgetDuringRestore, .pairNewFailed: true
        default: false
        }
    }
}

private actor Pairing {
    private var repaired = false
    private var failing = false
    private var cancelPair = false
    private var holdPair = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var waiting: Bool { pending != nil }
    func cancelNextPair() { cancelPair = true }
    func holdNextPair() { holdPair = true }
    func releasePair() { pending?.resume(); pending = nil }
    func replaceA() { repaired = true }
    func failA() { failing = true }
    func pair(_ code: PairingCode) async throws -> GatewayCredential {
        calls += 1
        if holdPair {
            holdPair = false
            await withCheckedContinuation { pending = $0 }
        }
        if cancelPair { cancelPair = false; withUnsafeCurrentTask { $0?.cancel() } }
        let a = code.host == "a.fixture.invalid"
        if a && failing { throw Failure("Synthetic pairing failed.") }
        return GatewayCredential(device: a ? (repaired ? "fixture-A-v2" : "fixture-A-v1") : "fixture-B-v1",
                                 token: String(repeating: a ? (repaired ? "c" : "a") : "b", count: 43))
    }
}

private final class Tokens: DeviceTokenStoring, @unchecked Sendable {
    private let backing = InMemoryDeviceTokens()
    private let lock = NSLock()
    private var failSave = false
    private var cancelSave = false
    private var holdSave = false
    private var saveWaiting = false
    private let release = DispatchSemaphore(value: 0)
    func holdNextSave() { lock.lock(); defer { lock.unlock() }; holdSave = true }
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return saveWaiting }
    func releaseSave() { release.signal() }
    func cancelNextSave() { lock.lock(); defer { lock.unlock() }; cancelSave = true }
    func failNextSave() { lock.lock(); defer { lock.unlock() }; failSave = true }
    func save(_ token: String, for host: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try backing.save(token, for: host)
        // Cancel the real pairing Task inside the synchronous persistence boundary.
        if cancelSave { cancelSave = false; withUnsafeCurrentTask { $0?.cancel() } }
        if holdSave {
            holdSave = false
            saveWaiting = true
            lock.unlock()
            release.wait()
            lock.lock()
            saveWaiting = false
        }
        // Fail after the synthetic write so ArgoHostStore must restore the old token.
        if failSave { failSave = false; throw Failure("Synthetic credential save failed.") }
    }
    func read(_ host: UUID) throws -> String? { try backing.read(host) }
    func delete(_ host: UUID) { backing.delete(host) }
}

// The HTTP/OS boundaries are synthetic; route guards, Task registration,
// pairing, cancellation, selection and receipt reconciliation are production.
private actor Network {
    let terminalUnknown: Bool
    private(set) var messages: [(UUID, HTTPRequest)] = []
    private(set) var fullReads: [UUID] = []
    private var unknownHosts: Set<UUID> = []
    private var pauseDirectory: UUID?
    private var directory: CheckedContinuation<HTTPResponse, Never>?
    private var directoryResponse: HTTPResponse?
    private var pauseFull: UUID?
    private var full: CheckedContinuation<HTTPResponse, Never>?
    private var fullResponse: HTTPResponse?
    private var post: CheckedContinuation<HTTPResponse, Never>?
    private var postResponse: HTTPResponse?
    private(set) var fullCancelled = false
    private(set) var postCancelled = false
    var directoryWaiting: Bool { directory != nil }
    var fullWaiting: Bool { full != nil }
    var postWaiting: Bool { post != nil }
    init(terminalUnknown: Bool) { self.terminalUnknown = terminalUnknown }
    func holdDirectory(_ id: UUID) { pauseDirectory = id }
    func holdFull(_ id: UUID) { pauseFull = id }
    func releaseDirectory() { if let directoryResponse { directory?.resume(returning: directoryResponse) }; directory = nil; directoryResponse = nil }
    func releaseFull() { if let fullResponse { full?.resume(returning: fullResponse) }; full = nil; fullResponse = nil }
    func releasePost() { if let postResponse { post?.resume(returning: postResponse) }; post = nil; postResponse = nil }
    func count(_ id: UUID) -> Int { messages.filter { $0.0 == id }.count }
    func attempt(_ id: UUID) -> String? { messages.first { $0.0 == id }?.1.headers.first { $0.0 == "X-Loom-Attempt" }?.1 }
    private func identity(_ host: LoomHost, run: String) -> [String: Any] {
        ["run": run, "engine": "codex", "session": "native-\(host.deviceID)-\(run)"]
    }
    private func row(_ host: LoomHost, run: String, unknown: Bool) -> [String: Any] {
        var result: [String: Any] = ["id": "q1", "text": originalText, "submit": true, "source": "ios",
            "created": "2026-11-16T06:40:00Z", "updated": "2026-11-16T06:40:01Z", "target": identity(host, run: run)]
        if unknown { result["deliveryUnknown"] = unknownReason }
        return result
    }
    private func queue(_ host: LoomHost, run: String, unknown: Bool) -> [String: Any] {
        ["bounded": true, "byteLimit": 8_388_608, "run": run, "ws": "w1", "identity": identity(host, run: run),
         "state": "working", "ended": false, "items": [row(host, run: run, unknown: unknown)], "later": [], "pending": 1, "nativeHistory": 0]
    }
    private func json(_ object: Any) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "application/json")],
                     body: try JSONSerialization.data(withJSONObject: object), reusable: true)
    }
    func send(_ request: HTTPRequest, host: LoomHost, credential: GatewayCredential, reuse: Bool) async throws -> HTTPResponse {
        try require(host.deviceID == credential.device, "Connection mixed host/credential ownership")
        let url = URLComponents(string: "http://synthetic.invalid" + request.target)!
        let path = url.path
        if path == "/api/notify/device" {
            let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.0.lowercased(), $0.1) })
            try require(headers["x-argo-device-id"] == credential.device && headers["x-argo-device-token"] == credential.token,
                        "Notification registration crossed credential ownership")
            if request.method == "PUT" {
                return try json(["enabled": true, "hostID": host.id.uuidString, "deviceID": credential.device,
                                 "registrationID": "registration-\(credential.device)"])
            }
            try require(request.method == "DELETE", "Unexpected notification method")
            return try json(["enabled": false])
        }
        if request.method == "POST" {
            try require(path == "/api/agents/r1/queue" && !reuse && url.queryItems == [URLQueryItem(name: "bounded", value: "1")],
                        "Notification manufactured or replayed a conversation write")
            let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            try require(body["text"] as? String == originalText && body["source"] as? String == "ios", "Original send bytes changed")
            try require((body["target"] as? [String: Any])?["session"] as? String == "native-\(host.deviceID)-r1", "Send target crossed host/native owner")
            messages.append((host.id, request)); unknownHosts.insert(host.id)
            if terminalUnknown { throw TransportFailure.noReply("synthetic lost ACK") }
            postResponse = try json(["bounded": true, "byteLimit": 8_388_608, "delivered": false,
                                     "item": row(host, run: "r1", unknown: false), "queue": queue(host, run: "r1", unknown: false)])
            let result = await withCheckedContinuation { post = $0 }
            postCancelled = Task.isCancelled
            return result
        }
        try require(request.method == "GET", "Unexpected non-read navigation request")
        if path == "/api/health" { return try json(["api": 1, "version": "synthetic"]) }
        if path == "/api/projects" || path == "/api/agents/profiles" { return try json([]) }
        if path == "/api/workspaces" {
            let response = try json([["id": "w1"]])
            if pauseDirectory == host.id {
                pauseDirectory = nil; directoryResponse = response
                return await withCheckedContinuation { directory = $0 }
            }
            return response
        }
        if path == "/api/agents" { return try json((1...2).map { ["run": "r\($0)", "terminal": "t\($0)", "ws": "w1", "engine": "codex", "status": "active", "state": "working"] }) }
        if path == "/api/terminals" { return try json((1...2).map { ["id": "t\($0)", "ws": "w1", "alive": true, "agent": ["run": "r\($0)", "engine": "codex"]] as [String: Any] }) }
        if path.hasSuffix("/chat") {
            let run = path.contains("/t1/") ? "r1" : "r2"
            return try json(["bounded": true, "byteLimit": 1_048_576, "identity": identity(host, run: run),
                             "items": [], "start": "0:0", "end": "0:0", "size": 0, "older": false, "newer": false])
        }
        if path.hasPrefix("/api/agents/") {
            let parts = path.split(separator: "/")
            let run = String(parts[2])
            if parts.count == 5 && parts[3] == "queue" {
                fullReads.append(host.id)
                try require(parts[4] == "q1" && request.body == nil && url.queryItems == nil &&
                            !request.headers.contains { $0.0 == "X-Loom-Attempt" }, "Full GET carried write data")
                let response = try json(["run": run, "ws": "w1", "identity": identity(host, run: run), "state": "working",
                                         "ended": false, "later": false, "item": row(host, run: run, unknown: unknownHosts.contains(host.id))])
                if pauseFull == host.id {
                    pauseFull = nil; fullResponse = response
                    let result = await withCheckedContinuation { full = $0 }
                    fullCancelled = Task.isCancelled
                    return result
                }
                return response
            }
            if parts.count == 4 && parts[3] == "queue" {
                return try json(queue(host, run: run, unknown: unknownHosts.contains(host.id)))
            }
            if parts.count == 3 { return try json(["run": run, "asks": []]) }
        }
        throw Failure("Unexpected synthetic navigation path: \(path)")
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
    func close() async {} // Intentionally uncancellable I/O for late-response checks.
}
@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}
@MainActor private func eventually(_ label: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw Failure("Timed out: " + label)
}
@MainActor private func task(_ model: AppModel, label: String) -> Task<Void, Never>? {
    Mirror(reflecting: model).children.first { $0.label == label }?.value as? Task<Void, Never>
}
@MainActor private func registered(_ model: AppModel) throws -> [String: Task<Void, Never>] {
    guard let value = Mirror(reflecting: model).children.first(where: { $0.label == "sends" })?.value as? [String: Task<Void, Never>] else { throw Failure("Cannot observe real sends registration") }
    return value
}

@MainActor private final class Fixture {
    let pairing = Pairing()
    let network: Network
    let directory: URL
    let store: ArgoHostStore
    let tokens = Tokens()
    let model: AppModel
    let a: LoomHost
    let b: LoomHost
    let root: RootNotificationHarness
    var notifications: PhoneNotifications { .shared }
    static func code(_ address: String, fingerprint: UInt8 = 1) -> String {
        "argo1:\(address):6779:\(Base64URL.encode(Data(repeating: fingerprint, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))"
    }
    init(_ scenario: Scenario) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("argo-notification-combination-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        network = Network(terminalUnknown: scenario == .pushB)
        let pairing = pairing, network = network
        store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: tokens) { code, _ in try await pairing.pair(code) }
        a = try await store.pair(code: Self.code("a.fixture.invalid"), deviceName: "synthetic")
        b = try await store.pair(code: Self.code("b.fixture.invalid"), deviceName: "synthetic")
        let factory: AppModel.ConnectionFactory = { host, credential in ArgoConnection(host: host, transport: Transport(network: network, host: host, credential: credential)) }
        model = AppModel(store: store, pendingCreations: MemoryCreations(), makeConnection: factory)
        NotificationTestPlatform.defaults.set([a.id.uuidString, b.id.uuidString], forKey: "argo.push.enabledHosts.v1")
        root = RootNotificationHarness(model: model)
        PhoneNotifications.shared.attach(store: store, makeConnection: factory)
        PhoneNotifications.shared.hostsChanged([a, b])
        PhoneNotifications.shared.didRegister(Data(repeating: 3, count: 32))
        await PhoneNotifications.shared.refresh()
        try await eventually("Two synthetic registrations") { PhoneNotifications.shared.registrations.count == 2 }
        bindNotifications(to: model)
        await model.loadHosts(); model.selectHost(a.id); model.setActive(true)
        try await select(a, run: "r1")
    }
    func key(_ host: LoomHost, run: String) -> SessionKey { SessionKey(host: host.id, workspace: "w1", run: run, terminal: run == "r1" ? "t1" : "t2") }
    func select(_ host: LoomHost, run: String) async throws {
        model.selectHost(host.id)
        try await eventually("Selected host connected") { self.model.hostID == host.id && self.model.status.isConnected && self.model.agents.count == 2 }
        let key = key(host, run: run)
        model.selectSession(key); model.showConversation(key, visible: true)
        try await eventually("Selected native/queue ready") { self.model.conversation?.key == key && self.model.conversation?.canSendToIdentity == true && self.model.conversation?.queue != nil }
    }
    func route(_ host: LoomHost, run: String) throws -> ArgoPushRoute {
        guard let registration = notifications.registrations[host.id] else { throw Failure("No current registration") }
        let info: [AnyHashable: Any] = ["argo": ["v": 1, "hostID": host.id.uuidString, "deviceID": registration.deviceID,
            "registrationID": registration.registrationID, "workspace": "w1", "run": run, "event": "agent.done", "eventID": "synthetic-event"]]
        guard let route = ArgoPushRoute.decode(info) else { throw Failure("Synthetic notification did not decode") }
        return route
    }
    func tap(_ route: ArgoPushRoute) throws {
        notifications.receive(route)
        try require(notifications.pendingRoute == route, "Current synthetic notification was rejected")
        root.drive()
        try require(notifications.pendingRoute == nil && !root.hostsBinding.wrappedValue && !root.hostPairingShown,
                    "Production RootView handoff did not consume/dismiss presentation")
    }
    func finish() { model.setActive(false); try? FileManager.default.removeItem(at: directory) }
}

@MainActor private func check(_ scenario: Scenario) async throws {
    let f = try await Fixture(scenario)
    defer { f.finish() }
    if scenario == .missingAgent {
        try f.tap(f.route(f.a, run: "missing"))
        try await eventually("Current notification error") { f.model.notificationProblem != nil }
        try require(f.model.notificationProblem == L10n.text("This notification's Agent is no longer available.") &&
                    f.model.selectedKey == f.key(f.a, run: "r1"), "Current notification lost its legitimate failure message")
        let count = await f.network.messages.count
        try require(count == 0, "Failed navigation manufactured a message POST")
        print("PASS missingAgent: current notification retains unavailable-Agent error, no navigation or message POST")
        return
    }
    let state = f.model.conversation!
    state.draft = originalText
    f.model.sendDraft(for: state.key)
    guard let initial = state.deliveries.first, let sendTask = try registered(f.model)[initial.id] else { throw Failure("No real send Task") }
    if scenario == .pushB {
        await sendTask.value
        guard case .unknown = state.deliveries.first?.status else { throw Failure("Pending unknown did not terminate") }
    } else { try await eventually("Actual POST held") { await f.network.postWaiting } }
    f.model.refreshConversation()
    try await eventually("GET unknown evidence") { state.queue?.items.first?.deliveryUnknown == unknownReason }
    await f.network.holdFull(f.a.id)
    f.model.openQueueItem(state.ordinaryQueueItems[0], for: state.key, copy: true)
    guard let read = state.queueItemRead, let fullTask = read.task else { throw Failure("No production full-read Task") }
    try await eventually("Actual full GET held") { await f.network.fullWaiting }

    var notificationTask: Task<Void, Never>?
    var oldRoute: ArgoPushRoute?
    if scenario == .pushB || scenario == .sameHostRun {
        let target = scenario == .pushB ? f.b : f.a
        let run = scenario == .pushB ? "r1" : "r2"
        try f.tap(f.route(target, run: run))
        try await eventually("Notification selected exact host/run") { f.model.selectedKey == f.key(target, run: run) }
        f.model.showConversation(f.key(target, run: run), visible: true)
        try await eventually("Notification target native ready") { f.model.conversation?.canSendToIdentity == true }
        f.model.conversation?.draft = "preserve notified target draft"
    } else {
        await f.network.holdDirectory(f.a.id)
        let route = try f.route(f.a, run: "r2")
        oldRoute = route
        try f.tap(route)
        try await eventually("Notification directory GET held") { await f.network.directoryWaiting }
        notificationTask = task(f.model, label: "notificationTask")
        try require(notificationTask != nil, "No actual notification resolution Task")
        switch scenario {
        case .userB:
            try await f.select(f.b, run: "r1")
            f.model.conversation?.draft = "preserve manual B draft"
        case .forget:
            try await f.model.removeHost(f.a.id)
            f.notifications.hostsChanged(f.model.hosts)
            try await f.select(f.b, run: "r1")
            f.model.conversation?.draft = "preserve remaining B draft"
        case .repair:
            await f.pairing.replaceA()
            f.model.pair(code: Fixture.code("a.fixture.invalid", fingerprint: 4), name: "synthetic", deviceName: "synthetic")
            try await eventually("Actual re-pair plus registration restored") {
                !f.model.pairing && f.model.selectedHost?.deviceID == "fixture-A-v2" &&
                    f.notifications.registrations[f.a.id]?.deviceID == "fixture-A-v2" && f.model.status.isConnected
            }
            f.notifications.hostsChanged(f.model.hosts)
        case .reconnect:
            f.model.reconnect()
            try await eventually("Same pairing reconnect resolves original tap") {
                f.model.status.isConnected && f.model.selectedKey == f.key(f.a, run: "r2")
            }
            f.model.conversation?.draft = "preserve reconnected target draft"
        case .pairFailed, .pairRollback:
            if scenario == .pairFailed { await f.pairing.failA() }
            else { await f.pairing.replaceA(); f.tokens.failNextSave() }
            let originalCredential = try await f.store.credential(for: f.a)
            f.model.pair(code: Fixture.code("a.fixture.invalid", fingerprint: 4), name: "synthetic", deviceName: "synthetic")
            try await eventually("Failed pairing restored original registration") {
                !f.model.pairing && f.model.pairingProblem != nil &&
                    f.notifications.registrations[f.a.id]?.deviceID == f.a.deviceID
            }
            let persisted = try await f.store.hosts().first { $0.id == f.a.id }
            let restoredCredential = try await f.store.credential(for: f.a)
            let expectedError = scenario == .pairFailed ? "Synthetic pairing failed." : "Synthetic credential save failed."
            try require(persisted == f.a && restoredCredential == originalCredential &&
                        f.model.selectedHost == f.a && f.model.pairingProblem == expectedError,
                        "Failed pairing lost its error or did not retain/restore original pairing")
            try require(f.notifications.trusted(route), "Restored original registration lost its legitimate tap")
        case .newerRoute:
            try f.tap(f.route(f.b, run: "r1"))
            try await eventually("New notification wins") { f.model.selectedKey == f.key(f.b, run: "r1") }
            f.model.conversation?.draft = "preserve newer notification draft"
        default: throw Failure("Unexpected directory scenario")
        }
    }

    if notificationTask != nil { await f.network.releaseDirectory(); await notificationTask?.value }
    await f.network.releaseFull(); await fullTask.value
    if scenario != .pushB { await f.network.releasePost(); await sendTask.value }
    let fullCancelled = await f.network.fullCancelled
    try require(fullTask.isCancelled && fullCancelled && read.item == nil && f.model.queueItemText(read) == nil,
                "Notification/host lifecycle restored an old full read")
    let countA = await f.network.count(f.a.id), countB = await f.network.count(f.b.id)
    let attempt = await f.network.attempt(f.a.id)
    let fullCount = await f.network.fullReads.count
    try require(countA == 1 && countB == 0 && attempt == initial.id && fullCount == 1,
                "Notification/full read manufactured a conversation POST or replaced its attempt")
    if scenario == .forget {
        try require(!f.model.hosts.contains { $0.id == f.a.id } && f.model.selectedKey == f.key(f.b, run: "r1") &&
                    state.deliveries.isEmpty && state.queue == nil && state.queueItemRead == nil && state.transcript.identity == nil,
                    "Forgotten host revived from late notification/POST/full GET")
        try require(!f.notifications.trusted(oldRoute!), "Forgotten registration remained trusted")
    } else {
        guard let final = state.deliveries.first, case .unknown = final.status else { throw Failure("Pending unknown changed classification") }
        try require(final.id == initial.id && final.operation.text == originalText && final.operation.attempt == initial.operation.attempt && !final.status.canRetry,
                    "Notification changed original unknown text/attempt/retry state")
        try require(try registered(f.model).isEmpty, "Finished production send stayed registered")
        if scenario != .pushB { try require(final.queueItemID == "q1", "Late original POST did not retain original server ID") }
    }
    if scenario == .repair {
        try require(!f.notifications.trusted(oldRoute!), "Retired registration remained trusted after re-pair")
        print("OBSERVED repair: retiredRouteTrusted=\(f.notifications.trusted(oldRoute!)), selectedRun=\(f.model.selectedKey?.run ?? "nil"), currentDeviceIsReplacement=\(f.model.selectedHost?.deviceID == "fixture-A-v2")")
        try require(f.model.selectedKey == f.key(f.a, run: "r1"), "Retired notification navigated after re-pair to replacement credentials")
        try f.tap(f.route(f.model.selectedHost!, run: "r2"))
        try await eventually("Replacement pairing accepts a fresh tap") { f.model.selectedKey == f.key(f.a, run: "r2") }
    } else {
        let targetA = [.sameHostRun, .reconnect, .pairFailed, .pairRollback].contains(scenario)
        let target = targetA ? f.key(f.a, run: "r2") : f.key(f.b, run: "r1")
        try require(f.model.selectedKey == target && f.model.conversation?.deliveries.isEmpty == true &&
                    f.model.conversation?.queueItemRead == nil,
                    "Late notification completion contaminated current host/run/draft")
        if scenario != .pairFailed && scenario != .pairRollback {
            try require(f.model.conversation?.draft.isEmpty == false, "Late notification completion replaced the current draft")
        }
    }
    print("PASS \(scenario.rawValue): exact notification host/run ownership, original unknown isolated, cancelled full ignored, messagePOST A=1/B=0")
}

// Reuses this harness's real AppModel/ArgoHostStore and synthetic token/HTTP boundaries.
@MainActor private func checkPairingLifecycle(_ scenario: Scenario) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argo-pair-cancel-" + UUID().uuidString)
    let tokens = Tokens(), pairing = Pairing()
    let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: tokens) { code, _ in
        try await pairing.pair(code)
    }
    let connections = ConnectionCalls()
    let network = Network(terminalUnknown: false)
    let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, credential in
        connections.record(host.id)
        return ArgoConnection(host: host, transport: Transport(network: network, host: host, credential: credential))
    }
    defer { tokens.releaseSave(); model.setActive(false); try? FileManager.default.removeItem(at: directory) }
    let hasExisting = [.pairCancelExisting, .pairCancelRepair, .pairBackgroundExisting, .pairForgetLate, .pairForgetDuringRestore].contains(scenario)
    let existing = hasExisting ? try await store.pair(code: Fixture.code("a.fixture.invalid"), deviceName: "synthetic") : nil
    await model.loadHosts()
    model.setActive(true)
    if existing != nil { try await eventually("Original host connected") { model.status.isConnected } }
    let selected = model.hostID, opened = connections.count
    let oldCredential = try existing.flatMap { try tokens.read($0.id) }
    let calls = await pairing.calls
    let isRepair = [.pairCancelRepair, .pairForgetLate, .pairForgetDuringRestore].contains(scenario)
    let address = isRepair || scenario == .pairNewFailed ? "a.fixture.invalid" : "new.fixture.invalid"
    if isRepair { await pairing.replaceA() }
    if scenario == .pairNewFailed { await pairing.failA() }
    if scenario == .pairCancelBeforeSave { await pairing.cancelNextPair() }
    let heldPair = [.pairCancelLate, .pairBackgroundLate, .pairForgetLate].contains(scenario)
    if heldPair { await pairing.holdNextPair() }
    let heldSave = [.pairBackgroundEmpty, .pairBackgroundExisting, .pairDuplicate].contains(scenario)
    if heldSave { tokens.holdNextSave() }
    if [.pairCancelEmpty, .pairCancelExisting, .pairCancelRepair, .pairForgetDuringRestore].contains(scenario) { tokens.cancelNextSave() }
    var restoration: CheckedContinuation<Void, Never>?
    if scenario == .pairForgetDuringRestore {
        model.restoreNotificationsAfterPairing = { _ in await withCheckedContinuation { restoration = $0 } }
    }
    let code = Fixture.code(address, fingerprint: 4)
    model.pair(code: code, name: "new synthetic", deviceName: "synthetic")
    guard let pairingTask = task(model, label: "pairTask") else { throw Failure("No production pairing Task") }
    if heldPair {
        try await eventually("Uncancellable pairing response held") { await pairing.waiting }
        if scenario == .pairForgetLate { try await model.removeHost(existing!.id) }
        else if scenario == .pairBackgroundLate { model.setActive(false) }
        else { model.cancelPairing() }
        await pairing.releasePair()
    }
    if heldSave {
        try await eventually("Synchronous credential save held") { tokens.waiting }
        if scenario == .pairDuplicate { model.pair(code: code, name: "duplicate", deviceName: "synthetic") }
        else { model.setActive(false) }
        tokens.releaseSave()
    }
    if scenario == .pairForgetDuringRestore {
        try await eventually("Cancelled re-pair notification restoration held") { restoration != nil }
        try await model.removeHost(existing!.id)
        restoration?.resume()
    }
    await pairingTask.value
    let saved = try await store.hosts()
    let completedCalls = await pairing.calls
    try require(completedCalls == calls + 1, "Pairing retried or duplicate submission reached the pairer")
    if [.pairCancelBeforeSave, .pairCancelLate, .pairBackgroundLate, .pairNewFailed].contains(scenario) {
        try require(saved.isEmpty && model.hosts.isEmpty && model.hostID == nil && model.pairedHostID == nil &&
                    connections.count == 0, "Uncommitted pairing changed hosts, selection or connections")
        try require(scenario == .pairNewFailed ? model.pairingProblem == "Synthetic pairing failed." : model.pairingProblem == nil,
                    "Failed/cancelled pairing reported the wrong outcome")
        print("PASS \(scenario.rawValue): no host/token committed; no selection, connection or retry")
        return
    }
    if [.pairForgetLate, .pairForgetDuringRestore].contains(scenario) {
        print("OBSERVED \(scenario.rawValue): persisted=\(saved.count), visible=\(model.hosts.count), selected=\(model.hostID?.uuidString ?? "nil")")
        try require(saved.isEmpty && model.hosts.isEmpty && model.hostID == nil && model.pairedHostID == nil &&
                    (try tokens.read(existing!.id)) == nil,
                    "Late pairing revived a forgotten host or credential")
        print("PASS \(scenario.rawValue): late pairing/restoration cannot revive forgotten host/token")
        return
    }
    guard let added = saved.first(where: { $0.address == address }) else { throw Failure("Fixture did not commit the host") }
    let credential = try await store.credential(for: added)
    if scenario == .pairDuplicate {
        try await eventually("Single successful pairing connected") { model.status.isConnected }
        try require(saved.count == 1 && model.hosts == saved && model.hostID == added.id && model.pairedHostID == added.id &&
                    connections.count(for: added.id) == 1, "Duplicate pairing changed success or created extra hosts/connections")
        print("PASS pairDuplicate: one exchange, one committed host, one selection and one connection")
        return
    }
    try require(pairingTask.isCancelled && model.hostID == selected && model.pairedHostID == nil &&
                model.pairingProblem == nil && connections.count == opened,
                "Cancellation changed selection, reported success/error, or connected the new host")
    if scenario == .pairCancelRepair {
        try require(added.id == existing?.id && added.deviceID == "fixture-A-v2" &&
                    credential.token != oldCredential, "Cancelled committed re-pair lost the replacement credential")
    } else if let existing {
        try require(try tokens.read(existing.id) == oldCredential, "Cancellation changed the existing token")
    }
    let visibleBeforeForeground = model.hosts == saved
    model.setActive(false)
    model.setActive(true)
    if existing != nil { try await eventually("Original selection reconnected") { model.status.isConnected } }
    print("OBSERVED \(scenario.rawValue): persisted=\(saved.count), visible=\(model.hosts.count), selectedPreserved=\(model.hostID == selected), newHostConnections=\(isRepair ? 0 : connections.count(for: added.id))")
    try require(visibleBeforeForeground && model.hosts == saved,
                "Committed host missing from AppModel hosts after cancellation and foreground")
    try require(model.hostID == selected && model.pairedHostID == nil &&
                (isRepair || connections.count(for: added.id) == 0),
                "Foreground selected or connected the cancelled pairing")
    print("PASS \(scenario.rawValue): committed hosts visible; cancellation/foreground preserve selection, credentials and connection ownership")
}

private final class ConnectionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [UUID] = []
    func record(_ id: UUID) { lock.lock(); defer { lock.unlock() }; opened.append(id) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return opened.count }
    func count(for id: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return opened.filter { $0 == id }.count }
}

@main private struct NavigationCheck {
    @MainActor static func main() async {
        guard let argument = CommandLine.arguments.dropFirst().first, let scenario = Scenario(rawValue: argument) else { print("FAIL missing scenario"); exit(2) }
        do {
            if scenario.checksPairingLifecycle { try await checkPairingLifecycle(scenario) }
            else { try await check(scenario) }
        }
        catch { print("FAIL \(scenario.rawValue): \(error)"); exit(1) }
    }
}
