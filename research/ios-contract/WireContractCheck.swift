import ArgoMobileKit
import Foundation

// Fixed synthetic payloads checked against b5453cf4b, never live user data.
// Unknown members represent newer server fields; no alternate schema is tried.
enum WireContractCheck {
    static func run() throws {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try decoder.decode(type, from: Data(json.utf8))
        }
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw NSError(domain: "WireContractCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        }
        // agents.go profileView: models are attribution patterns, never a model
        // picker. Required flags remain strict; omitted hints stay optional.
        let profiles = try decode([ArgoAgentProfile].self, #"[{"name":"Fixture Claude","engine":"claude","available":true,"models":["fixture-*"],"sessionHome":"/synthetic/claude"},{"name":"Fixture Codex","engine":"codex","available":true,"source":null,"fixedPermission":null},{"name":"Unavailable","engine":"claude","available":false},{"name":"Hidden","engine":"codex","available":true,"hidden":true},{"name":"Other","engine":"other","available":true}]"#)
        try expect(profiles.map(\.canLaunch) == [true, true, false, false, false], "catalog launch eligibility")
        try expect(profiles[1].source.isEmpty && profiles[1].fixedPermission.isEmpty, "nullable profile hints")
        do {
            _ = try decode(ArgoAgentProfile.self, #"{"name":"Malformed","engine":"codex"}"#)
            throw NSError(domain: "WireContractCheck", code: 2)
        } catch is DecodingError {}
        // agentRequest: only the existing launch fields are encoded. Selection
        // uses the exact catalog name; model/effort follow the chosen CLI.
        let request = ArgoCreateAgentRequest(workspace: "fixture-ws", cwd: "/synthetic/src", profile: profiles[0].name,
                                             context: "ios:new:fixture", autonomy: .workspaceShell, prompt: "检查代码\n保留换行")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        try expect(Set(json.keys) == Set(["ws", "cwd", "profile", "context", "autonomy", "prompt", "cols", "rows", "leader"]), "creation wire keys")
        try expect(json["profile"] as? String == "Fixture Claude" && json["autonomy"] as? String == "workspace-shell" && json["leader"] as? Bool == false && json["prompt"] as? String == "检查代码\n保留换行", "creation selections and message")
        // terminals.go terminalAgent always emits leader:false for ordinary
        // launches; creation/adoption uses current ownership, never endedAgent.
        let terminal = try decode(ArgoTerminalView.self, #"{"id":"fixture-terminal","ws":"fixture-ws","cwd":"/synthetic/src","context":"ios:new:fixture","alive":true,"exitCode":null,"agent":{"run":"20261115-120000-fixture","profile":"Fixture Claude","engine":"claude","leader":false},"unmanaged":null}"#)
        try expect(terminal.matches(workspace: request.ws, cwd: request.cwd, profile: request.profile, context: request.context), "exact launch receipt")
        try expect(!terminal.matches(workspace: request.ws, cwd: request.cwd, profile: request.profile, context: "another-intent"), "foreign intent refused")
        let ended = try decode(ArgoTerminalView.self, #"{"id":"fixture-terminal","alive":true,"endedAgent":{"run":"20261115-120000-fixture","profile":"Fixture Claude","engine":"claude","leader":false}}"#)
        try expect(ended.agent == nil && !ended.matches(workspace: request.ws, cwd: request.cwd, profile: request.profile, context: request.context), "ended ownership ignored")
        // agent_view.go: null Go slices and unknown member/model fields decode;
        // detail tasks remain an array and list-card tasks remain a count.
        let card = try decode(ArgoAgentCard.self, #"{"run":"20261115-120000-fixture","waitingIDs":null,"ask":null,"plan":null,"tasks":0,"members":[{"id":"task:fixture","task":{"model":"fixture-model"},"usage":{"model":"observed-model"}}],"modelSelection":"fixture-model"}"#)
        let team = try decode(ArgoTeamView.self, #"{"run":"20261115-120000-fixture","tasks":null,"steps":null,"asks":null,"userTurns":null,"members":[]}"#)
        try expect(card.waitingIDs.isEmpty && card.tasks == 0 && team.tasks.isEmpty && team.steps.isEmpty && team.asks.isEmpty && team.userTurns.isEmpty, "null slices and newer fields")
        do {
            _ = try decode(ArgoTeamView.self, #"{"run":"20261115-120000-fixture","tasks":3}"#)
            throw NSError(domain: "WireContractCheck", code: 3)
        } catch is DecodingError {}
        let emptyWorkspace = try decode(ArgoWorkspace.self, #"{"id":"fixture-ws","roots":null,"status":null,"parentId":null}"#)
        try expect(emptyWorkspace.roots.isEmpty && emptyWorkspace.status.isEmpty && emptyWorkspace.parentId.isEmpty, "optional workspace fields")
        // agent_model.go and agent_resume.go: confirmation flags are required.
        let switched = try decode(ArgoModelSwitchReceipt.self, #"{"switched":true,"resume":{"sent":false,"reason":"not-error"}}"#)
        try expect(switched.switched && switched.resume?.sent == false && switched.resume?.retryAfterMs == 0, "partial model recovery result")
        for malformed in [#"{}"#, #"{"switched":true,"resume":{}}"#] {
            do {
                _ = try decode(ArgoModelSwitchReceipt.self, malformed)
                throw NSError(domain: "WireContractCheck", code: 4)
            } catch is DecodingError {}
        }
        try expect(ArgoModelID.normalized("  fixture/model:v1@host[blue]_-.  ") == "fixture/model:v1@host[blue]_-.", "model argument syntax")
        try expect(["", "a b", "中文", "semi;colon", String(repeating: "a", count: 81)].allSatisfy { ArgoModelID.normalized($0) == nil }, "invalid model arguments")
        print("PASS: fixed profiles/create/terminal/card/team/workspace/model wire fixtures")
    }
}
