import ArgoMobileKit
import Foundation

// Executed by ios/scripts/check_notification_unregister.py on Linux. This file
// is excluded from the app target by the existing Verification exclusion.
// Only the factory type and localization are needed by PhoneNotifications.
enum AppModel {
    typealias ConnectionFactory = @Sendable (LoomHost, GatewayCredential) throws -> ArgoConnection
}
enum L10n {
    static func text(_ value: String) -> String { value }
    static func error(_ error: Error) -> String { error.localizedDescription }
}

struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

final class ScriptedTransport: ArgoHTTPTransport, @unchecked Sendable {
    let scenario: String
    private let lock = NSLock()
    private var closes = 0
    private var sends = 0
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sends }
    init(_ scenario: String) { self.scenario = scenario }

    var expected: ArgoClientError? {
        switch scenario {
        case "fingerprint": return .needsPairing(.gateway(.fingerprintChanged))
        case "offline": return .notSent(.gateway(.network("synthetic offline")))
        case "timeout": return .notSent(.gateway(.timeout("synthetic timeout")))
        case "banned": return .notSent(.gateway(.banned("synthetic banned")))
        case "device-table-unreadable": return .notSent(.gateway(.rejected("synthetic device table I/O")))
        case "http401": return .http(status: 401, message: "synthetic failure", code: nil)
        case "http403": return .http(status: 403, message: "synthetic failure", code: nil)
        case "http503": return .http(status: 503, message: "synthetic failure", code: nil)
        default: return nil
        }
    }

    func loomdToken() async throws -> String {
        switch scenario {
        case "revoked-token": throw TransportFailure.open(.unauthorized("synthetic revoked"))
        case "fingerprint": throw TransportFailure.open(.fingerprintChanged)
        case "offline": throw TransportFailure.open(.network("synthetic offline"))
        case "timeout": throw TransportFailure.open(.timeout("synthetic timeout"))
        case "banned": throw TransportFailure.open(.banned("synthetic banned"))
        case "device-table-unreadable": throw TransportFailure.open(.rejected("synthetic device table I/O"))
        case "cancelled": throw CancellationError()
        default: return String(repeating: "a", count: 64)
        }
    }

    private func recordSend() { lock.lock(); sends += 1; lock.unlock() }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        recordSend()
        try require(request.method == "DELETE" && request.target == "/api/notify/device" && !reuse,
                    "unregistration must use one non-reused DELETE")
        if scenario == "revoked-open" { throw TransportFailure.open(.unauthorized("synthetic revoked")) }
        let status = Int(scenario.dropFirst(4)) ?? 200
        return HTTPResponse(status: status, headers: [],
                            body: Data((status == 200 ? #"{"enabled":false}"# : #"{"error":"synthetic failure"}"#).utf8),
                            reusable: false)
    }
    private func recordClose() { lock.lock(); closes += 1; lock.unlock() }
    func close() async { recordClose() }
}

@main struct NotificationUnregisterCheck {
    @MainActor static func run(_ scenario: String, _ action: String) async throws {
        let revoked = try GatewayReply.parse(Data(#"{"ok":false,"code":"auth","error":"synthetic revoked"}"#.utf8)).failure
        try require(revoked == .unauthorized("synthetic revoked"), "gateway auth must preserve its exact typed error")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notification-unregister-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = InMemoryDeviceTokens()
        let fingerprint = Base64URL.encode(Data(repeating: 7, count: 32))
        let secret = Base64URL.encode(Data(repeating: 8, count: 16))
        let code = "argo1:synthetic.example:6779:\(fingerprint):\(secret)"
        let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: tokens) { _, name in
            GatewayCredential(device: name, token: String(repeating: "b", count: 43))
        }
        let host = try await store.pair(code: code, deviceName: "oldDevice")
        let other = UUID()
        let receipt = ArgoPushRegistration(enabled: true, hostID: host.id, deviceID: host.deviceID, registrationID: "registration1")
        let otherReceipt = ArgoPushRegistration(enabled: true, hostID: other, deviceID: "otherDevice", registrationID: "registration2")
        let enabledKey = "argo.push.enabledHosts.v1", registrationsKey = "argo.push.registrations.v1"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: enabledKey); defaults.removeObject(forKey: registrationsKey) }
        defaults.set([host.id.uuidString, other.uuidString], forKey: enabledKey)
        defaults.set(try JSONEncoder().encode([host.id: receipt, other: otherReceipt]), forKey: registrationsKey)
        let notifications = PhoneNotifications.shared
        let transport = ScriptedTransport(scenario)
        let clients = ClientRecorder()
        notifications.attach(store: store) { host, _ in
            let client = ArgoConnection(host: host, transport: transport)
            clients.record(client)
            return client
        }
        notifications.hostsChanged([host])
        if scenario == "missing-token" { tokens.delete(host.id) }
        var failure: Error?
        do { try await notifications.forgetHost(host.id) }
        catch { failure = error }
        let shouldSucceed = ["success", "revoked-token", "revoked-open"].contains(scenario)
        if shouldSucceed {
            try require(failure == nil, "revoked/successful unregister blocked \(action): \(String(describing: failure))")
            try require(!notifications.enabledHosts.contains(host.id) && notifications.registrations[host.id] == nil,
                        "local notification registration was retained")
            let saved = try JSONDecoder().decode([UUID: ArgoPushRegistration].self, from: defaults.data(forKey: registrationsKey)!)
            try require(saved[host.id] == nil && saved[other] == otherReceipt, "persisted registration cleanup is not host-scoped")
            if action == "remove" {
                try await store.remove(host.id)
                let hosts = try await store.hosts()
                try require(hosts.isEmpty && tokens.read(host.id) == nil, "host removal did not complete")
            } else {
                let repaired = try await store.pair(code: code, deviceName: "newDevice")
                let credential = try await store.credential(for: repaired)
                try require(repaired.id == host.id && credential.device == "newDevice", "re-pair did not complete")
            }
        } else {
            try require(failure != nil, "non-revocation failure was swallowed")
            if let expected = transport.expected {
                try require(failure as? ArgoClientError == expected, "typed failure was changed: \(String(describing: failure))")
            } else if scenario == "cancelled" {
                try require(failure is CancellationError, "cancellation was changed")
            } else if scenario == "missing-token" {
                guard case .needsPairing(.message) = failure as? ArgoClientError else { throw Failure(description: "missing local token was changed") }
            }
            let hosts = try await store.hosts()
            try require(hosts == [host] && notifications.enabledHosts.contains(host.id) && notifications.registrations[host.id] == receipt,
                        "retry state was discarded on failure")
            if scenario != "missing-token" { try require(tokens.read(host.id) != nil, "credential was deleted on failure") }
        }
        try require(notifications.enabledHosts.contains(other) && notifications.registrations[other] == otherReceipt,
                    "another host was changed")
        try require(transport.closeCount == (scenario == "missing-token" ? 0 : 1), "temporary connection was not closed exactly once")
        try require(transport.sendCount <= 1, "unregistration was retried")
        for client in clients.snapshot { try require(await client.isClosed, "temporary connection remains open") }
    }

    static func main() async {
        let args = CommandLine.arguments
        do {
            try await run(args[1], args[2])
            print("PASS \(args[1]) \(args[2])")
        } catch {
            print("FAIL \(args[1]) \(args[2]): \(error)")
            exit(1)
        }
    }
}

final class ClientRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [ArgoConnection] = []
    func record(_ client: ArgoConnection) { lock.lock(); clients.append(client); lock.unlock() }
    var snapshot: [ArgoConnection] { lock.lock(); defer { lock.unlock() }; return clients }
}
