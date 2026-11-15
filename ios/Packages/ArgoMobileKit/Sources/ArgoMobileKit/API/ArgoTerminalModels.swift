import Foundation

/// Shared terminal wire DTO for current ownership, manual asks and creation
/// recovery. EndedAgent history never supplies the current managed owner.
public struct ArgoTerminalView: Decodable, Equatable, Identifiable, Sendable {
    public struct Agent: Decodable, Equatable, Sendable {
        public let run: String
        public let profile: String
        public let engine: String
        public let leader: Bool?
        public let session: String?
        private enum CodingKeys: String, CodingKey { case run, profile, engine, leader, session }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            run = try c.decode(String.self, forKey: .run)
            profile = try c.value(.profile, or: "")
            engine = try c.value(.engine, or: "")
            leader = try c.decodeIfPresent(Bool.self, forKey: .leader)
            session = try c.decodeIfPresent(String.self, forKey: .session)
        }
    }

    public struct Unmanaged: Decodable, Equatable, Sendable {
        public let engine: String
        public let name: String
        public let cwd: String
        public let title: String
        public let state: String
        public let stateText: String
        public let stateAt: String
        public let attention: Int
        public let unread: Bool
        public let waitingIDs: [String]
        public let ask: ArgoAsk?

        private enum CodingKeys: String, CodingKey {
            case engine, name, cwd, title, state, stateText, stateAt, attention, unread, waitingIDs, ask
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            engine = try c.value(.engine, or: "")
            name = try c.value(.name, or: "")
            cwd = try c.value(.cwd, or: "")
            title = try c.value(.title, or: "")
            state = try c.value(.state, or: "")
            stateText = try c.value(.stateText, or: "")
            stateAt = try c.value(.stateAt, or: "")
            attention = try c.value(.attention, or: 0)
            unread = try c.value(.unread, or: false)
            waitingIDs = try c.value(.waitingIDs, or: [])
            ask = try c.decodeIfPresent(ArgoAsk.self, forKey: .ask)
        }
    }

    public let id: String
    public let ws: String
    public let title: String
    public let pinned: Bool
    public let created: String
    public let cwd: String
    public let context: String
    public let alive: Bool?
    public let exitCode: Int?
    /// Current owner only; released shells' EndedAgent history is not `agent`.
    public let agent: Agent?
    public let unmanaged: Unmanaged?

    private enum CodingKeys: String, CodingKey { case id, ws, title, pinned, created, cwd, context, alive, exitCode, agent, unmanaged }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ws = try c.value(.ws, or: "")
        title = try c.value(.title, or: "")
        pinned = try c.value(.pinned, or: false)
        created = try c.value(.created, or: "")
        cwd = try c.value(.cwd, or: "")
        context = try c.value(.context, or: "")
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        unmanaged = try c.decodeIfPresent(Unmanaged.self, forKey: .unmanaged)
    }

    public func matches(workspace: String, cwd: String, profile: String, context: String) -> Bool {
        !id.isEmpty && alive != nil && ws == workspace && self.cwd == cwd && self.context == context &&
            agent?.profile == profile && agent?.leader == false &&
            agent.map { ArgoRun.isManaged($0.run) && ($0.engine == "claude" || $0.engine == "codex") } == true
    }
}
