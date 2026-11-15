import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A reply always carries its host, workspace, run and terminal. A later change
/// of keyboard focus cannot redirect it to another agent (or another host).
public struct AttentionTarget: Codable, Hashable, Sendable {
    public let host: UUID
    public let ws: String
    public let run: String
    public let terminal: String
    /// A page view instead of one run: `errorsView` opens the overview with
    /// only the failed Agents (FT47-03's grouped error notice).
    public let view: String?
    /// The browser tab a browser ask-user waits in (B-01): opening the target
    /// shows that tab instead of the run's question drawer. nil otherwise,
    /// and in targets stored before it existed.
    public let tab: String?
    /// FT56-03: a same-task race's comparison instead of an Agent run; run
    /// and terminal are empty then.
    public let race: String?
    /// What the page does once the run is located: nil only locates it,
    /// `forkAction` also opens the fork dialog on the handoff summary
    /// (FT21-02). Targets stored before it existed decode as nil.
    public let action: String?

    public static let forkAction = "fork"
    public static let errorsView = "errors"
    /// FT74-01: the overview on the Agents that ended unexpectedly (grouped
    /// exits), and the workspace's session library (a run lost on another
    /// ptyd, which has no terminal here; `ws` names the workspace).
    public static let exitedView = "exited"
    public static let sessionsView = "sessions"

    public init(host: UUID, ws: String, run: String, terminal: String, view: String? = nil, tab: String? = nil, race: String? = nil, action: String? = nil) {
        self.host = host; self.ws = ws; self.run = run; self.terminal = terminal; self.view = view
        self.tab = tab?.isEmpty == true ? nil : tab
        self.race = race
        self.action = action
    }

    /// The target a notification response asks for: its 「换 CLI 接着做…」
    /// action adds `forkAction`; a click or any other action only locates.
    public func responding(to actionIdentifier: String) -> AttentionTarget {
        guard actionIdentifier == AgentNotification.switchCLIAction else { return self }
        return AttentionTarget(host: host, ws: ws, run: run, terminal: terminal, view: view, tab: tab, race: race, action: Self.forkAction)
    }

    public var id: String { race.map { "\(host.uuidString)/race/\($0)" } ?? "\(host.uuidString)/\(run)" }

    /// A notification's target is usable when it names a whole run, a view
    /// or a race (FT56-03).
    public var deliverable: Bool {
        view == Self.errorsView || view == Self.exitedView || (view == Self.sessionsView && !ws.isEmpty)
            || race?.isEmpty == false || (!ws.isEmpty && !run.isEmpty && !terminal.isEmpty)
    }
}

/// One same-task race in `/api/attention` (FT56-03): still running, or settled
/// recently and not picked yet. loomd decides `settled` and writes the texts.
public struct AttentionRace: Decodable, Equatable, Sendable {
    public let id: String
    public let ws: String
    public let workspace: String
    public let settled: Bool
    /// Settled with no member reporting done.
    public let failed: Bool?
    /// The notice's texts; only a settled race has them.
    public let title: String?
    public let body: String?

    public init(id: String, ws: String = "", workspace: String = "", settled: Bool,
                failed: Bool? = nil, title: String? = nil, body: String? = nil) {
        self.id = id; self.ws = ws; self.workspace = workspace; self.settled = settled
        self.failed = failed; self.title = title; self.body = body
    }
}

public struct AttentionQuestion: Codable, Equatable, Sendable {
    // Optional only for notifications delivered before question identities
    // existed. Their text remains recoverable, and replyRequest rejects them.
    public let questionID: String?
    /// Read acknowledgement affects reminders only; the original question
    /// remains in the snapshot so a delivered notification can still reply.
    public let unread: Bool?
    public let run: String
    public let terminal: String
    public let ws: String
    public let workspace: String
    public let title: String
    public let agent: String
    public let name: String
    public let kind: String
    public let question: String
    public let options: [String]
    /// When it was asked (RFC 3339; FT44-01). nil from a loomd that predates
    /// it and in notifications posted before it.
    public let at: String?
    /// The host's reason a remote reply would be refused (a permission
    /// dialog, multiSelect, a Codex run showing approvals, queued dialogs);
    /// nil when it can be answered here. Such a question offers no reply.
    public let terminalOnly: String?
    /// The note under each option, in option order (FT76-02); nil from an
    /// older host.
    public let optionNotes: [String]?

