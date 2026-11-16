import Foundation

// What the phone reads from loomd. Field names are loomd's JSON tags
// (internal/server: workspaces.go workspaceView, agent_view.go agentCard /
// teamView / askView / taskView / userTurnView, agent_semantic.go stepGroup,
// agent_answer.go answerView, terminal_chat.go, queue.go DeliverResult;
// internal/agent/model plan.go Plan, terminal.go TerminalAgentIdentity;
// internal/agent/providers chat.go ChatItem). Only the fields the phone shows
// are decoded; unknown fields are ignored. Fields loomd omits when empty, and
// Go slices that may arrive as null, decode to their empty value. Times stay
// loomd's RFC 3339 strings (Go's zero time included); `ArgoTime.date` reads them.

public enum ArgoTime {
    /// RFC 3339 with up to nine fractional digits; nil for Go's zero time
    /// and for anything unreadable.
    public static func date(_ text: String?) -> Date? {
        guard let parts = parts(text) else { return nil }
        return parts.second.addingTimeInterval(Double(parts.nanosecond) / 1_000_000_000)
    }

    /// Compare Go timestamps without rounding their fractional seconds into Date.
    /// Missing or unreadable times sort before valid times.
    public static func isLater(_ lhs: String?, than rhs: String?) -> Bool {
        let left = parts(lhs) ?? (.distantPast, 0)
        let right = parts(rhs) ?? (.distantPast, 0)
        return left > right
    }

    private static func parts(_ text: String?) -> (second: Date, nanosecond: Int)? {
        guard let text, !text.isEmpty else { return nil }
        var whole = text
        var nanosecond = 0
        if let dot = text.firstIndex(of: ".") {
            // RFC 3339's optional fraction follows YYYY-MM-DDTHH:MM:SS.
            guard text.distance(from: text.startIndex, to: dot) == 19 else { return nil }
            let digits = text[text.index(after: dot)...].prefix { $0 >= "0" && $0 <= "9" }
            guard (1...9).contains(digits.count), let value = Int(digits) else { return nil }
            // The remaining zone must not be parsed as another fraction.
            let zone = text[digits.endIndex...]
            guard !zone.contains(".") else { return nil }
            nanosecond = value
            for _ in digits.count..<9 { nanosecond *= 10 }
            whole.removeSubrange(dot..<digits.endIndex)
        }
        // Foundation handles the calendar and offset on an exact whole second;
        // parsing a fractional Date first could round across a second boundary.
        guard let second = try? Date.ISO8601FormatStyle().parse(whole),
              (second, nanosecond) > (Date(timeIntervalSince1970: 946_684_800), 0) else { return nil }
        return (second, nanosecond)
    }
}

extension KeyedDecodingContainer {
    /// The value, or `fallback` when the key is absent or null.
    func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

/// `GET /api/health` (server.go pageBoot): what `connect()` checks.
public struct ArgoHealth: Decodable, Equatable, Sendable {
    public let version: String?
    public let commit: String?
    public let build: Int?
    /// Page↔loomd protocol (internal/apiproto.Version); absent reads as 0.
    public let api: Int?
    public let capabilities: [String]
    public let host: String?
    public let user: String?

    private enum CodingKeys: String, CodingKey { case version, commit, build, api, capabilities, host, user }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        build = try c.decodeIfPresent(Int.self, forKey: .build)
        api = try c.decodeIfPresent(Int.self, forKey: .api)
        capabilities = try c.value(.capabilities, or: [])
        host = try c.decodeIfPresent(String.self, forKey: .host)
        user = try c.decodeIfPresent(String.self, forKey: .user)
    }
}

/// A connected dev machine, as `connect()` found it.
public struct ArgoServerInfo: Equatable, Sendable {
    public let host: UUID
    public let version: String?
    public let commit: String?
    public let api: Int
    /// The dev machine's own host name (`/api/health` host).
    public let machine: String?
}

// MARK: Projects and workspaces

public struct ArgoRoot: Decodable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let repo: String
    public let kind: String
    /// The saved directory no longer exists (workspace roots only).
    public let missing: Bool

    private enum CodingKeys: String, CodingKey { case path, name, repo, kind, missing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.value(.name, or: "")
        repo = try c.value(.repo, or: "")
        kind = try c.value(.kind, or: "")
        missing = try c.value(.missing, or: false)
    }
}

