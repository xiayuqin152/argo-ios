import ArgoMobileKit
import Foundation
import Glibc

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private let originalCredential = GatewayCredential(device: "fixture-old", token: String(repeating: "a", count: 43))
private let replacementCredential = GatewayCredential(device: "fixture-new", token: String(repeating: "b", count: 43))

private actor PairingBoundary {
    enum Plan { case success(GatewayCredential), expired, suspended }
    private var plan = Plan.success(originalCredential)
    private var continuations: [CheckedContinuation<GatewayCredential, Never>] = []
    private(set) var calls = 0
    var suspended: Bool { !continuations.isEmpty }
    var suspendedCount: Int { continuations.count }
    func set(_ plan: Plan) { self.plan = plan }
    func pair() async throws -> GatewayCredential {
        calls += 1
        switch plan {
        case .success(let credential): return credential
        case .expired: throw GatewayError.pairingRejected("synthetic expired code")
        case .suspended: return await withCheckedContinuation { continuations.append($0) }
        }
    }
    func release(_ credential: GatewayCredential = replacementCredential) {
        if !continuations.isEmpty { continuations.removeFirst().resume(returning: credential) }
    }
}

private actor NotificationBoundary {
    enum Revocation { case token, open }
    struct Write: Sendable {
        let method: String
        let credential: GatewayCredential
        let receipt: String
    }
    private(set) var writes: [Write] = []
    private var holdPUT = false
    private var holdDELETE = false
    private var put: CheckedContinuation<HTTPResponse, Never>?
    private var delete: CheckedContinuation<HTTPResponse, Never>?
    private var putResponse: HTTPResponse?
    private var deleteResponse: HTTPResponse?
    private var failPUT = false
    private var failDELETE = false
    private var revocation: Revocation?
    private(set) var rejectedCredentials: [GatewayCredential] = []
    var holdingPUT: Bool { put != nil }
    var holdingDELETE: Bool { delete != nil }
    func pausePUT() { holdPUT = true }
    func pauseDELETE() { holdDELETE = true }
    func fail(put: Bool, delete: Bool = false) { failPUT = put; failDELETE = delete }
    func revokeOriginal(at point: Revocation) { revocation = point }
    func loomdToken(for credential: GatewayCredential) throws -> String {
        if credential == originalCredential, revocation == .token {
            rejectedCredentials.append(credential)
            throw TransportFailure.open(.unauthorized("synthetic revoked pairing"))
        }
        return String(repeating: "c", count: 64)
    }
    func releasePUT() { if let response = putResponse { put?.resume(returning: response) }; put = nil; putResponse = nil }
    func releaseDELETE() { if let response = deleteResponse { delete?.resume(returning: response) }; delete = nil; deleteResponse = nil }

    private func json(_ body: Any) throws -> HTTPResponse {
        .init(status: 200, headers: [("Content-Type", "application/json")],
              body: try JSONSerialization.data(withJSONObject: body), reusable: true)
    }
    func send(_ request: HTTPRequest, host: LoomHost, credential: GatewayCredential) async throws -> HTTPResponse {
        if request.target == "/api/notify/device" {
            let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.0.lowercased(), $0.1) })
            guard host.deviceID == credential.device,
                  headers["x-argo-device-id"] == credential.device,
                  headers["x-argo-device-token"] == credential.token else {
                throw CheckFailure("Mixed host and credential in notification request")
            }
            let receipt = "fixture-registration-\(writes.count)"
            writes.append(Write(method: request.method, credential: credential, receipt: receipt))
            if credential == originalCredential, revocation == .open {
                rejectedCredentials.append(credential)
                throw TransportFailure.open(.unauthorized("synthetic revoked pairing"))
            }
            if request.method == "PUT" {
                if failPUT { throw TransportFailure.noReply("synthetic offline registration") }
                let response = try json(["enabled": true, "hostID": host.id.uuidString,
                                         "deviceID": credential.device, "registrationID": receipt])
                if holdPUT {
                    holdPUT = false; putResponse = response
                    return await withCheckedContinuation { put = $0 }
                }
                return response
            }
            guard request.method == "DELETE" else { throw CheckFailure("Unexpected notification write") }
            if failDELETE { throw TransportFailure.noReply("synthetic offline unregistration") }
            let response = try json(["enabled": false])
            if holdDELETE {
                holdDELETE = false; deleteResponse = response
                return await withCheckedContinuation { delete = $0 }
            }
            return response
        }
        if request.target == "/api/health" { return try json(["api": 1, "version": "fixture"]) }
        if ["/api/projects", "/api/workspaces", "/api/agents/profiles"].contains(request.target) { return try json([]) }
        throw CheckFailure("Unexpected request outside pairing/notification scope")
    }
}

