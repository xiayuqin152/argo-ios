import ArgoMobileKit
import Foundation
import Glibc

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Synthetic responses only. A continuation holds the readback's list GET
/// across real AppModel navigation; it deliberately finishes after cancellation.
private actor ReadbackTransport: ArgoHTTPTransport {
    private var holdNextList = false
    private var heldList: CheckedContinuation<HTTPResponse, Never>?
    private var staleList: HTTPResponse?
    private var revision = 0
    private var lists: [String: Int] = [:]
    private var writes: [String] = []

    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async { releaseList() }
    func holdList() { holdNextList = true }
    var isHolding: Bool { heldList != nil }
    func listCount(_ workspace: String) -> Int { lists[workspace, default: 0] }
    var writePaths: [String] { writes }
    func advance() { revision += 1 }
    func releaseList() {
        let continuation = heldList
        heldList = nil
        if let response = staleList { continuation?.resume(returning: response) }
        staleList = nil
    }

    private func json(_ value: Any) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "application/json")],
                     body: try JSONSerialization.data(withJSONObject: value), reusable: true)
    }

    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        let url = URLComponents(string: "http://fixture.invalid" + request.target)!
        let path = url.path
        let ws = url.queryItems?.first { $0.name == "ws" }?.value ?? "w1"
        if request.method == "POST" {
            writes.append(path)
            if path.hasSuffix("/interrupt") {
                return try json(["run": "r1", "ws": "w1", "sent": true, "stopped": true,
                                 "state": "done", "interrupted": true, "held": 0])
            }
            if path.hasSuffix("/model") {
                return try json(["switched": true, "resume": ["sent": true]])
            }
            throw CheckFailure("Unexpected POST: \(path)")
        }
        if path == "/api/health" { return try json(["api": 1, "version": "fixture"]) }
        if path == "/api/projects" || path == "/api/agents/profiles" { return try json([]) }
        if path == "/api/workspaces" { return try json([["id": "w1"], ["id": "w2"]]) }
        if path == "/api/agents" {
            lists[ws, default: 0] += 1
            let response = try json((1...2).map { index in
                ["run": "r\(index)", "terminal": "t\(index)", "ws": ws, "engine": "claude",
                 "status": "active", "state": "working", "title": "\(ws)-revision-\(revision)"]
            })
            if holdNextList {
                holdNextList = false
                staleList = response
                return await withCheckedContinuation { heldList = $0 }
            }
            return response
        }
        if path == "/api/terminals" {
            return try json((1...2).map { index in
                ["id": "t\(index)", "ws": ws, "alive": true,
                 "agent": ["run": "r\(index)", "engine": "claude"]] as [String: Any]
            })
        }
        if path.hasSuffix("/chat") {
            let terminal = path.split(separator: "/")[2]
            let run = terminal == "t1" ? "r1" : "r2"
            return try json(["bounded": true, "byteLimit": 1_048_576,
                             "identity": ["run": run, "engine": "claude", "session": "native-\(run)"],
                             "items": [], "start": "0:0", "end": "0:0", "size": 0,
                             "older": false, "newer": false])
        }
        if path.hasSuffix("/queue") {
            return try json(["bounded": true, "byteLimit": 8_388_608,
                             "run": String(path.split(separator: "/")[2]), "items": []])
        }
        if path == "/api/agents/r1" || path == "/api/agents/r2" {
            return try json(["run": String(path.split(separator: "/").last!), "asks": []])
        }
        throw CheckFailure("Unexpected GET: \(request.target)")
    }
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}

private enum Readback: String, CaseIterable {
    case interrupt, modelRecovery
}

private enum Transition: String, CaseIterable {
    case switchSession, closeConversation, refreshConversation, newerList, switchWorkspace, background, unchanged
}

@main private struct ReadbackPollingCheck {
    @MainActor private static func eventually(_ message: String, timeout: Duration = .seconds(2),
                                              _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(message)
    }