/// `GET /api/projects` item (workspace.Project).
public struct ArgoProject: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let roots: [ArgoRoot]

    private enum CodingKeys: String, CodingKey { case id, name, path, roots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.value(.name, or: "")
        path = try c.value(.path, or: "")
        roots = try c.value(.roots, or: [])
    }
}

/// `GET /api/workspaces` item (workspaceView). `status` is the user's manual
/// board state (`""`, todo, in-progress, in-review, completed), not an Agent state.
public struct ArgoWorkspace: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let projectId: String
    public let name: String
    public let path: String
    public let status: String
    public let parentId: String
    public let roots: [ArgoRoot]
    public let updated: String

    private enum CodingKeys: String, CodingKey { case id, projectId, name, path, status, parentId, roots, updated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.value(.projectId, or: "")
        name = try c.value(.name, or: "")
        path = try c.value(.path, or: "")
        status = try c.value(.status, or: "")
        parentId = try c.value(.parentId, or: "")
        roots = try c.value(.roots, or: [])
        updated = try c.value(.updated, or: "")
    }
}

// MARK: Agents

/// `POST /api/agents/{run}/interrupt` (server.agent_interrupt.go). Unlike
/// ordinary read projections, confirmation fields are required: missing flags
/// must never turn an unreadable receipt into a reported success.
public struct ArgoInterruptReceipt: Decodable, Equatable, Sendable {
    public let run: String
    public let ws: String
    public let sent: Bool
    public let stopped: Bool
    public let reason: String?
    public let state: String
    public let interrupted: Bool
    public let turnStartedAt: String?
    /// Only messages queued when the key was sent are held. Read the actual
    /// queue afterwards; zero does not hold future automatic messages.
    public let held: Int
}

/// A pending decision of one Agent (askView). `terminalOnly` non-nil: only
/// the terminal can answer it (permission dialogs, multi-select, Codex
/// approvals…); `reply` refuses it here.
public struct ArgoAsk: Decodable, Equatable, Sendable {
    public let questionID: String
    public let run: String
    /// Member id; "" for the main Agent.
    public let agent: String
    public let name: String
    public let kind: String
    public let text: String
    public let options: [String]
    public let optionNotes: [String]
    public let multi: Bool
    /// Claude option previews have no custom-answer row.
    public let preview: Bool
    /// Number of questions in the native dialog, not a multi-select flag.
    public let questions: Int
    /// "external", "destructive" or "".
    public let risk: String
    public let terminalOnly: String?
    public let unread: Bool
    public let at: String

    private enum CodingKeys: String, CodingKey {
        case questionID, run, agent, name, kind, text, options, optionNotes, multi, preview, questions, risk, terminalOnly, unread, at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionID = try c.value(.questionID, or: "")
        run = try c.value(.run, or: "")
        agent = try c.value(.agent, or: "")
        name = try c.value(.name, or: "")
        kind = try c.value(.kind, or: "")
        text = try c.value(.text, or: "")
        options = try c.value(.options, or: [])
        optionNotes = try c.value(.optionNotes, or: [])
        multi = try c.value(.multi, or: false)
        preview = try c.value(.preview, or: false)
        questions = try c.value(.questions, or: 0)
        risk = try c.value(.risk, or: "")
        let only = try c.value(.terminalOnly, or: "")
        terminalOnly = only.isEmpty ? nil : only
        unread = try c.value(.unread, or: false)
        at = try c.value(.at, or: "")
    }

    /// Same rule as AttentionQuestion.acceptsReply: not a browser ask-user,
    /// background job or permission request, and not refused by the host.
    public var acceptsReply: Bool {
        !questionID.isEmpty && kind != "browser" && kind != "background" && kind != "permission" && !multi && terminalOnly == nil
    }

    /// Mirrors answerKeys in agent_reply_keys.go: Claude's custom row needs
    /// a number key after its options; preview dialogs have no such row.
    public func acceptsCustomReply(engine: String) -> Bool {
        acceptsReply && (options.isEmpty || engine != "claude" || (!preview && options.count < 9))
    }

    public func acceptsReply(_ text: String, engine: String) -> Bool {
        guard acceptsReply, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let index = options.firstIndex(of: text) {
            return engine != "claude" && engine != "codex" || index < 9
        }
        return acceptsCustomReply(engine: engine)
    }
}

/// The Agent's todo list (model.Plan: Claude TodoWrite/TaskCreate, Codex
/// update_plan). Item status: pending, in_progress, done.
public struct ArgoPlan: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Sendable {
        public let text: String
        public let status: String
        public var isDone: Bool { status == "done" }
        public var isActive: Bool { status == "in_progress" }

