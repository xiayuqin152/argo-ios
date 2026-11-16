// Linux integration fixture: real PhoneNotifications and ArgoMobileKit; only OS/HTTP are synthetic.
import ArgoMobileKit
import Foundation

enum AppModel {
    typealias ConnectionFactory = @Sendable (LoomHost, GatewayCredential) throws -> ArgoConnection
}
enum L10n {
    static func text(_ value: String) -> String { value }
    static func error(_ error: Error) -> String { error.localizedDescription }
}
private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

private actor Boundary {
    struct Write: Sendable {
        let method: String
        let host: UUID
        let status: UNAuthorizationStatus
    }
    private(set) var writes: [Write] = []
    private var holdPUT = false, holdDELETE = false
    private var failDELETE = false
    private var put: CheckedContinuation<HTTPResponse, Never>?
    private var delete: CheckedContinuation<HTTPResponse, Never>?
    private var putResponse: HTTPResponse?, deleteResponse: HTTPResponse?
    var holdingPUT: Bool { put != nil }
    var holdingDELETE: Bool { delete != nil }
    func pausePUT() { holdPUT = true }
    func pauseDELETE() { holdDELETE = true }
    func failUnregister(_ value: Bool) { failDELETE = value }
    func releasePUT() { if let r = putResponse { put?.resume(returning: r) }; put = nil; putResponse = nil }
    func releaseDELETE() { if let r = deleteResponse { delete?.resume(returning: r) }; delete = nil; deleteResponse = nil }
    func send(_ request: HTTPRequest, host: LoomHost, credential: GatewayCredential) async throws -> HTTPResponse {
        try require(request.target == "/api/notify/device" && ["PUT", "DELETE"].contains(request.method),
                    "Request left notification scope")
        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.0.lowercased(), $0.1) })
        try require(host.deviceID == credential.device && headers["x-argo-device-id"] == credential.device &&
                    headers["x-argo-device-token"] == credential.token, "Mixed notification host/credential")
        if request.method == "PUT" {
            let body = try request.body.map { try JSONSerialization.jsonObject(with: $0) } as? [String: String]
            try require(body?["token"] == String(repeating: "03", count: 32) && body?["environment"] == "sandbox" &&
                        body?["topic"] == "dev.argo.fixture" && body?["hostID"] == host.id.uuidString,
                        "Registration used another token, host or app identity")
        }
        let status = await MainActor.run { UNUserNotificationCenter.current().status }
        writes.append(.init(method: request.method, host: host.id, status: status))
        if request.method == "DELETE", failDELETE { throw TransportFailure.noReply("synthetic offline unregistration") }
        let body: [String: Any] = request.method == "PUT" ?
            ["enabled": true, "hostID": host.id.uuidString, "deviceID": credential.device,
             "registrationID": "fixture-registration-\(writes.count)"] : ["enabled": false]
        let response = HTTPResponse(status: 200, headers: [], body: try JSONSerialization.data(withJSONObject: body), reusable: true)
        if request.method == "PUT", holdPUT {
            holdPUT = false; putResponse = response
            return await withCheckedContinuation { put = $0 }
        }
        if request.method == "DELETE", holdDELETE {
            holdDELETE = false; deleteResponse = response
            return await withCheckedContinuation { delete = $0 }
        }
        return response
    }
}
private struct Transport: ArgoHTTPTransport {
    let boundary: Boundary
    let host: LoomHost
    let credential: GatewayCredential
    func loomdToken() async throws -> String { String(repeating: "c", count: 64) }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        try await boundary.send(request, host: host, credential: credential)
    }
    func close() async {}
}

@MainActor private func eventually(_ message: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw Failure(description: message)
}