    /// Set for kind "browser": the tab the Agent's ask-user waits in (B-01).
    public let tab: String?

    public init(run: String, terminal: String, ws: String, workspace: String, title: String,
                agent: String = "", name: String = "", kind: String = "question", question: String, options: [String] = [], questionID: String? = nil, at: String? = nil,
                terminalOnly: String? = nil, optionNotes: [String]? = nil, tab: String? = nil, unread: Bool? = nil) {
        self.questionID = questionID
        self.unread = unread
        self.run = run; self.terminal = terminal; self.ws = ws; self.workspace = workspace
        self.title = title; self.agent = agent; self.name = name; self.kind = kind
        self.question = question; self.options = options; self.at = at; self.terminalOnly = terminalOnly
        self.optionNotes = optionNotes; self.tab = tab
    }

    private enum CodingKeys: String, CodingKey {
        case questionID, unread, run, terminal, ws, workspace, title, agent, name, kind, question, options, at,
             terminalOnly, optionNotes, tab
    }

    /// loomd copies a hand-started CLI's options as they were parsed, so a
    /// free-text question arrives as `"options":null` (srv/attention.go,
    /// waiting_seen.go). Reading that as no options keeps the whole snapshot
    /// readable instead of failing it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionID = try c.decodeIfPresent(String.self, forKey: .questionID)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread)
        run = try c.decode(String.self, forKey: .run)
        terminal = try c.decode(String.self, forKey: .terminal)
        ws = try c.decode(String.self, forKey: .ws)
        workspace = try c.decode(String.self, forKey: .workspace)
        title = try c.decode(String.self, forKey: .title)
        agent = try c.decode(String.self, forKey: .agent)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        at = try c.decodeIfPresent(String.self, forKey: .at)
        terminalOnly = try c.decodeIfPresent(String.self, forKey: .terminalOnly)
        optionNotes = try c.decodeIfPresent([String].self, forKey: .optionNotes)
        tab = try c.decodeIfPresent(String.self, forKey: .tab)
    }

    /// A browser ask-user is answered on the page (log in, then 「完成」), not
    /// by text typed into the terminal: it offers no reply or choices.
    public var isBrowser: Bool { kind == "browser" }
    public var needsReminder: Bool { unread != false }
    /// A Claude background job waiting for an answer (FT149-02). It has no
    /// Loom terminal to type into: opening it attaches the job, and it never
    /// offers a reply.
    public var isBackground: Bool { kind == "background" }
    /// A tool permission request: approved or denied in the terminal only
    /// (FT62-02, BG1-21).
    public var isPermission: Bool { kind == "permission" }
    /// A reply typed or picked here reaches the CLI: not a browser ask-user,
    /// a background job, a permission request, or a question the host answers
    /// only in the terminal (BG1-21).
    public var acceptsReply: Bool { !isBrowser && !isBackground && !isPermission && terminalOnly == nil }

    public func target(host: UUID) -> AttentionTarget {
        AttentionTarget(host: host, ws: ws, run: run, terminal: terminal, tab: isBrowser ? tab : nil)
    }
}

public struct AttentionUpstreamBurst: Decodable, Sendable {
    public let text: String
}

/// One host's upstream hint. The host id is the identity: two hosts can report
/// the same text during a shared outage, and ForEach must still keep them
/// apart. The host name is shown with the text so the user can tell which
/// machine needs attention.
public struct AttentionUpstreamHint: Identifiable, Equatable, Sendable {
    public let hostID: UUID
    public let hostName: String
    public let text: String
    public var id: UUID { hostID }