        private enum CodingKeys: String, CodingKey { case text, status }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.value(.text, or: "")
            status = try c.value(.status, or: "")
        }
    }

    public let items: [Item]
    public let done: Int
    public let total: Int
    public let updated: String

    private enum CodingKeys: String, CodingKey { case items, done, total, updated }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.value(.items, or: [])
        done = try c.value(.done, or: 0)
        total = try c.value(.total, or: 0)
        updated = try c.value(.updated, or: "")
    }
}

/// `GET /api/agents?ws=` item (agentCard with its state.View). `state`:
/// working, waiting, done, error (`unknown` for a run read too late);
/// `status` is the transcript's model.Status.
public struct ArgoAgentCard: Decodable, Equatable, Identifiable, Sendable {
    public let run: String
    public let ws: String
    public let terminal: String
    public let profile: String
    public let engine: String
    public let cli: String
    public let leader: Bool
    public let title: String
    public let latestTitle: String
    public let activity: String
    public let reply: String
    public let status: String
    public let state: String
    public let stateText: String
    /// `model` identifies Claude's recoverable model-unavailable error.
    public let failKind: String
    public let failNote: String
    public let stateStartedAt: String
    public let interrupted: Bool
    public let unread: Bool
    /// 5 waiting, 4 error, 3 stuck, 2 done-unseen < 30 min, 1 working, 0 idle.
    public let attention: Int
    public let ask: ArgoAsk?
    /// Current unread question identities. Intersect with questions actually
    /// displayed before acknowledging; seen questions remain available to answer.
    public let waitingIDs: [String]
    public let plan: ArgoPlan?
    /// Team tasks and how many are complete.
    public let tasks: Int
    public let done: Int
    /// Messages waiting in the run's queue.
    public let queued: Int
    /// Read-only native handoffs, separate from messages waiting to send.
    public let nativeHistory: Int
    public let error: String
    public let endReason: String
    public let exitCode: Int?
    public let cwd: String
    public let created: String
    public let updated: String

    public var id: String { run }

    /// The saved session name. `latestTitle` is only a rename suggestion.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        return cli.isEmpty ? (profile.isEmpty ? "Agent" : profile) : cli
    }

    private enum CodingKeys: String, CodingKey {
        case run, ws, terminal, profile, engine, cli, leader, title, latestTitle, activity, reply, status, state,
             stateText, failKind, failNote, stateStartedAt, interrupted, unread, attention, ask, waitingIDs, plan, tasks, done, queued, error,
             endReason, exitCode, cwd, created, updated, nativeHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(String.self, forKey: .run)
        ws = try c.value(.ws, or: "")
        terminal = try c.value(.terminal, or: "")
        profile = try c.value(.profile, or: "")
        engine = try c.value(.engine, or: "")
        cli = try c.value(.cli, or: "")
        leader = try c.value(.leader, or: false)
        title = try c.value(.title, or: "")
        latestTitle = try c.value(.latestTitle, or: "")
        activity = try c.value(.activity, or: "")
        reply = try c.value(.reply, or: "")
        status = try c.value(.status, or: "")
        state = try c.value(.state, or: "")
        stateText = try c.value(.stateText, or: "")
        failKind = try c.value(.failKind, or: "")
        failNote = try c.value(.failNote, or: "")
        stateStartedAt = try c.value(.stateStartedAt, or: "")
        interrupted = try c.value(.interrupted, or: false)
        unread = try c.value(.unread, or: false)
        attention = try c.value(.attention, or: 0)
        ask = try c.decodeIfPresent(ArgoAsk.self, forKey: .ask)
        waitingIDs = try c.value(.waitingIDs, or: [])
        plan = try c.decodeIfPresent(ArgoPlan.self, forKey: .plan)
        tasks = try c.value(.tasks, or: 0)
        done = try c.value(.done, or: 0)
        queued = try c.value(.queued, or: 0)
        nativeHistory = try c.value(.nativeHistory, or: 0)
        error = try c.value(.error, or: "")
        endReason = try c.value(.endReason, or: "")
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        cwd = try c.value(.cwd, or: "")
        created = try c.value(.created, or: "")
        updated = try c.value(.updated, or: "")
    }
}


