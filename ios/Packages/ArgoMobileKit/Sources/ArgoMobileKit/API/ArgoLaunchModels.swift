import Foundation

/// GET /api/agents/profiles. `models` is an attribution pattern list, not a
/// model catalog. Launches keep the selected CLI's existing model settings.
public struct ArgoAgentProfile: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let engine: String
    public let command: String
    public let available: Bool
    public let hidden: Bool
    public let source: String
    public let fixedPermission: String
    public var id: String { name }
    public var supported: Bool { engine == "claude" || engine == "codex" }
    public var canLaunch: Bool { available && !hidden && supported }

    private enum CodingKeys: String, CodingKey {
        case name, engine, command, available, hidden, source, fixedPermission
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(String.self, forKey: .engine)
        command = try c.value(.command, or: "")
        available = try c.decode(Bool.self, forKey: .available)
        hidden = try c.value(.hidden, or: false)
        source = try c.value(.source, or: "")
        fixedPermission = try c.value(.fixedPermission, or: "")
    }
}

public enum ArgoLaunchPermission: String, Codable, CaseIterable, Sendable {
    case full, workspaceShell = "workspace-shell", workspace, readonly
}

/// POST /api/agents has no attempt deduplication, model or effort parameter.
public struct ArgoCreateAgentRequest: Encodable, Sendable {
    public let ws: String
    public let cwd: String
    public let profile: String
    public let context: String
    public let autonomy: ArgoLaunchPermission
    public let prompt: String
    public let cols = 80
    public let rows = 24
    public let leader = false

    public init(workspace: String, cwd: String, profile: String, context: String,
                autonomy: ArgoLaunchPermission = .full, prompt: String) {
        self.ws = workspace
        self.cwd = cwd
        self.profile = profile
        self.context = context
        self.autonomy = autonomy
        self.prompt = prompt
    }
}