@MainActor private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("permission-" + UUID().uuidString)
    let boundary = Boundary()
    let store: ArgoHostStore
    var hosts: [LoomHost] = []
    var notifications: PhoneNotifications { .shared }
    var center: UNUserNotificationCenter { .current() }
    init() {
        store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, name in
            GatewayCredential(device: name, token: String(repeating: "b", count: 43))
        }
    }
    func start(enabled: Bool = true, count: Int = 2, coldReceipt: Bool = false) async throws {
        for i in 0..<count {
            let code = "argo1:fixture\(i).invalid:6779:\(Base64URL.encode(Data(repeating: 1, count: 32))):\(Base64URL.encode(Data(repeating: 2, count: 16)))"
            hosts.append(try await store.pair(code: code, deviceName: "fixture-\(i)"))
        }
        if enabled { NotificationTestPlatform.defaults.set(hosts.map(\.id.uuidString), forKey: "argo.push.enabledHosts.v1") }
        if coldReceipt {
            let receipt = ArgoPushRegistration(enabled: true, hostID: hosts[0].id, deviceID: hosts[0].deviceID,
                                               registrationID: "fixture-saved-registration")
            NotificationTestPlatform.defaults.set(try JSONEncoder().encode([hosts[0].id: receipt]), forKey: "argo.push.registrations.v1")
        }
        let boundary = boundary
        notifications.attach(store: store) { host, credential in
            ArgoConnection(host: host, transport: Transport(boundary: boundary, host: host, credential: credential))
        }
        notifications.hostsChanged(hosts)
        if coldReceipt { return }
        try await eventually("Host-triggered settings query did not start") { self.center.settingsCalls >= 1 }
        await notifications.refresh()
    }
    func register() async throws {
        notifications.didRegister(Data(repeating: 3, count: 32))
        try await eventually("Initial registrations did not finish") { self.notifications.registrations.count == self.hosts.count }
        // Observe the registrar's real serialization barrier, without changing it.
        guard let last = Mirror(reflecting: notifications).children.first(where: { $0.label == "last" })?.value as? Task<Void, Never> else {
            throw Failure(description: "Missing real registration serialization barrier")
        }
        await last.value
    }
    func route(for receipt: ArgoPushRegistration) throws -> ArgoPushRoute {
        let body: [String: Any] = ["v": 1, "hostID": receipt.hostID.uuidString, "deviceID": receipt.deviceID,
                                  "registrationID": receipt.registrationID, "workspace": "fixture-workspace", "run": "fixture-run",
                                  "event": "agent.done", "eventID": "fixture-event"]
        guard let route = ArgoPushRoute.decode(["argo": body]) else { throw Failure(description: "Invalid synthetic route") }
        return route
    }
    func cleanup() async {
        center.releaseSettings()
        await boundary.releasePUT(); await boundary.releaseDELETE()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private func run(_ name: String, _ f: Fixture) async throws {
    switch name {
    case "deniedDuringPUT":
        try await f.start()
        await f.boundary.pausePUT()
        f.notifications.didRegister(Data(repeating: 3, count: 32))
        try await eventually("PUT did not suspend") { await f.boundary.holdingPUT }
        f.center.status = .denied
        let denied = Task { await f.notifications.refresh() }
        try await eventually("Denied settings did not publish") { f.notifications.authorization == .denied }
        await f.boundary.pauseDELETE()
        await f.boundary.releasePUT()
        try await eventually("Permission cleanup did not reach DELETE") { await f.boundary.holdingDELETE }
        let writes = await f.boundary.writes
        let latePUT = writes.filter { $0.method == "PUT" && $0.status == .denied }.count
        let accepted = f.notifications.registrations.count
        let trusted = try f.notifications.registrations.values.first.map { f.notifications.trusted(try f.route(for: $0)) } ?? false
        print("OBSERVED \(name): authorization=\(f.notifications.authorization), PUT=\(writes.filter { $0.method == "PUT" }.count), PUTwhileDenied=\(latePUT), accepted=\(accepted), trusted=\(trusted)")
        await f.boundary.releaseDELETE(); await denied.value
        try require(latePUT == 0 && accepted == 0 && !trusted, "Denied permission allowed late receipt publication or another host PUT")
        try require(f.notifications.enabledHosts == Set(f.hosts.map(\.id)), "Permission cleanup lost enabled intent")
    case "staleAuthorized", "staleDenied":
        try await f.start()
        try await f.register()
        let oldDenied = name == "staleDenied"
        f.center.status = oldDenied ? .denied : .authorized
        f.center.holdNextSettings = true
        let old = Task { await f.notifications.refresh() }
        try await eventually("Older settings query did not suspend") { f.center.holdingSettings }
        f.center.status = oldDenied ? .authorized : .denied
        await f.notifications.refresh()
        let before = await f.boundary.writes.count
        f.center.releaseSettings(); await old.value
        let writes = await f.boundary.writes
        let late = Array(writes.dropFirst(before))
        print("OBSERVED \(name): OS=\(f.center.status), authorization=\(f.notifications.authorization), latePUT=\(late.filter { $0.method == "PUT" }.count), lateDELETE=\(late.filter { $0.method == "DELETE" }.count), registrations=\(f.notifications.registrations.count)")
        try require(f.notifications.authorization == f.center.status && late.isEmpty, "Older settings snapshot overwrote current permission and synchronized stale state")
    case "enableStaleAuthorized":
        try await f.start(enabled: false, count: 1)
        f.center.holdNextSettings = true
        let enable = Task { await f.notifications.setEnabled(true, host: f.hosts[0]) }
        try await eventually("Enable settings query did not suspend") { f.center.holdingSettings }
        f.center.status = .denied
        await f.notifications.refresh()
        let before = UIApplication.shared.registrations
        f.center.releaseSettings(); await enable.value
        print("OBSERVED \(name): OS=\(f.center.status), authorization=\(f.notifications.authorization), enabled=\(f.notifications.enabledHosts.count), registerCalls=\(UIApplication.shared.registrations-before)")
        try require(f.notifications.authorization == .denied && f.notifications.enabledHosts.isEmpty && UIApplication.shared.registrations == before,
                    "Enable accepted an authorization snapshot superseded by denial")
    case "grantThenDenied", "deniedThenGranted":
        try await f.start(enabled: false, count: 1)
        // The prompt result precedes the separate settings snapshot.
        let allowedNow = name == "deniedThenGranted"
        f.center.granted = !allowedNow
        f.center.status = allowedNow ? .authorized : .denied
        let before = UIApplication.shared.registrations
        await f.notifications.setEnabled(true, host: f.hosts[0])
        print("OBSERVED \(name): authorization=\(f.notifications.authorization), enabled=\(f.notifications.enabledHosts.count), registerCalls=\(UIApplication.shared.registrations-before), problemVisible=\(f.notifications.problem(for:f.hosts[0].id) != nil)")
        if allowedNow {
            try require(f.notifications.authorization == .authorized && f.notifications.enabledHosts.contains(f.hosts[0].id) &&
                        UIApplication.shared.registrations == before + 1 && f.notifications.problem(for:f.hosts[0].id) == nil,
                        "Earlier refusal overrode current allowed settings when enabling alerts")
        } else {
            try require(f.notifications.authorization == .denied && f.notifications.enabledHosts.isEmpty && UIApplication.shared.registrations == before && f.notifications.problem(for:f.hosts[0].id) != nil,
                        "Earlier grant overrode current denied settings when enabling alerts")
        }
    case "deniedDuringDELETE", "undeterminedDuringDELETE", "deniedOffline":
        try await f.start(count: 1)
        try await f.register()
        let receipt = f.notifications.registrations[f.hosts[0].id]!
        let route = try f.route(for: receipt)
        f.notifications.receive(route)
        if name != "deniedOffline" { await f.boundary.pauseDELETE() }
        else { await f.boundary.failUnregister(true) }
        f.center.status = name == "undeterminedDuringDELETE" ? .notDetermined : .denied
        let denied = Task { await f.notifications.refresh() }
        if name != "deniedOffline" {
            try await eventually("DELETE did not suspend") { await f.boundary.holdingDELETE }
        } else { await denied.value }
        let retained = f.notifications.registrations[f.hosts[0].id] == receipt
        let trusted = f.notifications.trusted(route)
        let taken = f.notifications.takeRoute(hosts: f.hosts)
        f.notifications.receive(route)
        let buffered = f.notifications.pendingRoute != nil
        print("OBSERVED \(name): authorization=\(f.notifications.authorization), retainedForCleanup=\(retained), trusted=\(trusted), taken=\(taken != nil), buffered=\(buffered)")
        await f.boundary.releaseDELETE(); await denied.value
        try require(retained && !trusted && taken == nil && !buffered, "Known disallowed permission still admitted a notification while cleanup was pending or offline")
        try require(f.notifications.enabledHosts.contains(f.hosts[0].id), "Denied cleanup discarded alert intent")
        if name == "deniedOffline" {
            try require(f.notifications.problem(for: f.hosts[0].id) != nil, "Offline cleanup hid its retry error")
            await f.boundary.failUnregister(false)
        }
        f.center.status = .authorized
        await f.notifications.refresh()
        guard let current = f.notifications.registrations[f.hosts[0].id] else { throw Failure(description: "Reauthorization did not restore registration") }
        try require(f.notifications.trusted(try f.route(for: current)) && f.notifications.problem(for: f.hosts[0].id) == nil,
                    "Reauthorization did not restore trusted registration and clear errors")
    case "coldReceipt":
        f.center.holdNextSettings = true
        try await f.start(count: 1, coldReceipt: true)
        let receipt = f.notifications.registrations[f.hosts[0].id]!
        let route = try f.route(for: receipt)
        f.notifications.receive(route)
        try require(f.notifications.takeRoute(hosts: f.hosts) == route, "Cold-start route was dropped before the first settings snapshot")
        try await eventually("First settings query did not suspend") { f.center.holdingSettings }
        try require(f.notifications.trusted(route), "Cold receipt lost trust while initial settings were pending")
        f.center.releaseSettings()
        await f.notifications.refresh()
        try require(f.notifications.trusted(route), "Current authorized cold receipt lost trust")
        print("OBSERVED \(name): trustedBeforeSettings=true, trustedAfterSettings=true")
    case "currentAuthorized", "currentProvisional", "currentEphemeral":
        f.center.status = name == "currentProvisional" ? .provisional : (name == "currentEphemeral" ? .ephemeral : .authorized)
        try await f.start()
        try await f.register()
        try require(f.notifications.authorization == f.center.status && f.notifications.registrations.count == f.hosts.count, "Current authorization did not register enabled hosts")
        for receipt in f.notifications.registrations.values { try require(f.notifications.trusted(try f.route(for:receipt)), "Current registration not trusted") }
        let writes = await f.boundary.writes
        try require(writes.count == f.hosts.count && Set(writes.map(\.host)) == Set(f.hosts.map(\.id)), "Registration changed enabled host scope")
        print("OBSERVED \(name): authorization=\(f.notifications.authorization), registrations=\(f.notifications.registrations.count), trusted=true")
    case "enableCurrent":
        try await f.start(enabled: false, count: 1)
        let before = UIApplication.shared.registrations
        await f.notifications.setEnabled(true, host: f.hosts[0])
        let writes = await f.boundary.writes
        try require(f.notifications.enabledHosts.contains(f.hosts[0].id) && writes.isEmpty &&
                    UIApplication.shared.registrations == before + 1 && !f.notifications.busy,
                    "Current enable did not preserve intent while waiting for Apple's token callback")
        try await f.register()
        let receipt = f.notifications.registrations[f.hosts[0].id]!
        try require(f.notifications.trusted(try f.route(for: receipt)), "Current enable did not register after token callback")
        print("OBSERVED \(name): enabled=true, waitedForToken=true, trusted=true")
    case "disableThenRefresh":
        try await f.start()
        try await f.register()
        await f.notifications.setEnabled(false, host: f.hosts[0])
        let before = await f.boundary.writes.count
        await f.notifications.refresh()
        let late = await f.boundary.writes.dropFirst(before)
        try require(!f.notifications.enabledHosts.contains(f.hosts[0].id) && f.notifications.registrations[f.hosts[0].id] == nil &&
                    f.notifications.registrations[f.hosts[1].id] != nil && late.allSatisfy { $0.host == f.hosts[1].id && $0.method == "PUT" },
                    "Refresh re-enabled a disabled host or changed another host")
        print("OBSERVED \(name): disabledHostRegistered=false, otherHostRegistered=true")
    default: throw Failure(description:"Unknown scenario")
    }
}

@main private struct NotificationAuthorizationCheck {
    @MainActor static func main() async {
        let name = CommandLine.arguments[1]
        let f = Fixture()
        do {
            try await run(name, f)
            await f.cleanup()
            print("PASS \(name)")
        } catch {
            await f.cleanup()
            print("FAIL \(name): \(error)")
            exit(1)
        }
    }
}