extension ArgoAgentCard {
    /// `/api/agents` contains managed runs only. A hand-started CLI comes
    /// from the terminal list and keeps its read-only capabilities explicit.
    init?(manual terminal: ArgoTerminalView) {
        guard terminal.agent == nil, let agent = terminal.unmanaged else { return nil }
        run = "unmanaged:" + terminal.id
        ws = terminal.ws
        self.terminal = terminal.id
        profile = agent.name
        engine = agent.engine
        cli = agent.name.isEmpty ? agent.engine : agent.name
        leader = false
        title = terminal.pinned || agent.title.isEmpty ? terminal.title : agent.title
        latestTitle = ""
        activity = agent.stateText
        reply = ""
        status = agent.state
        state = agent.state
        stateText = agent.stateText
        failKind = ""
        failNote = ""
        stateStartedAt = agent.stateAt
        interrupted = false
        unread = agent.unread
        attention = agent.attention
        // Only the server's one structured question is available here. Its ID
        // must never stand in for other entries in this terminal's waitingIDs.
        ask = agent.ask
        waitingIDs = agent.waitingIDs
        plan = nil
        tasks = 0
        done = 0
        queued = 0
        nativeHistory = 0
        error = ""
        endReason = ""
        exitCode = nil
        cwd = agent.cwd
        created = terminal.created
        updated = agent.stateAt
    }
}

// MARK: Progress (team view)

/// One team task (taskView). `status` is model.Status: pending, active,
/// waiting, done, complete, error, stopped, unknown.
public struct ArgoTask: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let owner: String
    public let status: String
    public let description: String
    public let blockedBy: [String]

    private enum CodingKeys: String, CodingKey { case id, title, owner, status, description, blockedBy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, or: "")
        title = try c.value(.title, or: "")
        owner = try c.value(.owner, or: "")
        status = try c.value(.status, or: "")
        description = try c.value(.description, or: "")
        blockedBy = try c.value(.blockedBy, or: [])
    }
}

/// Recent grouped actions (stepGroup), newest first. `mark`: edit, pass,
/// fail, test, delegate, read, other.
public struct ArgoStepGroup: Decodable, Equatable, Sendable {
    public let at: String
    public let text: String
    public let count: Int
    public let mark: String

    private enum CodingKeys: String, CodingKey { case at, text, count, mark }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.value(.at, or: "")
        text = try c.value(.text, or: "")
        count = try c.value(.count, or: 0)
        mark = try c.value(.mark, or: "")
    }
}

/// One real user prompt (userTurnView). `by == "argo"`: Argo typed it.
public struct ArgoUserTurn: Decodable, Equatable, Sendable {
    public let nativeId: String
    public let at: String
    public let text: String
    public let by: String

    private enum CodingKeys: String, CodingKey { case nativeId, at, text, by }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nativeId = try c.value(.nativeId, or: "")
        at = try c.value(.at, or: "")
        text = try c.value(.text, or: "")
        by = try c.value(.by, or: "")
    }
}

/// `GET /api/agents/{run}`, the parts the phone shows as progress. loomd
/// runs git for each call, so read it when a session opens and on a slow
/// cadence, not at chat speed.
public struct ArgoTeamView: Decodable, Equatable, Sendable {
    public let run: String
    public let terminal: String
    public let ws: String
    public let title: String
    public let latestTitle: String
    public let engine: String
    public let cli: String
    public let status: String
    public let state: String
    public let stateText: String
    public let stateStartedAt: String
    public let interrupted: Bool
    public let plan: ArgoPlan?
    public let tasks: [ArgoTask]
    public let done: Int
    public let steps: [ArgoStepGroup]
    public let asks: [ArgoAsk]
    public let userTurns: [ArgoUserTurn]
    public let error: String
    public let updated: String

    private enum CodingKeys: String, CodingKey {
        case run, terminal, ws, title, latestTitle, engine, cli, status, state, stateText, stateStartedAt,
             interrupted, plan, tasks, done, steps, asks, userTurns, error, updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(String.self, forKey: .run)
        terminal = try c.value(.terminal, or: "")
        ws = try c.value(.ws, or: "")
        title = try c.value(.title, or: "")
        latestTitle = try c.value(.latestTitle, or: "")
        engine = try c.value(.engine, or: "")
        cli = try c.value(.cli, or: "")
        status = try c.value(.status, or: "")
        state = try c.value(.state, or: "")
        stateText = try c.value(.stateText, or: "")
        stateStartedAt = try c.value(.stateStartedAt, or: "")
        interrupted = try c.value(.interrupted, or: false)
        plan = try c.decodeIfPresent(ArgoPlan.self, forKey: .plan)
        tasks = try c.value(.tasks, or: [])
        done = try c.value(.done, or: 0)
        steps = try c.value(.steps, or: [])
        asks = try c.value(.asks, or: [])
        userTurns = try c.value(.userTurns, or: [])
        error = try c.value(.error, or: "")
        updated = try c.value(.updated, or: "")
    }
}