    public init(hostID: UUID, hostName: String, text: String) {
        self.hostID = hostID
        self.hostName = hostName
        self.text = text
    }
}

public struct AttentionSnapshot: Decodable, Sendable {
    public let waiting: [AttentionQuestion]
    public let errors: Int
    /// One recent multi-session upstream failure burst; nil when there is none
    /// or the host predates passive upstream health.
    public var upstream: AttentionUpstreamBurst? = nil
    /// Every run's display state, for the shell's notification diff. nil for
    /// a loomd that predates it; such a host keeps the menu bar and replies
    /// but produces no local Agent notifications.
    public let agents: [AttentionAgent]?
    /// Runs whose first transcript read is still in flight. A snapshot with a
    /// non-zero value must not make its missing runs look deleted.
    public let loading: Int?
    /// Runs whose record could not be read. They are absent from `agents` for
    /// a reason that is not deletion (R2-1).
    public let unreadable: [String]?
    /// FT56-03: nil for a loomd that predates race notices.
    public let races: [AttentionRace]?
    /// loomd is still looking for runs lost on another ptyd (FT74-01): a
    /// missing run may be one of them, so the snapshot is incomplete too.
    public var scanning: Bool? = nil

    /// Runs that need the user, for the Dock badge next to `errors`: a
    /// question, a turn that ended with one (FT79-01, when `asking` is on) or
    /// an unexpected end not looked at yet (FT74-01). An error run is
    /// counted in `errors`, never here as well.
    public func needsYouRuns(asking: Bool) -> Int {
        var runs = Set(waiting.filter(\.needsReminder).map(\.run))
        for agent in agents ?? [] where agent.state != "error" {
            if asking, agent.state == "done", !(agent.asking ?? "").isEmpty { runs.insert(agent.run) }
            if agent.unexpectedEnd, agent.endUnseen == true { runs.insert(agent.run) }
        }
        return runs.count
    }
    /// BG34-01: loomd's count of what is still working on that machine —
    /// working runs, runs with background commands, busy background tasks.
    /// nil for a loomd that predates it.
    public let working: Int?
    /// A plain terminal may enter a hand-started CLI without a managed run
    /// event. Observe it on the existing heartbeat while it is alive.
    public var observingTerminals: Bool? = nil
}

public struct AttentionEntry: Identifiable, Equatable, Sendable {
    public let host: UUID
    public let hostName: String
    public let question: AttentionQuestion
    public var target: AttentionTarget { question.target(host: host) }
    public var id: String { "\(target.id)/\(question.agent)/\(question.questionID ?? "unidentified")" }

    public init(host: UUID, hostName: String, question: AttentionQuestion) {
        self.host = host; self.hostName = hostName; self.question = question
    }
}

/// D81: the one 「下一个等你处理的 Agent」 queue ⌃⌥Space, the page's ⌃⌘J and
/// the status menu walk, across every connected host. Same rule as the page
/// (web/js/attention.js attentionQueue, shared fixture attention-queue.json):
/// waiting (a question, or with the host's 「以问句结尾」 switch on a finished
/// unseen turn that ended with one, FT79-01) > error > stuck > finished and
/// unseen within 30 minutes; within a
/// kind the nearest warm cache expiry first, then earliest `stateStartedAt`,
/// an unknown time last; ties keep
/// the host order, then loomd's order. A run without a terminal is skipped.
public enum AttentionQueue {
    public static let unreadFor: TimeInterval = 30 * 60

