import ArgoMobileKit
import Foundation

@main
struct CreationLifecycleCheck {
    @MainActor static func main() async {
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        if failures > 0 { print("CHECK_FAILED: \(failures) lifecycle checks"); exit(1) }
        print("PASS: all creation lifecycle checks")
    }

    @MainActor static var tests: [(String, () async throws -> Void)] {
        [
            ("double submit and exact launch binding", doubleSubmit),
            ("unknown result, file restart and read-only reconcile", unknownAndRestart),
            ("late result stays with original host and intent", lateResult),
            ("reviewed prompt must not leak into another destination", recoveredPromptIsolation),
            ("start another survives cancel and return", startAnotherPresentation),
            ("switching to pending must not overwrite a new draft", draftPreservation),
        ]
    }

    @MainActor static func doubleSubmit() async throws {
        let host = fixtureHost()
        let workspace = try fixtureWorkspace()
        let transport = ScriptedTransport { request in
            if request.target == "/api/agents/profiles" { return jsonResponse(200, profilesJSON) }
            if request.target == "/api/agents" && request.method == "POST" {
                let body = try requestJSON(request)
                guard let context = body["context"] as? String else { throw ProbeFailure.fixture("missing context") }
                return jsonResponse(200, terminalJSON(context: context))
            }
            throw ProbeFailure.fixture("unexpected \(request.method) \(request.target)")
        }
        let connection = ArgoConnection(host: host, transport: transport)
        let store = MemoryCreationStore()
        let model = NewSessionModel(store: store)
        try await prepare(model, host: host, workspace: workspace, connection: connection)
        var accepted: [PendingAgentCreation] = []
        model.start(host: host.id, workspace: workspace, using: connection) { accepted.append($0) }
        model.start(host: host.id, workspace: workspace, using: connection) { accepted.append($0) }
        try await waitUntil { accepted.count == 1 && !model.creating }
        let posts = transport.requests.filter { $0.target == "/api/agents" && $0.method == "POST" }
        try expect(posts.count == 1, "double tap produced \(posts.count) POSTs")
        let body = try requestJSON(posts[0])
        try expect(body["profile"] as? String == "Fixture Claude" && body["cwd"] as? String == "/synthetic/src" &&
                   body["autonomy"] as? String == "readonly" && body["prompt"] as? String == "first message",
                   "request changed profile/cwd/permission/prompt binding")
        try expect(accepted[0].receipt?.run == "20261115-120000-fixture" && accepted[0].permission == .readonly,
                   "receipt lost original launch binding")
        model.present(host: host.id, workspace: workspace)
        try expect(model.originalPrompt == "first message", "cancel/return lost the in-memory original prompt")
    }

    @MainActor static func unknownAndRestart() async throws {
        let host = fixtureHost()
        let workspace = try fixtureWorkspace()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creation-probe-" + UUID().uuidString)
        let file = directory.appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let postTransport = ScriptedTransport { request in
            if request.target == "/api/agents/profiles" { return jsonResponse(200, profilesJSON) }
            if request.target == "/api/agents" && request.method == "POST" {
                throw TransportFailure.noReply("synthetic lost creation reply")
            }
            throw ProbeFailure.fixture("unexpected \(request.method) \(request.target)")
        }
        let postConnection = ArgoConnection(host: host, transport: postTransport)
        let model = NewSessionModel(store: PendingCreationFile(url: file))
        try await prepare(model, host: host, workspace: workspace, connection: postConnection)
        model.start(host: host.id, workspace: workspace, using: postConnection) { _ in }
        try await waitUntil { !model.creating }
        guard let intent = model.current else { throw ProbeFailure.assertion("unknown result was removed") }
        try expect(intent.receipt == nil && !model.canEdit && model.originalPrompt == "first message",
                   "unknown result did not retain the pending intent and prompt")
        model.present(host: host.id, workspace: workspace)
        try expect(model.current?.context == intent.context && model.originalPrompt == "first message",
                   "cancel/return did not recover the unknown intent")

        let restarted = NewSessionModel(store: PendingCreationFile(url: file))
        restarted.present(host: host.id, workspace: workspace)
        try expect(restarted.current?.receipt == nil && !restarted.canEdit,
                   "restart did not restore unresolved intent as unknown")
        try expect(restarted.draft.prompt.isEmpty && restarted.originalPrompt == nil,
                   "restart unexpectedly persisted the private first message")
        try expect(postTransport.requests.filter { $0.method == "POST" }.count == 1,
                   "restart replayed the creation POST")

        let readTransport = ScriptedTransport { request in
            if request.target.hasPrefix("/api/terminals") {
                return jsonResponse(200, "[" + terminalJSON(context: intent.context) + "]")
            }
            throw ProbeFailure.fixture("unexpected recovery \(request.method) \(request.target)")
        }
        let readConnection = ArgoConnection(host: host, transport: readTransport)
        var accepted: [PendingAgentCreation] = []
        restarted.reconcile(intent, using: readConnection) { accepted.append($0) }
        try await waitUntil { accepted.count == 1 }
        try expect(accepted[0].receipt?.run == "20261115-120000-fixture", "matching terminal did not reconcile")
        try expect(readTransport.requests.allSatisfy { $0.method == "GET" }, "recovery issued a write")
        let third = NewSessionModel(store: PendingCreationFile(url: file))
        third.present(host: host.id, workspace: workspace)
        try expect(third.current?.receipt?.run == "20261115-120000-fixture", "receipt was not durable")
    }