// MARK: Conversation

/// The native session a terminal's chat was read from
/// (model.TerminalAgentIdentity). Sent back as a message's `target`, loomd
/// refuses the message (409) when the terminal now runs another process or
/// session, so a message never lands in a conversation the user did not see.
/// Every field is kept exactly as loomd sent it.
public struct ArgoAgentIdentity: Codable, Equatable, Hashable, Sendable {
    public let run: String?
    public let engine: String
    public let pid: Int
    public let start: String
    public let started: String
    public let session: String

    public init(run: String?, engine: String, pid: Int = 0, start: String = "", started: String = "0001-01-01T00:00:00Z", session: String) {
        self.run = run
        self.engine = engine
        self.pid = pid
        self.start = start
        self.started = started
        self.session = session
    }

    private enum CodingKeys: String, CodingKey { case run, engine, pid, start, started, session }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let run = try c.decodeIfPresent(String.self, forKey: .run)
        self.run = run?.isEmpty == true ? nil : run
        engine = try c.value(.engine, or: "")
        pid = try c.value(.pid, or: 0)
        start = try c.value(.start, or: "")
        started = try c.value(.started, or: "0001-01-01T00:00:00Z")
        session = try c.value(.session, or: "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(run, forKey: .run)
        try c.encode(engine, forKey: .engine)
        try c.encode(pid, forKey: .pid)
        try c.encode(start, forKey: .start)
        try c.encode(started, forKey: .started)
        try c.encode(session, forKey: .session)
    }

    /// loomd's own validity rule (TerminalAgentIdentity.Valid).
    public var isValid: Bool {
        !engine.isEmpty && !session.isEmpty && ((run?.isEmpty == false) || (pid > 0 && !start.isEmpty && ArgoTime.date(started) != nil))
    }
}

/// One native content block, with the bounded reader's stable block identity.
public struct ArgoChatItem: Decodable, Equatable, Identifiable, Sendable {
    public let itemID: String
    /// Native JSONL record start, for display metadata only. Use `cursor` to page.
    public let offset: Int64
    public let cursor: ArgoChatPosition
    public let type: String
    public let role: String
    public let text: String
    public let name: String
    public let call: String
    public let diff: String
    public let output: String
    public let failed: Bool
    public let exit: Int?
    public let at: String
    public let cwd: String
    /// Show an explicit truncation notice; every projected block remains reachable.
    public let truncated: Bool
    public let truncatedFields: [String]
    public let fileRefs: [ArgoFileReference]

    /// Stable within the page's native session, even if the native id was shortened.
    public var id: String { cursor.description }

    private enum CodingKeys: String, CodingKey {
        case itemID = "id", offset, cursor, type, role, text, name, call, diff, output, failed, exit, at, cwd,
             truncated, truncatedFields, fileRefs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.value(.itemID, or: "")
        offset = try c.decode(Int64.self, forKey: .offset)
        cursor = try c.decode(ArgoChatPosition.self, forKey: .cursor)
        guard offset == cursor.recordOffset else {
            throw DecodingError.dataCorruptedError(forKey: .cursor, in: c, debugDescription: "Chat cursor does not match native offset")
        }
        type = try c.value(.type, or: "")
        role = try c.value(.role, or: "")
        text = try c.value(.text, or: "")
        name = try c.value(.name, or: "")
        call = try c.value(.call, or: "")
        diff = try c.value(.diff, or: "")
        output = try c.value(.output, or: "")
        failed = try c.value(.failed, or: false)
        exit = try c.decodeIfPresent(Int.self, forKey: .exit)
        at = try c.value(.at, or: "")
        cwd = try c.value(.cwd, or: "")
        truncated = try c.value(.truncated, or: false)
        truncatedFields = try c.value(.truncatedFields, or: [])
        if c.contains(.fileRefs), try !c.decodeNil(forKey: .fileRefs) {
            var refs = try c.nestedUnkeyedContainer(forKey: .fileRefs)
            var list: [ArgoFileReference] = []
            while !refs.isAtEnd {
                guard list.count < ArgoAttachmentPolicy.referenceLimit else {
                    throw DecodingError.dataCorruptedError(forKey: .fileRefs, in: c, debugDescription: "Too many file references")
                }
                list.append(try refs.decode(ArgoFileReference.self))
            }
            fileRefs = list
        } else { fileRefs = [] }
    }