    public static func rank(_ a: AttentionAgent, asking: Bool = true, now: Date) -> Int {
        if asking, a.state == "done", !a.interrupted, a.unread == true, !(a.asking ?? "").isEmpty { return 4 }
        switch a.state {
        case "waiting": return a.unread == false ? 0 : 4
        case "error": return 3
        case "working": return a.stuckSince?.isEmpty == false ? 2 : 0
        case "done":
            guard a.unread == true, let at = date(a.stateStartedAt) else { return 0 }
            return now.timeIntervalSince(at) < unreadFor ? 1 : 0
        default: return 0
        }
    }

    public static func order(_ hosts: [(host: UUID, asking: Bool, agents: [AttentionAgent])], now: Date) -> [AttentionTarget] {
        var rows: [(target: AttentionTarget, rank: Int, expiry: Date, at: Date, i: Int)] = []
        for (host, asking, agents) in hosts {
            for a in agents where !a.terminal.isEmpty {
                let r = rank(a, asking: asking, now: now)
                guard r > 0 else { continue }
                rows.append((AttentionTarget(host: host, ws: a.ws, run: a.run, terminal: a.terminal), r,
                             CacheSoon.date(a.cacheExpiresAt).flatMap { $0 > now ? $0 : nil } ?? .distantFuture,
                             date(a.stateStartedAt) ?? .distantFuture, rows.count))
            }
        }
        return rows.sorted { x, y in
            if x.rank != y.rank { return x.rank > y.rank }
            if x.expiry != y.expiry { return x.expiry < y.expiry }
            if x.at != y.at { return x.at < y.at }
            return x.i < y.i
        }.map(\.target)
    }

    /// RFC 3339 with up to nine fractional digits; nil for Go's zero time.
    static func date(_ iso: String) -> Date? {
        let whole = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let d = ISO8601DateFormatter().date(from: whole), d > Date(timeIntervalSince1970: 946_684_800) else { return nil }
        return d
    }
}

/// The queue's position: the entry after the Agent the user is on (the
/// focused one a page reports, else the last jump). Neither in the queue
/// starts again at the top. Disconnecting a host removes its runs from the
/// supplied queue without losing the cursor.
public struct AttentionCursor {
    private var last: String?
    public init() {}
    public mutating func selected(_ target: AttentionTarget) { last = target.id }
    public mutating func next(_ queue: [AttentionTarget], current: String? = nil) -> AttentionTarget? {
        guard !queue.isEmpty else { last = nil; return nil }
        let index = [current, last].compactMap { $0 }.lazy.compactMap { id in queue.firstIndex { $0.id == id } }.first
        let item = queue[index.map { ($0 + 1) % queue.count } ?? 0]
        last = item.id
        return item
    }
}

/// FT62-04 「回到刚才」: the waiting question a jump went to, and the App the
/// user was in when ⌃⌥Space, a notification or the panel brought Argo
/// forward. Once that question leaves the queue it is reported once (the page
/// says 「已处理」 and offers the workspace it came from); with nothing left,
/// the next ⌃⌥Space returns to that App. A page that finds the user moved on
/// declines, which forgets both.
public struct AttentionReturn: Equatable, Sendable {
    public struct App: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
    }
    public private(set) var watched: AttentionTarget?
    public private(set) var app: App?
    public init() {}

    /// A jump. Only a waiting question is watched; `from` nil (Argo was
    /// already in front) keeps the App of the walk's first jump.
    public mutating func jumped(to target: AttentionTarget, waiting: Bool, from: App?) {
        if let from { app = from }
        watched = waiting ? target : nil
    }

    /// The watched question left the queue of its live host: returned once.
    /// A host going offline drops its runs from the queue without answering.
    public mutating func handled(_ queue: [AttentionTarget], live: Set<UUID>) -> AttentionTarget? {
        guard let t = watched, live.contains(t.host), !queue.contains(where: { $0.id == t.id }) else { return nil }
        watched = nil
        return t
    }

    public mutating func declined() { watched = nil; app = nil }

    /// Nothing left and nothing watched: the App to go back to, once.
    public mutating func takeApp(_ queue: [AttentionTarget]) -> App? {
        guard queue.isEmpty, watched == nil, let a = app else { return nil }
        app = nil
        return a
    }
}

