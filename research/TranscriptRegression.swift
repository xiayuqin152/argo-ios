import Foundation
import ArgoMobileKit

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@MainActor private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CheckFailure(description: "Timed out: " + message)
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}

private actor TranscriptHost: ArgoHTTPTransport {
    enum Phase { case original, restarted, otherOwner, newSession, waiting, gone }
    let manual: Bool
    var phase = Phase.original
    var requests: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = false
    var isHolding: Bool { held != nil }

    init(manual: Bool) { self.manual = manual }
    func setPhase(_ value: Phase) { phase = value }
    func holdNextChat() { holdNext = true }
    func releaseChat() { held?.resume(); held = nil }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async {}

    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        requests.append(request.target)
        guard request.method == "GET" else { throw CheckFailure(description: "Unexpected write: " + request.method) }
        let url = URLComponents(string: "http://fixture.invalid" + request.target)!
        switch url.path {
        case "/api/health": return .json(200, Fixture.health)
        case "/api/projects": return .json(200, "[]")
        case "/api/workspaces": return .json(200, #"[{"id":"w1","name":"Fixture","cwd":"/fixture"}]"#)
        case "/api/agents": return .json(200, manual ? "[]" : #"[{"run":"20261115-101010-abcdef01","terminal":"t1","ws":"w1","engine":"claude","state":"working"}]"#)
        case "/api/terminals":
            let owner = manual ? #""unmanaged":{"engine":"claude","state":"working"}"# : #""agent":{"run":"20261115-101010-abcdef01","engine":"claude"}"#
            return .json(200, "[{\"id\":\"t1\",\"ws\":\"w1\",\"alive\":true," + owner + "}]")
        case "/api/agents/20261115-101010-abcdef01": return .json(200, Fixture.team)
        case "/api/agents/20261115-101010-abcdef01/queue": return .json(200, #"{"run":"20261115-101010-abcdef01","items":[],"later":[]}"#)
        case "/api/terminals/t1/chat":
            // Capture before suspension: a cancelled old read can finish after a new read.
            let snapshot = phase
            if holdNext {
                holdNext = false
                await withCheckedContinuation { held = $0 }
            }
            if snapshot == .gone { return .json(404, #"{"error":"terminal gone"}"#) }
            if snapshot == .waiting { return .json(200, #"{"bounded":true,"byteLimit":1048576,"waiting":"native pending","items":[]}"#) }
            let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let session = snapshot == .newSession ? "s2" : "s1"
            if let expected = query["session"], expected != session { return .json(409, #"{"error":"native changed"}"#) }
            let start: Int64 = query["after"] == "400:0" ? 400 : 100
            let items = start == 400 ? "" : Fixture.item("answer", offset: 100, text: "中文 👨‍👩‍👧‍👦 e\u{301}")
            var body = try JSONSerialization.jsonObject(with: Data(Fixture.chat(session: session, start: start, items: items).utf8)) as! [String: Any]
            var identity = body["identity"] as! [String: Any]
            if manual {
                identity.removeValue(forKey: "run")
                identity["pid"] = snapshot == .restarted ? 20 : 10
                identity["start"] = snapshot == .restarted ? "200" : "100"
                identity["started"] = snapshot == .restarted ? "2026-11-15T10:01:00Z" : "2026-11-15T10:00:00Z"
            }
            if snapshot == .otherOwner { identity["run"] = "20261115-111111-bbbbbbbb" }
            body["identity"] = identity
            return HTTPResponse(status: 200, headers: [], body: try JSONSerialization.data(withJSONObject: body), reusable: true)
        default: return .json(200, "[]")
        }
    }
}

@MainActor private func withConversation(manual: Bool = false,
    _ test: (AppModel, ConversationState, TranscriptHost) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("argo-transcript-regression-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ArgoHostStore(fileURL: dir.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
        GatewayCredential(device: "fixture-device", token: Fixture.token)
    }
    _ = try await store.pair(code: Fixture.code(), deviceName: "Synthetic fixture")
    let transport = TranscriptHost(manual: manual)
    let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in
        ArgoConnection(host: host, transport: transport)
    }
    defer { model.setActive(false) }
    await model.loadHosts()
    model.setActive(true)
    try await eventually("connect and list") { model.status.isConnected && !model.agents.isEmpty }
    let key = model.key(for: model.agents[0])!
    model.selectSession(key)
    model.showConversation(key, visible: true)
    let state = model.conversation!
    try await eventually("initial native page") { !state.loading && state.transcript.identity != nil }
    state.draft = "unsent fixture draft"
    try await test(model, state, transport)
}

@main private enum TranscriptRegression {
    @MainActor static func main() async {
        var failures = 0
        func run(_ name: String, _ test: () async throws -> Void) async {
            do { try await test(); print("PASS: " + name) }
            catch { failures += 1; print("FAIL: " + name + ": " + String(describing: error)) }
        }

        await run("around refresh recognizes a restarted manual CLI") {
            try await withConversation(manual: true) { model, state, host in
                state.displayedQuestionIDs.insert("old-question")
                state.followingLatest = false
                await host.setPhase(.restarted)
                model.refreshConversation()
                try await eventually("around completed") { !state.loadingOlder }
                try check(state.sessionNotice != nil, "around replaced the native identity without session-change handling")
                try check(state.displayedQuestionIDs.isEmpty, "old displayed questions survived a native change")
                try check(state.followingLatest, "changed native did not reopen latest")
                try check(state.draft == "unsent fixture draft", "draft was lost")
            }
        }

        for manual in [false, true] {
            for cursor in ["latest", "after", "around"] {
                await run("reject another run under \(manual ? "manual" : "managed") key via \(cursor)") {
                    try await withConversation(manual: manual) { model, state, host in
                        await host.setPhase(.otherOwner)
                        if cursor == "latest" { model.showLatest() }
                        else { state.followingLatest = cursor == "after"; model.refreshConversation() }
                        try await eventually("replacement page handled") {
                            state.problem != nil || state.transcript.identity?.run == "20261115-111111-bbbbbbbb"
                        }
                        try check(state.transcript.identity == nil && state.transcript.isEmpty,
                                  "another owner's transcript was rendered under the selected session")
                        try check(state.draft == "unsent fixture draft", "draft was lost")
                    }
                }
            }
        }

        await run("409 reopens latest without losing the draft") {
            try await withConversation { model, state, host in
                await host.setPhase(.newSession)
                model.refreshConversation()
                try await eventually("new native") { state.transcript.identity?.session == "s2" }
                try check(state.sessionNotice != nil && state.draft == "unsent fixture draft", "409 recovery lost session state")
            }
        }
        await run("waiting clears the old native identity") {
            try await withConversation { model, state, host in
                await host.setPhase(.waiting)
                model.refreshConversation()
                try await eventually("waiting") { state.transcript.waiting != nil }
                try check(state.transcript.identity == nil && state.transcript.isEmpty, "waiting retained old messages")
            }
        }
        await run("reconnect resumes from the retained cursor without duplication or Unicode loss") {
            try await withConversation { model, state, host in
                let items = state.transcript.items
                let previous = await host.requests.count
                model.reconnect()
                try await eventually("reconnected") { model.status.isConnected }
                for _ in 0..<300 {
                    if await host.requests.dropFirst(previous).contains(where: { $0.contains("after=400%3A0") }) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let requests = await host.requests
                try check(requests.dropFirst(previous).contains(where: { $0.contains("after=400%3A0") }), "reconnect did not retain its cursor")
                try check(state.transcript.items == items && items.first?.text == "中文 👨‍👩‍👧‍👦 e\u{301}", "reconnect duplicated or corrupted messages")
            }
        }
        await run("cancelled history response cannot replace the newer latest page") {
            try await withConversation(manual: true) { model, state, host in
                state.followingLatest = false
                await host.holdNextChat()
                model.refreshConversation()
                for _ in 0..<300 {
                    if await host.isHolding { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let held = await host.isHolding
                try check(held, "history read was not held")
                await host.setPhase(.newSession)
                model.showLatest()
                try await eventually("replacement latest") { state.transcript.identity?.session == "s2" }
                await host.releaseChat()
                try await Task.sleep(for: .milliseconds(30))
                try check(state.transcript.identity?.session == "s2", "late cancelled response replaced latest")
            }
        }
        await run("terminal 404 retires the selection") {
            try await withConversation { model, state, host in
                await host.setPhase(.gone)
                model.refreshConversation()
                try await eventually("selection retired") { model.selectedKey == nil }
                try check(state.draft == "unsent fixture draft", "closed terminal discarded its draft")
            }
        }
        print("Checks: \(12 - failures)/12 passed")
        if failures > 0 { exit(1) }
    }
}