    /// Owned UTF-8 payload plus value/array element storage. The transcript's
    /// budget bounds retained content; decoding also has a separate 1 MiB cap.
    var retainedByteCount: Int {
        MemoryLayout<Self>.stride
            + [itemID, type, role, text, name, call, diff, output, at, cwd].reduce(0) { $0 + $1.utf8.count }
            + fileRefs.reduce(0) { $0 + $1.retainedByteCount }
            + truncatedFields.reduce(0) { $0 + MemoryLayout<String>.stride + $1.utf8.count }
    }
}

/// A bounded block span [start, end). Waiting replies have no native span yet.
public struct ArgoChatPage: Decodable, Equatable, Sendable {
    public static let responseByteLimit = 1_048_576
    public let bounded: Bool
    public let byteLimit: Int
    public let waiting: String?
    public let identity: ArgoAgentIdentity?
    public let items: [ArgoChatItem]
    public let start: ArgoChatPosition
    public let end: ArgoChatPosition
    public let size: Int64
    public let older: Bool
    public let newer: Bool
    public let skipped: Int

    private enum CodingKeys: String, CodingKey {
        case bounded, byteLimit, waiting, identity, items, start, end, size, older, newer, skipped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(Bool.self, forKey: .bounded) == true,
              try c.decodeIfPresent(Int.self, forKey: .byteLimit) == Self.responseByteLimit else {
            throw ArgoClientError.unsupportedServer(.message("Update Argo on the host to read bounded 1 MiB chat pages."))
        }
        bounded = true
        byteLimit = Self.responseByteLimit
        let note = try c.decodeIfPresent(String.self, forKey: .waiting)
        waiting = note?.isEmpty == true ? nil : note
        items = try c.value(.items, or: [])
        skipped = try c.value(.skipped, or: 0)
        if waiting != nil {
            identity = nil
            start = .zero; end = .zero; size = 0
            older = false; newer = false
        } else {
            identity = try c.decode(ArgoAgentIdentity.self, forKey: .identity)
            start = try c.decode(ArgoChatPosition.self, forKey: .start)
            end = try c.decode(ArgoChatPosition.self, forKey: .end)
            size = try c.decode(Int64.self, forKey: .size)
            older = try c.decode(Bool.self, forKey: .older)
            newer = try c.decode(Bool.self, forKey: .newer)
            guard identity?.isValid == true, start <= end, end <= ArgoChatPosition(recordOffset: size),
                  items.allSatisfy({ $0.cursor >= start && $0.cursor < end }) else {
                throw DecodingError.dataCorruptedError(forKey: .start, in: c, debugDescription: "Invalid bounded chat span")
            }
        }
    }
}

public enum ArgoChatCursor: Equatable, Sendable {
    case latest
    /// Blocks strictly before this boundary.
    case before(ArgoChatPosition)
    /// Blocks starting at this boundary, including the named block.
    case after(ArgoChatPosition)
    /// Open a new window at this block (EOF opens the tail).
    case around(ArgoChatPosition)
}

/// `GET /api/agents/{run}/answer[?turn=n]`: one turn of the main Agent, the
/// full Markdown re-read from the transcript (not the 12000-character
/// window). `turn` 1-based among `turns`; 0 when there is no user turn yet.
/// `final` false: the Agent kept working after this answer.
public struct ArgoTurnAnswer: Decodable, Equatable, Sendable {
    public let prompt: ArgoUserTurn?
    public let text: String
    public let at: String
    public let final: Bool
    public let turn: Int
    public let turns: Int

    private enum CodingKeys: String, CodingKey { case prompt, text, at, final, turn, turns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decodeIfPresent(ArgoUserTurn.self, forKey: .prompt)
        text = try c.value(.text, or: "")
        at = try c.value(.at, or: "")
        final = try c.value(.final, or: false)
        turn = try c.value(.turn, or: 0)
        turns = try c.value(.turns, or: 0)
    }
}

// MARK: Sending