/// Property-list-safe JSON stored inside a system notification. Options travel
/// with that notification, so a later question cannot change an old button's
/// meaning. macOS displays at most four actions: reply plus three choices;
/// every choice is also available in the menu bar panel.
public struct AttentionNotice: Codable, Sendable {
    public static let replyAction = "loom.reply.text"
    public static let optionPrefix = "loom.reply.option."
    public static let maxOptions = 3
    public let host: UUID
    public let question: AttentionQuestion

    public init(host: UUID, question: AttentionQuestion) { self.host = host; self.question = question }
    public var target: AttentionTarget { question.target(host: host) }

    /// The notification's actions: free text plus up to three choices, none
    /// for a question that takes no reply here (B-01, FT149-02, BG1-21).
    public var replyActions: [(id: String, title: String)] {
        guard question.acceptsReply else { return [] }
        return [(Self.replyAction, "回复…")] + question.options.prefix(Self.maxOptions).enumerated().map { (Self.optionPrefix + String($0.offset), $0.element) }
    }

    /// Body lines for the choices this notification offers that have a note:
    /// "1. 标题：说明", each at most 140 characters like the shell's other
    /// notification summaries (FT76-02).
    public var optionLines: [String] {
        guard question.acceptsReply, let notes = question.optionNotes else { return [] }
        return question.options.prefix(Self.maxOptions).enumerated().compactMap { i, label in
            guard i < notes.count, !notes[i].isEmpty else { return nil }
            let line = "\(i + 1). \(label)：\(notes[i])"
            return line.count <= 140 ? line : String(line.prefix(139)) + "…"
        }
    }