private struct FixtureTransport: ArgoHTTPTransport {
    let boundary: NotificationBoundary
    let host: LoomHost
    let credential: GatewayCredential
    func loomdToken() async throws -> String { try await boundary.loomdToken(for: credential) }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        try await boundary.send(request, host: host, credential: credential)
    }
    func close() async {}
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}

@MainActor private final class Fixture {
    let pairing = PairingBoundary()
    let network = NotificationBoundary()
    let store: ArgoHostStore
    let directory: URL
    let model: AppModel
    var secondModel: AppModel?
    var host: LoomHost!
    var notifications: PhoneNotifications { .shared }

    static func code(fingerprint: UInt8 = 1) -> String {
        "argo1:fixture.invalid:6779:\(Base64URL.encode(Data(repeating: fingerprint, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))"
    }

    init() throws {
        directory = URL(fileURLWithPath: "research/repair-notifications/build/fixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pairing = pairing, network = network
        store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
            try await pairing.pair()
        }
        let factory: AppModel.ConnectionFactory = { host, credential in
            ArgoConnection(host: host, transport: FixtureTransport(boundary: network, host: host, credential: credential))
        }
        model = AppModel(store: store, pendingCreations: MemoryCreations(), makeConnection: factory)
        // Notification singleton is first accessed after synthetic intent is installed.
    }

    func start(enabled: Bool) async throws {
        host = try await store.pair(code: Self.code(), deviceName: "fixture")
        if enabled {
            NotificationTestPlatform.defaults.set([host.id.uuidString], forKey: "argo.push.enabledHosts.v1")
        }
        let network = network
        notifications.attach(store: store) { host, credential in
            ArgoConnection(host: host, transport: FixtureTransport(boundary: network, host: host, credential: credential))
        }
        notifications.hostsChanged([host])
        await notifications.refresh()
        notifications.didRegister(Data(repeating: 3, count: 32))
        await notifications.refresh()
        if enabled { try await eventually("Initial registration did not finish") { self.notifications.registrations[self.host.id] != nil } }
        bindNotifications(to: model)
        await model.loadHosts()
        model.setActive(true)
        try await eventually("Model did not connect") { self.model.status.isConnected }
        await pairing.set(.success(replacementCredential))
    }

    func cleanup() async {
        model.setActive(false)
        secondModel?.setActive(false)
        await network.releasePUT()
        await network.releaseDELETE()
        await pairing.release()
        await pairing.release()
        try? FileManager.default.removeItem(at: directory)
    }

    func pair() { model.pair(code: Self.code(fingerprint: 4), name: "fixture", deviceName: "fixture") }
    func finished() async throws { try await eventually("Pairing did not finish") { !self.model.pairing } }
    func requireIntent() throws {
        guard notifications.enabledHosts.contains(host.id),
              NotificationTestPlatform.defaults.stringArray(forKey: "argo.push.enabledHosts.v1")?.contains(host.id.uuidString) == true else {
            throw CheckFailure("ALERT INTENT LOST after re-pairing")
        }
    }
    func requireRegistration(_ expected: GatewayCredential) async throws {
        try requireIntent()
        guard notifications.registrations[host.id]?.deviceID == expected.device else {
            throw CheckFailure("Registration was not restored for the persisted credential")
        }
        guard let current = try await store.hosts().first,
              try await store.credential(for: current) == expected else { throw CheckFailure("Unexpected persisted credential") }
        let writes = await network.writes
        guard let last = writes.last, last.method == "PUT", last.credential == expected else {
            throw CheckFailure("Restore did not PUT the exact persisted credential")
        }
    }
}

@MainActor private func eventually(_ message: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CheckFailure(message)
}