/// A handoff acknowledgement, never a native chat record or model completion.
public struct ArgoNativeHandoff: Decodable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case accepted, unknown }
    public let state: State
    public let note: String
    public let unrecognizedState: String?

    private enum CodingKeys: String, CodingKey { case state, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Presence of native is read-only even when a newer host adds a state.
        let raw = try c.value(.state, or: "")
        state = raw == "accepted" ? .accepted : .unknown
        unrecognizedState = raw == "accepted" || raw == "unknown" ? nil : raw
        note = try c.value(.note, or: "")
    }
}

/// One queued message (queueItem).
public struct ArgoQueuedMessage: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let source: String
    public let created: String
    public let updated: String
    public let notBefore: String
    /// A pasted row is read-only even before its input is submitted.
    public let pastedAt: String?
    /// Nonempty when the host may already have submitted this item. It keeps
    /// the record for review and forbids automatic delivery or manual resend.
    public let deliveryUnknown: String
    public let native: ArgoNativeHandoff?
    /// Original server-confirmed destination; never rebound to the current chat.
    public let target: ArgoAgentIdentity?
    public let submit: Bool
    public let parked: Bool
    public let truncatedFields: [String]

    public var isIncomplete: Bool { !truncatedFields.isEmpty }
    /// Unknown future markers cannot authorize copying or editing a preview.
    public func isComplete(_ field: String) -> Bool {
        let known: Set<String> = ["text", "source", "deliveryUnknown", "native.note", "origin.label", "origin.why", "pasted.placeholder"]
        return !truncatedFields.contains(field) && truncatedFields.allSatisfy(known.contains)
    }

    public func matchesFullItem(_ full: ArgoQueuedMessage) -> Bool {
        guard !full.isIncomplete, id == full.id, target == full.target, created == full.created,
              updated == full.updated, notBefore == full.notBefore, pastedAt == full.pastedAt,
              submit == full.submit, parked == full.parked,
              native?.state == full.native?.state, native?.unrecognizedState == full.native?.unrecognizedState else { return false }
        return (!isComplete("text") || text == full.text) &&
            (!isComplete("source") || source == full.source) &&
            (!isComplete("deliveryUnknown") || deliveryUnknown == full.deliveryUnknown) &&
            (!isComplete("native.note") || native?.note == full.native?.note)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, source, created, updated, pasted, deliveryUnknown, native, target, submit, parked, truncatedFields
        case notBefore = "not_before"
    }
    private enum PastedKeys: String, CodingKey { case at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, or: "")
        text = try c.value(.text, or: "")
        source = try c.value(.source, or: "")
        created = try c.value(.created, or: "")
        updated = try c.value(.updated, or: "")
        notBefore = try c.value(.notBefore, or: "")
        if c.contains(.pasted), try !c.decodeNil(forKey: .pasted) {
            pastedAt = try c.nestedContainer(keyedBy: PastedKeys.self, forKey: .pasted).decode(String.self, forKey: .at)
        } else { pastedAt = nil }
        deliveryUnknown = try c.value(.deliveryUnknown, or: "")
        native = try c.decodeIfPresent(ArgoNativeHandoff.self, forKey: .native)
        target = try c.decodeIfPresent(ArgoAgentIdentity.self, forKey: .target)
        submit = try c.value(.submit, or: false)
        parked = try c.value(.parked, or: false)
        truncatedFields = try c.contains(.truncatedFields) ? c.decode([String].self, forKey: .truncatedFields) : []
    }
}

/// A read-only reference to handoffs retained on an earlier run of the same
/// native session. Read the original queue with `sourceRun`; keep its target.
public struct ArgoNativeHistorySource: Decodable, Equatable, Sendable {
    public let sourceRun: String
    public let target: ArgoAgentIdentity
    public let nativeHistory: Int

    private enum CodingKeys: String, CodingKey { case sourceRun, target, nativeHistory }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceRun = try c.decode(String.self, forKey: .sourceRun)
        target = try c.decode(ArgoAgentIdentity.self, forKey: .target)
        nativeHistory = try c.decode(Int.self, forKey: .nativeHistory)
        guard ArgoRun.isManaged(sourceRun), target.run == sourceRun, target.isValid, nativeHistory >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .sourceRun, in: c, debugDescription: "Invalid native history source")
        }
    }
}

