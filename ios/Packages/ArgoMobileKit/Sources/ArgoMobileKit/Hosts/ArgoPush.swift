import Foundation

/// The registration receipt is safe to persist. It contains no APNs or gateway token.
public struct ArgoPushRegistration: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let hostID: UUID
    public let deviceID: String
    public let registrationID: String

    public init(enabled: Bool, hostID: UUID, deviceID: String, registrationID: String) {
        self.enabled = enabled; self.hostID = hostID
        self.deviceID = deviceID; self.registrationID = registrationID
    }
}

/// Only identifiers are accepted from a notification. No URL or action is executable.
public struct ArgoPushRoute: Codable, Equatable, Sendable {
    public let v: Int
    public let hostID: UUID
    public let deviceID: String
    public let registrationID: String
    public let workspace: String
    public let run: String
    public let event: String
    public let eventID: String

    public static func decode(_ userInfo: [AnyHashable: Any]) -> Self? {
        guard let body = userInfo["argo"] as? [String: Any], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return nil }
        return value
    }

    public func matches(_ registration: ArgoPushRegistration, hosts: [LoomHost]) -> Bool {
        valid && registration.enabled && registration.hostID == hostID &&
            registration.deviceID == deviceID && registration.registrationID == registrationID &&
            hosts.contains { $0.id == hostID && $0.deviceID == deviceID }
    }

    private var valid: Bool {
        v == 1 && GatewayCredential.validDevice(deviceID) && GatewayCredential.validDevice(registrationID) &&
            Self.identifier(workspace) && Self.identifier(run) && Self.identifier(eventID) &&
            ["agent.question", "agent.error", "agent.done", "agent.stuck", "agent.budget"].contains(event)
    }

    private static func identifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 &&
            !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