    @MainActor static func lateResult() async throws {
        let host = fixtureHost()
        let other = LoomHost(name: "other", address: "127.0.0.2", gatewayPort: 6779,
                             fingerprint: Base64URL.encode(Data(repeating: 4, count: 32)), deviceID: "dev456")
        let workspace = try fixtureWorkspace()
        let transport = ScriptedTransport { request in
            if request.target == "/api/agents/profiles" { return jsonResponse(200, profilesJSON) }
            if request.target == "/api/agents" && request.method == "POST" {
                let body = try requestJSON(request)
                guard let context = body["context"] as? String else { throw ProbeFailure.fixture("missing context") }
                return jsonResponse(200, terminalJSON(context: context))
            }
            throw ProbeFailure.fixture("unexpected \(request.method) \(request.target)")
        }
        let connection = ArgoConnection(host: host, transport: transport)
        let model = NewSessionModel(store: MemoryCreationStore())
        try await prepare(model, host: host, workspace: workspace, connection: connection)
        var accepted: [PendingAgentCreation] = []
        model.start(host: host.id, workspace: workspace, using: connection) { accepted.append($0) }
        model.selectHost(other.id)
        try await waitUntil { accepted.count == 1 && !model.creating }
        try expect(accepted[0].host == host.id && accepted[0].workspace == workspace.id,
                   "late receipt moved to the newly selected host/workspace")
        try expect(model.currentContext == nil && model.current == nil,
                   "late receipt replaced the new host's current recovery intent")
        try expect(model.pending.contains { $0.host == host.id && $0.receipt != nil },
                   "late receipt was not retained on its original host")
        try expect(transport.requests.filter { $0.method == "POST" }.count == 1, "late result caused a duplicate POST")
        model.present(host: host.id, workspace: workspace)
        try expect(model.current?.receipt?.run == "20261115-120000-fixture" && model.originalPrompt == "first message",
                   "returning to the original host lost the late creation's prompt")
    }

    @MainActor static func makeUnknownModel() async throws -> (LoomHost, ArgoWorkspace, NewSessionModel) {
        let host = fixtureHost()
        let workspace = try fixtureWorkspace()
        let transport = ScriptedTransport { request in
            if request.target == "/api/agents/profiles" { return jsonResponse(200, profilesJSON) }
            if request.target == "/api/agents" && request.method == "POST" {
                throw TransportFailure.noReply("synthetic lost creation reply")
            }
            throw ProbeFailure.fixture("unexpected \(request.method) \(request.target)")
        }
        let connection = ArgoConnection(host: host, transport: transport)
        let model = NewSessionModel(store: MemoryCreationStore())
        try await prepare(model, host: host, workspace: workspace, connection: connection)
        model.start(host: host.id, workspace: workspace, using: connection) { _ in }
        try await waitUntil { !model.creating }
        try expect(model.current?.receipt == nil && model.originalPrompt == "first message",
                   "failed to establish unknown creation fixture")
        return (host, workspace, model)
    }

    @MainActor static func recoveredPromptIsolation() async throws {
        let (host, created, model) = try await makeUnknownModel()
        let other = try fixtureWorkspace("other-ws")
        model.present(host: host.id, workspace: other)
        try expect(created.id != other.id && model.currentContext == nil, "test destination did not change")
        try expect(model.draft.prompt.isEmpty,
                   "reviewed first message became an editable new draft in another workspace")
    }

    @MainActor static func startAnotherPresentation() async throws {
        let (host, workspace, model) = try await makeUnknownModel()
        model.startAnother()
        try expect(model.currentContext == nil && model.draft.prompt.isEmpty, "startAnother did not start a new draft")
        model.present(host: host.id, workspace: workspace)
        try expect(model.currentContext == nil,
                   "cancel/return undid the explicit Start Another choice")
    }

    @MainActor static func draftPreservation() async throws {
        let host = fixtureHost()
        let first = try fixtureWorkspace("first-ws")
        let second = try fixtureWorkspace("second-ws")
        let old = fixtureIntent(host: host.id, workspace: second.id)
        let model = NewSessionModel(store: MemoryCreationStore([old]))
        model.present(host: host.id, workspace: first)
        model.draft.cwd = "/synthetic/src"
        model.draft.profile = "Fixture Claude"
        model.draft.permission = .readonly
        model.draft.prompt = "unsent user draft"
        model.present(host: host.id, workspace: second)
        try expect(model.currentContext == nil, "pending intent displaced an edited new draft")
        try expect(model.draft.prompt == "unsent user draft" && model.draft.profile == "Fixture Claude" &&
                   model.draft.permission == .readonly, "present overwrote the unsent draft")
        model.present(host: host.id, workspace: first)
        try expect(model.draft.prompt == "unsent user draft", "returning did not preserve the unsent prompt")

        let otherHost = LoomHost(name: "other", address: "127.0.0.2", gatewayPort: 6779,
                                 fingerprint: Base64URL.encode(Data(repeating: 4, count: 32)), deviceID: "dev456")
        let otherPending = fixtureIntent(host: otherHost.id, workspace: second.id)
        let hostModel = NewSessionModel(store: MemoryCreationStore([otherPending]))
        hostModel.present(host: host.id, workspace: first)
        hostModel.draft.prompt = "unsent cross-host draft"
        hostModel.selectHost(otherHost.id)
        hostModel.present(host: otherHost.id, workspace: second)
        try expect(hostModel.currentContext == nil && hostModel.draft.prompt == "unsent cross-host draft",
                   "host switching let pending overwrite the unsent prompt")
        hostModel.selectHost(host.id)
        hostModel.present(host: host.id, workspace: first)
        try expect(hostModel.draft.prompt == "unsent cross-host draft", "returning to the original host lost the draft")
    }
}
