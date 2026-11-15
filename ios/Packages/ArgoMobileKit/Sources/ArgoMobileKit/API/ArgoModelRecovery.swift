import Foundation

/// loomd's `/model <id>` argument rule (internal/server/agent_model.go).
/// This validates syntax only; it is not a model catalog or a claim that an
/// account can use a particular model.
public enum ArgoModelID {
    public static func normalized(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(id.utf8.count), id.utf8.allSatisfy(Self.allowed) else { return nil }
        return id
    }

    private static func allowed(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || ".:/@[]-_".utf8.contains(byte)
    }
}

public struct ArgoModelResume: Decodable, Equatable, Sendable {
    public let sent: Bool
    public let reason: String
    public let error: String
    public let retryAfterMs: Int64
    public let message: String

    private enum CodingKeys: String, CodingKey { case sent, reason, error, retryAfterMs, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decode(Bool.self, forKey: .sent)
        reason = try c.value(.reason, or: "")
        error = try c.value(.error, or: "")
        retryAfterMs = try c.value(.retryAfterMs, or: 0)
        message = try c.value(.message, or: "")
    }
}

/// The receipt of POST /api/agents/{run}/model. HTTP 200 alone does not say
/// that Claude accepted the model or that loomd sent the resume sentence.
public struct ArgoModelSwitchReceipt: Decodable, Equatable, Sendable {
    public let switched: Bool
    public let message: String
    public let resume: ArgoModelResume?

    private enum CodingKeys: String, CodingKey { case switched, message, resume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switched = try c.decode(Bool.self, forKey: .switched)
        message = try c.value(.message, or: "")
        resume = try c.decodeIfPresent(ArgoModelResume.self, forKey: .resume)
    }
}

public extension ArgoAgentCard {
    /// The same recovery state as the web's model error action, restricted to
    /// a live managed Claude run. Other CLIs never get a simulated `/model ID`.
    var offersModelRecovery: Bool {
        ArgoRun.isManaged(run) && engine == "claude" && state == "error" && failKind == "model"
            && !terminal.isEmpty && exitCode == nil && endReason.isEmpty
    }
}