/// A run's message queue (queueView). `hold`: why queued messages wait
/// ("" = they go at the next look).
public struct ArgoQueue: Decodable, Equatable, Sendable {
    public static let previewByteLimit = 8_388_608
    public let run: String
    public let ws: String
    public let identity: ArgoAgentIdentity?
    public let state: String
    public let ended: Bool
    public let hold: String
    public let items: [ArgoQueuedMessage]
    public let later: [ArgoQueuedMessage]
    public let truncatedFields: [String]
    /// Ordinary unsent and scheduled messages. Absent on pre-handoff hosts.
    public let pending: Int?
    /// Total read-only handoffs, including those referenced by nativeSources.
    public let nativeHistory: Int
    /// Earlier-run references, without their bodies or sendable items.
    /// nil means the host did not provide sources, not that history is absent.
    public let nativeSources: [ArgoNativeHistorySource]?

    private enum CodingKeys: String, CodingKey { case run, ws, identity, state, ended, hold, items, later, pending, nativeHistory, nativeSources, truncatedFields }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.value(.run, or: "")
        ws = try c.value(.ws, or: "")
        identity = try c.decodeIfPresent(ArgoAgentIdentity.self, forKey: .identity)
        state = try c.value(.state, or: "")
        ended = try c.value(.ended, or: false)
        hold = try c.value(.hold, or: "")
        items = try c.value(.items, or: [])
        later = try c.value(.later, or: [])
        truncatedFields = try c.contains(.truncatedFields) ? c.decode([String].self, forKey: .truncatedFields) : []
        pending = try c.decodeIfPresent(Int.self, forKey: .pending)
        nativeHistory = try c.value(.nativeHistory, or: 0)
        nativeSources = try c.decodeIfPresent([ArgoNativeHistorySource].self, forKey: .nativeSources)
    }
}

/// A read of one original item, never a delivery receipt or an editable preview.
public struct ArgoQueueItemDetail: Decodable, Equatable, Sendable {
    public let run: String
    public let ws: String
    public let identity: ArgoAgentIdentity
    public let state: String
    public let ended: Bool
    public let later: Bool
    public let item: ArgoQueuedMessage

    private enum CodingKeys: String, CodingKey { case run, ws, identity, state, ended, later, item, truncatedFields }
    private enum ItemKeys: String, CodingKey { case text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(String.self, forKey: .run)
        ws = try c.decode(String.self, forKey: .ws)
        identity = try c.decode(ArgoAgentIdentity.self, forKey: .identity)
        state = try c.decode(String.self, forKey: .state)
        ended = try c.decode(Bool.self, forKey: .ended)
        later = try c.decode(Bool.self, forKey: .later)
        item = try c.decode(ArgoQueuedMessage.self, forKey: .item)
        _ = try c.nestedContainer(keyedBy: ItemKeys.self, forKey: .item).decode(String.self, forKey: .text)
        let truncated = try c.contains(.truncatedFields) ? c.decode([String].self, forKey: .truncatedFields) : []
        guard !item.isIncomplete, truncated.isEmpty else {
            throw ArgoClientError.invalidResponse(.message("The host returned an incomplete full message."))
        }
    }
}

/// What loomd did with a message (DeliverResult), and whether this answer is
/// the replay of an earlier request with the same attempt id.
public struct ArgoSendReceipt: Equatable, Sendable {
    public let run: String
    public let attempt: String
    /// Written into the Agent now. false: inspect the queued item; an item
    /// with deliveryUnknown is held for review and must not be sent again.
    public let delivered: Bool
    /// The retained entry, including an uncertain delivery held for review.
    public let queued: ArgoQueuedMessage?
    public let queue: ArgoQueue
    /// The text sits in the CLI's input box without its Enter (a permission
    /// dialog came up); the user finishes it at the terminal.
    public let pasted: Bool
    public let note: String
    /// loomd answered from its attempt record (X-Loom-Duplicate): the first
    /// request with this attempt id had already been handled.
    public let duplicate: Bool
    public private(set) var truncatedFields: [String] = []
}

struct DeliverResult: Decodable {
    let delivered: Bool
    let item: ArgoQueuedMessage?
    let queue: ArgoQueue
    let pasted: Bool
    let note: String
    let truncatedFields: [String]

    private enum CodingKeys: String, CodingKey { case delivered, item, queue, pasted, note, truncatedFields }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try c.decode(Bool.self, forKey: .delivered)
        item = try c.decodeIfPresent(ArgoQueuedMessage.self, forKey: .item)
        queue = try c.decode(ArgoQueue.self, forKey: .queue)
        pasted = try c.value(.pasted, or: false)
        note = try c.value(.note, or: "")
        truncatedFields = try c.contains(.truncatedFields) ? c.decode([String].self, forKey: .truncatedFields) : []
    }
}
