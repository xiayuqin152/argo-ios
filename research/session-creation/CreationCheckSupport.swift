import ArgoMobileKit
import Foundation

// Storage/type support only. Creation, recovery and transport logic remains
// the production NewSessionState.swift and ArgoMobileKit implementations.
struct SessionKey: Hashable {
    let host: UUID
    let workspace: String
    let run: String
    let terminal: String
}

enum L10n {
    static func text(_ value: String) -> String { value }
    static func error(_ error: Error) -> String { error.localizedDescription }
}

@MainActor
final class MemoryCreationStore: PendingCreationStoring {
    var value: [PendingAgentCreation]
    var saves = 0
    init(_ value: [PendingAgentCreation] = []) { self.value = value }
    func load() throws -> [PendingAgentCreation] { value }
    func save(_ pending: [PendingAgentCreation]) throws { value = pending; saves += 1 }
}

final class ScriptedTransport: ArgoHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse
    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }
    var requests: [HTTPRequest] { locked { recorded } }
    private func locked<R>(_ body: () -> R) -> R { lock.lock(); defer { lock.unlock() }; return body() }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        locked { recorded.append(request) }
        _ = try request.encoded(keepAlive: reuse)
        return try handler(request)
    }
    func close() async {}
}

func jsonResponse(_ status: Int, _ body: String) -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: Data(body.utf8), reusable: true)
}

func fixtureHost() -> LoomHost {
    LoomHost(name: "fixture", address: "127.0.0.1", gatewayPort: 6779,
             fingerprint: Base64URL.encode(Data(repeating: 3, count: 32)), deviceID: "dev123")
}

func fixtureWorkspace(_ id: String = "fixture-ws", cwd: String = "/synthetic/src") throws -> ArgoWorkspace {
    let json = #"{"id":"\#(id)","name":"Fixture","roots":[{"path":"\#(cwd)","missing":false}]}"#
    return try JSONDecoder().decode(ArgoWorkspace.self, from: Data(json.utf8))
}

func fixtureIntent(host: UUID, workspace: String = "fixture-ws", context: String = "ios:new:fixture-old") -> PendingAgentCreation {
    PendingAgentCreation(host: host, workspace: workspace, cwd: "/synthetic/src", profile: "Fixture Claude",
                         engine: "claude", permission: .readonly, context: context, started: Date(timeIntervalSince1970: 1))
}

func terminalJSON(context: String, run: String = "20261115-120000-fixture", cwd: String = "/synthetic/src",
                  profile: String = "Fixture Claude", engine: String = "claude") -> String {
    #"{"id":"fixture-terminal","ws":"fixture-ws","cwd":"\#(cwd)","context":"\#(context)","alive":true,"exitCode":null,"agent":{"run":"\#(run)","profile":"\#(profile)","engine":"\#(engine)","leader":false},"unmanaged":null}"#
}

let profilesJSON = #"[{"name":"Fixture Claude","engine":"claude","available":true,"fixedPermission":null}]"#

func requestJSON(_ request: HTTPRequest) throws -> [String: Any] {
    guard let body = request.body else { throw ProbeFailure.fixture("missing request body") }
    return try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
}

@MainActor
func prepare(_ model: NewSessionModel, host: LoomHost, workspace: ArgoWorkspace,
             connection: ArgoConnection, prompt: String = "first message") async throws {
    model.selectHost(host.id)
    model.loadProfiles(from: connection)
    try await waitUntil { !model.profiles.isEmpty }
    model.draft.cwd = workspace.roots[0].path
    model.draft.profile = "Fixture Claude"
    model.draft.permission = .readonly
    model.draft.prompt = prompt
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ProbeFailure.fixture("timed out waiting for production model")
}

enum ProbeFailure: Error {
    case fixture(String)
    case assertion(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure.assertion(message) }
}