    public func reply(action: String, text: String?) -> String? {
        guard question.acceptsReply else { return nil }
        if action == Self.replyAction {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        guard action.hasPrefix(Self.optionPrefix), let i = Int(action.dropFirst(Self.optionPrefix.count)),
              i >= 0, i < min(Self.maxOptions, question.options.count) else { return nil }
        return question.options[i]
    }

    /// Stable notification identities. The shell replaces or withdraws exactly
    /// the notification it posted; one run keeps one completion and one error.
    public static func waitingIdentifier(host: UUID, run: String, agent: String, questionID: String?) -> String {
        "loom.waiting.\(host.uuidString).\(run).\(agent).\(questionID ?? "unidentified")"
    }
    public static func doneIdentifier(host: UUID, run: String) -> String {
        "loom.done.\(host.uuidString).\(run)"
    }
    public static func errorIdentifier(host: UUID, run: String) -> String {
        "loom.error.\(host.uuidString).\(run)"
    }
    /// FT74-01 / FT79-01: one unexpected end and one closing question per run.
    public static func exitIdentifier(host: UUID, run: String) -> String {
        "loom.exit.\(host.uuidString).\(run)"
    }
    public static func askingIdentifier(host: UUID, run: String) -> String {
        "loom.asking.\(host.uuidString).\(run)"
    }
    /// One notice for many runs failing for the same reason (FT47-03).
    public static func errorGroupIdentifier(host: UUID, key: String?) -> String {
        "loom.errors.\(host.uuidString).\(stableHash(key ?? ""))"
    }

    /// FNV-1a: identifiers must not change between launches (Hasher does).
    private static func stableHash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// MAC-05: the 「继续…」 text reply on a completion notification. The text
/// goes through loomd's Agent message queue (`POST /api/agents/{run}/queue`,
/// docs/api.md v1.22 #6): loomd pastes it and presses Enter when the Agent is
/// idle, queues it while the Agent works or waits on a question, and refuses
/// when the Agent no longer runs in its terminal. The shell never decides
/// that itself.
public struct AgentContinueNotice: Codable, Equatable, Sendable {
    public static let action = "loom.done.continue"
    public static let category = "loom.done"
    /// The panel row kind for a reply that did not go out.
    public static let kind = "continue"
    public let host: UUID
    public let target: AttentionTarget
    /// What the notification said: 「Claude Code 完成了」 and its place line.
    public let title: String
    public let place: String

    public init(host: UUID, target: AttentionTarget, title: String, place: String) {
        self.host = host; self.target = target; self.title = title; self.place = place
    }

    public init?(_ notice: AgentNotification) {
        guard notice.continuable, let target = notice.target else { return nil }
        self.init(host: notice.host, target: target, title: notice.title,
                  place: String(notice.body.split(separator: "\n").first ?? ""))
    }

    /// The reply text, or nil for any other action or blank text.
    public func reply(action: String, text: String?) -> String? {
        guard action == Self.action, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The 「需要我处理」 panel row that keeps a reply which did not go out, so
    /// it can be retried or discarded there like a question reply.
    public func entry(hostName: String) -> AttentionEntry {
        AttentionEntry(host: host, hostName: hostName, question: AttentionQuestion(
            run: target.run, terminal: target.terminal, ws: target.ws, workspace: place, title: title,
            kind: Self.kind, question: "「继续」消息没有送到这个 Agent", questionID: Self.kind))
    }
}

/// `POST /api/agents/{run}/queue`: delivered now, or waiting in the queue.
public struct AgentQueueReceipt: Decodable, Sendable {
    public let delivered: Bool
}

public struct AgentDeliveryReceipt: Decodable, Sendable {
    public let id: String
    public let status: String
}

/// HTTP and event requests use the window's already-established local tunnel.
/// No cookies, cache, system proxy or redirects can move a reply to another
/// host. Question replies go directly to the identity-bound /reply API.
public final class AttentionClient: @unchecked Sendable {
    public let port: Int
    private let token: String
    private let session: URLSession

    public init(port: Int, token: String) {
        self.port = port; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: AttentionRedirectGuard(), delegateQueue: nil)
    }

    public func close() { session.invalidateAndCancel() }

    public func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    public func events() -> URLSessionWebSocketTask {
        var r = request(path: "/api/agents/events")
        r.url = URL(string: "ws://127.0.0.1:\(port)/api/agents/events")!
        let task = session.webSocketTask(with: r)
        task.maximumMessageSize = 1 << 20
        return task
    }

    public func snapshot() async throws -> AttentionSnapshot {
        try await read(request(path: "/api/attention"), as: AttentionSnapshot.self)
    }

    /// The running loomd's live terminals, for the ptyd-protocol upgrade
    /// confirmation (UD-02).
    public func liveTerminals() async throws -> LiveTerminals {
        let (data, response) = try await session.data(for: request(path: "/api/terminals"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoomError.message("远程未能列出终端")
        }
        return try LiveTerminals.parse(data)
    }

    public func send(_ question: AttentionQuestion, text: String) async throws -> AgentDeliveryReceipt {
        try await read(replyRequest(question, text: text), as: AgentDeliveryReceipt.self)
    }

    public func replyRequest(_ question: AttentionQuestion, text: String) throws -> URLRequest {
        guard let id = question.questionID, !id.isEmpty else {
            throw LoomError.message("旧通知缺少问题标识，回复已保留，请查看当前问题")
        }
        let body = try JSONSerialization.data(withJSONObject: ["terminal": question.terminal, "agent": question.agent, "questionID": id, "text": text])
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let run = question.run.addingPercentEncoding(withAllowedCharacters: allowed)!
        return request(path: "/api/agents/\(run)/reply", method: "POST", body: body)
    }

    /// MAC-05: a follow-up message for a run, through loomd's queue (paste and
    /// Enter when idle, queued while it works).
    public func continueRun(_ run: String, text: String) async throws -> AgentQueueReceipt {
        try await read(continueRequest(run, text: text), as: AgentQueueReceipt.self)
    }

    /// Budget guard 「打断」: loomd writes the CLI's own interrupt key
    /// (`POST /api/agents/{run}/interrupt`), the same call the page makes.
    /// The CLI keeps running; only the current turn stops.
    public func interrupt(run: String) async throws {
        guard !run.isEmpty else { throw LoomError.message("通知缺少 Agent 标识") }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let path = run.addingPercentEncoding(withAllowedCharacters: allowed)!
        let (data, response) = try await session.data(for: request(
            path: "/api/agents/\(path)/interrupt", method: "POST", body: Data("{}".utf8)))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoomError.message(LoomError.responseMessage(data, fallback: "没能打断这个 Agent"))
        }
    }

    public func continueRequest(_ run: String, text: String) throws -> URLRequest {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "submit": true, "source": "notification", "when": "auto"])
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let path = run.addingPercentEncoding(withAllowedCharacters: allowed)!
        return request(path: "/api/agents/\(path)/queue", method: "POST", body: body)
    }