    @MainActor private static func check(_ readback: Readback, _ transition: Transition) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argo-readback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
            GatewayCredential(device: "fixture-device", token: String(repeating: "b", count: 43))
        }
        let fingerprint = Base64URL.encode(Data(repeating: 1, count: 32))
        let secret = Base64URL.encode(Data(repeating: 2, count: 16))
        let host = try await store.pair(code: "argo1:fixture.invalid:6779:\(fingerprint):\(secret)", deviceName: "fixture")
        let transport = ReadbackTransport()
        let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in
            ArgoConnection(host: host, transport: transport)
        }
        defer { model.setActive(false) }
        await model.loadHosts()
        model.setActive(true)
        try await eventually("Initial list did not load") { model.agents.count == 2 && !model.refreshingAgents }
        let key = SessionKey(host: host.id, workspace: "w1", run: "r1", terminal: "t1")
        model.selectSession(key)
        model.showConversation(key, visible: true)
        try await eventually("Initial chat did not load") { model.conversation?.team != nil && model.conversation?.canSendToIdentity == true }
        guard let state = model.conversation else { throw CheckFailure("Missing conversation") }
        state.draft = "synthetic retained draft"

        await transport.holdList()
        switch readback {
        case .interrupt:
            guard model.canInterrupt else { throw CheckFailure("Stop action unavailable") }
            model.interruptCurrentTurn()
        case .modelRecovery:
            // Model recovery's public refresh accepts an existing unknown receipt.
            // Seed only that receipt, then execute its actual production readback.
            let id = UUID()
            state.beginModelRecovery(id, model: "fixture-model")
            state.finishModelRecovery(id, status: .unknown("synthetic missing receipt"))
            model.refreshModelRecovery()
        }
        try await eventually("Readback did not reach controlled GET") { await transport.isHolding }
        await transport.advance()
        switch transition {
        case .switchSession:
            let next = SessionKey(host: host.id, workspace: "w1", run: "r2", terminal: "t2")
            model.selectSession(next)
            model.showConversation(next, visible: true)
        case .closeConversation:
            model.selectSession(nil)
        case .refreshConversation:
            model.refreshConversation()
        case .newerList:
            // Navigate away and back so this same workspace has a newer
            // poller generation before the old readback lands.
            model.selectWorkspace("w2")
            try await eventually("Replacement list did not load") { model.agents.first?.ws == "w2" && !model.refreshingAgents }
            model.selectWorkspace("w1")
            try await eventually("Newer list did not load") { model.agents.first?.title == "w1-revision-1" && !model.refreshingAgents }
        case .switchWorkspace:
            model.selectWorkspace("w2")
            try await eventually("New workspace list did not load") { model.agents.first?.ws == "w2" && !model.refreshingAgents }
        case .background:
            model.setActive(false)
        case .unchanged:
            break
        }
        let beforeW1 = await transport.listCount("w1")
        let beforeW2 = await transport.listCount("w2")
        await transport.releaseList()

        switch transition {
        case .switchSession, .closeConversation, .refreshConversation, .unchanged:
            try await eventually("LIST STALLED: \(readback.rawValue)/\(transition.rawValue) never resumed workspace polling") {
                model.agents.first?.title == "w1-revision-1"
            }
            // Cover the continuing 5-second loop, not only one cleanup GET.
            await transport.advance()
            try await eventually("List resumed once but did not keep polling", timeout: .seconds(6)) {
                model.agents.first?.title == "w1-revision-2"
            }
        case .newerList, .switchWorkspace, .background:
            try await Task.sleep(for: .milliseconds(100))
            let afterW1 = await transport.listCount("w1")
            let afterW2 = await transport.listCount("w2")
            guard afterW1 == beforeW1, afterW2 == beforeW2 else {
                throw CheckFailure("Stale cleanup restarted a replaced/closed workspace list")
            }
            if transition != .background {
                let workspace = transition == .newerList ? "w1" : "w2"
                guard model.agents.first?.title == "\(workspace)-revision-1" else {
                    throw CheckFailure("Stale readback replaced the new workspace cards")
                }
            }
        }
        guard state.draft == "synthetic retained draft" else { throw CheckFailure("Draft ownership changed") }
        if transition == .unchanged {
            if readback == .modelRecovery {
                guard state.modelRecovery?.reviewed == true, state.modelRecovery?.refreshing == false else {
                    throw CheckFailure("Successful recovery lost its native review proof")
                }
            } else {
                guard state.interruptStatus == .stopped, !state.isInterruptBusy else {
                    throw CheckFailure("Successful stop did not finish readback")
                }
            }
        }
        let writes = await transport.writePaths
        let expected = readback == .interrupt ? ["/api/agents/r1/interrupt"] : []
        guard writes == expected else { throw CheckFailure("Readback replayed or manufactured a write: \(writes)") }
    }

    @MainActor static func main() async {
        var failures = 0
        for readback in Readback.allCases {
            for transition in Transition.allCases {
                let name = "\(readback.rawValue)/\(transition.rawValue)"
                do {
                    try await check(readback, transition)
                    print("PASS \(name)")
                } catch {
                    failures += 1
                    print("FAIL \(name): \(error)")
                }
            }
        }
        let total = Readback.allCases.count * Transition.allCases.count
        print("Readback polling: \(total - failures)/\(total) passed")
        if failures > 0 { exit(1) }
    }
}