@MainActor private func run(_ name: String, _ f: Fixture) async throws {
    try await f.start(enabled: name != "disabled")
    switch name {
    case "success", "expired", "restoreOffline", "expiredRestoreOffline":
        let expired = name == "expired" || name == "expiredRestoreOffline"
        let offline = name == "restoreOffline" || name == "expiredRestoreOffline"
        if expired { await f.pairing.set(.expired) }
        if offline { await f.network.fail(put: true) }
        f.pair()
        try await f.finished()
        try f.requireIntent()
        guard (f.model.pairingProblem != nil) == expired else { throw CheckFailure("Pairing error visibility changed") }
        if offline {
            guard f.notifications.problem(for: f.host.id) != nil, f.notifications.registrations[f.host.id] == nil else {
                throw CheckFailure("Failed restoration did not preserve visible error and pending intent")
            }
            await f.network.fail(put: false)
            await f.notifications.refresh()
        }
        try await f.requireRegistration(expired ? originalCredential : replacementCredential)
        guard f.notifications.problem(for: f.host.id) == nil else { throw CheckFailure("Successful retry retained stale notification error") }
    case "cancelPair":
        await f.pairing.set(.suspended)
        f.pair()
        try await eventually("Pair handshake did not suspend") { await f.pairing.suspended }
        f.model.cancelPairing()
        await f.pairing.release()
        try await f.finished()
        try await f.requireRegistration(originalCredential)
        guard f.model.pairedHostID == nil else { throw CheckFailure("Cancelled pairing navigated") }
    case "cancelDelete":
        await f.network.pauseDELETE()
        f.pair()
        try await eventually("Old registration DELETE did not suspend") { await f.network.holdingDELETE }
        f.model.cancelPairing()
        await f.network.releaseDELETE()
        try await f.finished()
        try await f.requireRegistration(originalCredential)
        guard await f.pairing.calls == 1 else { throw CheckFailure("Cancelled prepare still started pairing") }
    case "disabled":
        f.pair()
        try await f.finished()
        guard !f.notifications.enabledHosts.contains(f.host.id), f.notifications.registrations[f.host.id] == nil,
              await f.network.writes.isEmpty else { throw CheckFailure("Disabled alerts acquired registration intent") }
        guard f.model.pairedHostID == f.host.id else { throw CheckFailure("Disabled-alert host did not re-pair") }
    case "revokedTokenRepair", "revokedOpenRepair", "revokedExpired":
        let expired = name == "revokedExpired"
        await f.network.revokeOriginal(at: name == "revokedTokenRepair" ? .token : .open)
        if expired { await f.pairing.set(.expired) }
        f.pair()
        try await f.finished()
        try f.requireIntent()
        guard await f.pairing.calls == 2 else { throw CheckFailure("Revoked old credential blocked or replayed re-pairing") }
        let rejected = await f.network.rejectedCredentials
        guard rejected.count == (expired ? 2 : 1), rejected.allSatisfy({ $0 == originalCredential }) else {
            throw CheckFailure("Old credential did not follow the expected gateway authorization path")
        }
        if expired {
            guard f.model.pairingProblem != nil, f.notifications.problem(for: f.host.id) != nil,
                  f.notifications.registrations[f.host.id] == nil,
                  let persisted = try await f.store.hosts().first,
                  try await f.store.credential(for: persisted) == originalCredential else {
                throw CheckFailure("Rejected re-pair lost intent, credential or visible restoration auth error")
            }
        } else {
            try await f.requireRegistration(replacementCredential)
            guard f.model.pairingProblem == nil, f.notifications.problem(for: f.host.id) == nil,
                  f.model.pairedHostID == f.host.id else {
                throw CheckFailure("Successful revoked-credential re-pair retained stale failure state")
            }
        }
    case "deleteOffline":
        await f.network.fail(put: true, delete: true)
        f.pair()
        try await f.finished()
        try f.requireIntent()
        guard f.model.pairingProblem != nil, f.notifications.problem(for: f.host.id) != nil,
              await f.pairing.calls == 1 else { throw CheckFailure("Failed DELETE was swallowed or pairing continued") }
        await f.network.fail(put: false)
        await f.notifications.refresh()
        try await f.requireRegistration(originalCredential)
    case "latePUT":
        let oldReceipt = f.notifications.registrations[f.host.id]
        await f.network.pausePUT()
        let refresh = Task { await f.notifications.refresh() }
        try await eventually("Old registration PUT did not suspend") { await f.network.holdingPUT }
        await f.network.pauseDELETE()
        f.pair()
        try await eventually("Pairing did not enter notification preparation") { NotificationTestPlatform.preparationBegan }
        await f.network.releasePUT()
        try await eventually("Re-pair did not reach DELETE") { await f.network.holdingDELETE }
        guard f.notifications.registrations[f.host.id] == oldReceipt else {
            throw CheckFailure("STALE RECEIPT accepted from a PUT superseded by re-pairing")
        }
        await f.network.releaseDELETE()
        await refresh.value
        try await f.finished()
        try await f.requireRegistration(replacementCredential)
    case "changedHost", "changedToken":
        let oldReceipt = f.notifications.registrations[f.host.id]
        await f.network.pausePUT()
        let refresh = Task { await f.notifications.refresh() }
        try await eventually("Old registration PUT did not suspend") { await f.network.holdingPUT }
        let next = name == "changedToken" ? GatewayCredential(device: originalCredential.device, token: replacementCredential.token) : replacementCredential
        await f.pairing.set(.success(next))
        let current = try await f.store.pair(code: Fixture.code(fingerprint: name == "changedToken" ? 1 : 4), deviceName: "fixture")
        await f.network.pausePUT()
        f.notifications.hostsChanged([current])
        await f.network.releasePUT()
        await refresh.value
        try await eventually("Current registration PUT did not suspend") { await f.network.holdingPUT }
        guard f.notifications.registrations[f.host.id] == oldReceipt else {
            throw CheckFailure("STALE RECEIPT accepted after persisted host/credential changed")
        }
        try f.requireIntent()
        guard f.notifications.problem(for: f.host.id) != nil else { throw CheckFailure("Credential change was silently ignored") }
        await f.network.releasePUT()
        await f.notifications.refresh()
        try await f.requireRegistration(next)
    case "overlappingPair":
        // Independent app models share the notification registrar and host store.
        // Completing one re-pair must not resume PUT while another still owns it.
        let network = f.network
        let other = AppModel(store: f.store, pendingCreations: MemoryCreations()) { host, credential in
            ArgoConnection(host: host, transport: FixtureTransport(boundary: network, host: host, credential: credential))
        }
        f.secondModel = other
        bindNotifications(to: other)
        await other.loadHosts()
        other.setActive(true)
        try await eventually("Second model did not connect") { other.status.isConnected }
        await f.pairing.set(.suspended)
        f.pair()
        try await eventually("First re-pair did not suspend") { await f.pairing.suspendedCount == 1 }
        other.pair(code: Fixture.code(fingerprint: 5), name: "fixture", deviceName: "fixture")
        try await eventually("Second re-pair did not suspend") { await f.pairing.suspendedCount == 2 }
        await f.pairing.release()
        try await f.finished()
        try f.requireIntent()
        guard other.pairing, f.notifications.registrations[f.host.id] == nil,
              await f.network.writes.last?.method == "DELETE" else {
            throw CheckFailure("Registration resumed before all re-pair owners finished")
        }
        let final = GatewayCredential(device: "fixture-last", token: String(repeating: "d", count: 43))
        await f.pairing.release(final)
        try await eventually("Second re-pair did not finish") { !other.pairing }
        try await f.requireRegistration(final)
    case "forget":
        try await f.model.removeHost(f.host.id)
        guard !f.notifications.enabledHosts.contains(f.host.id), f.notifications.registrations[f.host.id] == nil,
              try await f.store.hosts().isEmpty else { throw CheckFailure("Real host removal kept notification intent") }
        guard await f.network.writes.last?.method == "DELETE" else { throw CheckFailure("Removal re-registered forgotten host") }
    default: throw CheckFailure("Unknown scenario")
    }
}

@main private struct RepairNotificationsCheck {
    @MainActor static func main() async {
        let name = CommandLine.arguments[1]
        do {
            let fixture = try Fixture()
            do {
                try await run(name, fixture)
                await fixture.cleanup()
                print("PASS \(name)")
            } catch {
                await fixture.cleanup()
                throw error
            }
        } catch {
            print("FAIL \(name): \(error)")
            exit(1)
        }
    }
}