    private func read<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LoomError.message(LoomError.responseMessage(data, fallback: "远程未能完成请求，请检查连接与 Argo 版本"))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class AttentionRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Which document a notification target may be delivered to.
///
/// The page is replaced on every reload, reconnect and renderer restart; a
/// click that arrives between `suspend()` and the new document's `ready()`
/// would otherwise run in the old document and be lost when it goes away.
/// Holding it here lets the new page replay it (C1-07).
public struct AttentionDelivery: Equatable, Sendable {
    private var pageReady = false
    private var held: AttentionTarget?

    public init() {}

    /// The document that could receive a target is going away.
    public mutating func suspend() { pageReady = false }

    /// The new document is ready; returns the target held while it loaded.
    public mutating func ready() -> AttentionTarget? {
        pageReady = true
        return take()
    }

    /// Offer a target. Returns it when a ready page can take it now; otherwise
    /// it is held (the newest offer wins, as before) until `ready()`.
    public mutating func deliver(_ target: AttentionTarget) -> AttentionTarget? {
        held = target
        return take()
    }

    private mutating func take() -> AttentionTarget? {
        guard pageReady, let target = held else { return nil }
        held = nil
        return target
    }
}

/// What to do with one `/api/attention` response.
public enum AttentionSnapshotUse: Equatable, Sendable {
    /// A response requested after it was applied already: it is older state.
    case drop
    /// `fresh` is false for a response requested before the latest change of
    /// visibility or switches: it may update state but must not release a
    /// suppressed question or error (R2-5, R2-6, O1, BH-NEXT-02).
    case apply(fresh: Bool)
}

/// Orders the snapshot reloads of one host monitor (O1). Every reload takes a
/// ticket when it is requested, so a slow response cannot overwrite a newer
/// one, and a refresh asked for while one is in flight runs once more after it
/// instead of being dropped.
public struct AttentionRefreshPlan: Sendable {
    private var issued = 0
    private var applied = 0
    private var inputsChangedAt = 0
    private var refreshing = false
    private var again = false

    public init() {}

    /// Take this when a request is sent.
    public mutating func ticket() -> Int {
        issued += 1
        return issued
    }

    /// Visibility or a switch changed: responses to requests sent so far
    /// were taken against the old inputs.
    public mutating func inputsChanged() { inputsChangedAt = issued }

    public mutating func accept(_ ticket: Int) -> AttentionSnapshotUse {
        guard ticket > applied else { return .drop }
        applied = ticket
        return .apply(fresh: ticket > inputsChangedAt)
    }

    /// true: start a refresh now. false: one is in flight; it runs again
    /// when that one finishes.
    public mutating func requestRefresh() -> Bool {
        if refreshing { again = true; return false }
        refreshing = true
        return true
    }

    /// The in-flight refresh finished (or failed). true: start another now.
    public mutating func refreshFinished() -> Bool {
        if again { again = false; return true }
        refreshing = false
        return false
    }
}
