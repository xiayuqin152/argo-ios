import Foundation

/// One run's state in `/api/attention`. The shell diffs these snapshots, so
/// notifications keep working while every window is closed.
public struct AttentionAgent: Decodable, Equatable, Sendable {
    public let run: String
    public let terminal: String
    public let ws: String
    public let workspace: String
    public let title: String
    /// The display name loomd already projects for this run (「Claude Code」
    /// etc.). The shell never maps CLI names itself (OR-4).
    public let label: String?
    public let profile: String
    public let state: String
    public let interrupted: Bool
    public let stateText: String
    public let stateStartedAt: String
    /// A user decision created since the first snapshot may first appear in
    /// waiting state. Ordinary runs retain first-sight history suppression.
    public let notifyNewWaiting: Bool?
    public let errorAt: String?
    public let error: String?
    /// OR-029: background commands still running. Absent (or 0) until loomd
    /// records them; the notification body knows how to say it.
    public let backgroundCommands: Int?
    /// FT18-01: the run's effective level (its own, else its workspace's):
    /// "all", "needs", or absent to follow the host's two switches.
    public let notify: String?
    /// FT74-01: why the launch ended (UD-02's end_reason), loomd's sentence
    /// for it (the page's tooltip text) and whether the user has looked at
    /// the run since. Absent while it runs.
    public let endReason: String?
    public let endText: String?
    public let endUnseen: Bool?
    /// FT79-01: the question a done turn ended with, until the user looks at
    /// the run or it works again.
    public let asking: String?
    /// FT99-02: when a done turn agreed to continue by itself (Claude Code's
    /// ScheduleWakeup); such a turn sends no 「完成了」.
    public let wakeAt: String?
    /// FT74-02: what a completed turn's last reply says, for 「完成了」.
    public let lastReply: String?

    /// The exited launch's code (UD-02), with endReason.
    public let exitCode: Int?

    /// An end the user did not cause: the CLI failed with a non-zero code,
    /// was killed, or is lost on another ptyd. Esc leaves no end; exit 0
    /// (/exit, Ctrl+D, a one-shot Agent that finished, BG105-01), closing the
    /// tab and a ptyd restart (the restore bar) are normal ends.
    public var unexpectedEnd: Bool {
        guard let endReason else { return false }
        if endReason == "exit" { return (exitCode ?? 0) != 0 }
        return ["oom", "ptyd_lost"].contains(endReason) || endReason.hasPrefix("signal:")
    }
    /// FT67-02: the terminal's UI context (its worktree) and the run's
    /// creation time, which tell same-titled Agents apart. Absent from a
    /// loomd that predates them.
    public let context: String?
    public let created: String?
    /// FT146-02: when loomd started suspecting the run stuck or looping
    /// (RFC 3339); absent otherwise and from an older loomd.
    public let stuckSince: String?
    /// FT129-03: the prompt cache's expiry, for the panel's hint and order.
    /// Absent when the CLI reports none.
    public let cacheExpiresAt: String?
    /// External Claude's latest input tokens and the inferred TTL tier.
    public let cacheTokens: Int?
    public let cacheTTLSeconds: Int?
    /// D81: finished and not yet seen, for the 「下一个等你处理的 Agent」 queue
    /// (stuck comes from `stuckSince`). Absent from an older loomd.
    public let unread: Bool?
    /// Budget guard: the identity (its announcement time) of the latest
    /// time/token/cost threshold the run crossed, and the sentence to show.
    /// Present only while the run works; absent from an older loomd and from
    /// a run without a budget notice.
    public let budgetAt: String?
    public let budgetKind: String?
    public let budgetText: String?

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        if !title.isEmpty { return title }
        return profile.isEmpty ? "Agent" : profile
    }

    public init(run: String, terminal: String, ws: String, workspace: String, title: String,
                label: String? = nil, profile: String = "", state: String,
                interrupted: Bool = false, stateText: String = "", stateStartedAt: String = "",
                errorAt: String? = nil, error: String? = nil, backgroundCommands: Int? = nil,
                context: String? = nil, created: String? = nil, notify: String? = nil,
                endReason: String? = nil, endText: String? = nil,
                endUnseen: Bool? = nil, asking: String? = nil, wakeAt: String? = nil, exitCode: Int? = nil, lastReply: String? = nil,
                stuckSince: String? = nil, unread: Bool? = nil, cacheExpiresAt: String? = nil,
                cacheTokens: Int? = nil, cacheTTLSeconds: Int? = nil,
                budgetAt: String? = nil, budgetKind: String? = nil, budgetText: String? = nil,
                notifyNewWaiting: Bool? = nil) {
        self.run = run; self.terminal = terminal; self.ws = ws; self.workspace = workspace
        self.title = title; self.label = label; self.profile = profile; self.state = state
        self.interrupted = interrupted; self.stateText = stateText
        self.stateStartedAt = stateStartedAt; self.errorAt = errorAt; self.error = error
        self.notifyNewWaiting = notifyNewWaiting
        self.backgroundCommands = backgroundCommands
        self.notify = notify
        self.endReason = endReason; self.endText = endText; self.endUnseen = endUnseen; self.asking = asking
        self.wakeAt = wakeAt; self.exitCode = exitCode; self.lastReply = lastReply
        self.context = context; self.created = created; self.stuckSince = stuckSince
        self.cacheExpiresAt = cacheExpiresAt
        self.cacheTokens = cacheTokens; self.cacheTTLSeconds = cacheTTLSeconds
        self.unread = unread
        self.budgetAt = budgetAt; self.budgetKind = budgetKind; self.budgetText = budgetText
    }
}

/// Sounds bundled with macOS. `systemDefault` stays on UNNotificationSound so
/// the user's system alert choice is respected; named sounds use NSSound in the
/// AppKit shell because UNNotificationSound has no per-notification volume.
public enum AgentNotificationSound: String, CaseIterable, Equatable, Sendable {
    case systemDefault = "default"
    case glass, hero, ping, pop, submarine
    case none

    public var soundName: String? {
        switch self {
        case .glass: return "Glass"
        case .hero: return "Hero"
        case .ping: return "Ping"
        case .pop: return "Pop"
        case .submarine: return "Submarine"
        case .systemDefault, .none: return nil
        }
    }
}

public struct AgentNotificationSettings: Equatable, Sendable {
    /// 「需要你时通知（提问、出错）」
    public var needsYou: Bool
    /// 「完成时通知」; generic terminal signals use this switch too.
    public var done: Bool
    /// 「把以问句结尾的完成也当作等你回答」 under 「需要你时通知」 (FT79-01).
    public var asking: Bool
    /// 「通知里显示 Agent 最后一句话」 under 「完成时通知」 (FT74-02).
    public var reply: Bool
    public var needsYouSound: AgentNotificationSound
    public var needsYouVolume: Int
    /// Done stays silent by default, preserving FT5-02's existing behaviour.
    public var doneSound: AgentNotificationSound
    public var doneVolume: Int

    public init(needsYou: Bool = true, done: Bool = true, asking: Bool = true, reply: Bool = true,
                needsYouSound: AgentNotificationSound = .systemDefault, needsYouVolume: Int = 100,
                doneSound: AgentNotificationSound = .none, doneVolume: Int = 100) {
        self.needsYou = needsYou; self.done = done; self.asking = asking; self.reply = reply
        self.needsYouSound = needsYouSound; self.needsYouVolume = Self.normalizedVolume(needsYouVolume)
        self.doneSound = doneSound; self.doneVolume = Self.normalizedVolume(doneVolume)
    }

    public static func normalizedVolume(_ value: Int) -> Int { min(100, max(0, value)) }

    public func sound(for kind: AgentNotificationKind) -> (sound: AgentNotificationSound, volume: Int) {
        kind == .done ? (doneSound, doneVolume) : (needsYouSound, needsYouVolume)
    }

    /// Apply only the sound group from a page message. An older page does not
    /// send it and therefore cannot reset what a newer page already saved.
    public mutating func applySounds(from other: AgentNotificationSettings) {
        needsYouSound = other.needsYouSound; needsYouVolume = other.needsYouVolume
        doneSound = other.doneSound; doneVolume = other.doneVolume
    }

    /// The switches for one Agent or terminal at `level` (FT18-01).
    /// 「做完也通知我」 turns both on; 「只在需要我时通知」 keeps the needs-you class
    /// and drops done, so a blocking question or error is never muted per
    /// Agent. Any other value follows the host's switches. loomd's
    /// notify.Personal is the same table (Fixtures/notify-levels.json).
    public func applying(_ level: String?) -> AgentNotificationSettings {
        var result = self
        switch level {
        case "all": result.needsYou = true; result.done = true
        case "needs": result.needsYou = true; result.done = false
        default: break
        }
        return result
    }
}

public enum AgentNotificationKind: String, Equatable, Sendable {
    case waiting, done, error
    /// A run crossed a user-set budget threshold. Needs-you class: it keeps
    /// the needs-you sound and is never muted by 「只在需要我时通知」.
    case budget
}

/// FT5-02: how loudly a notice arrives. A done notice only goes to
/// Notification Center (no sound, no lit screen); waiting and error stay
/// active and rank above it in the grouped summary. The system's Focus modes
/// then apply on their own; `.timeSensitive` would need an entitlement.
public struct NotificationPresentation: Equatable, Sendable {
    public let passive: Bool
    /// UNNotificationContent.relevanceScore, 0...1.
    public let relevance: Double
}

extension AgentNotificationKind {
    public var presentation: NotificationPresentation {
        switch self {
        case .waiting: return NotificationPresentation(passive: false, relevance: 1)
        case .error: return NotificationPresentation(passive: false, relevance: 0.8)
        case .budget: return NotificationPresentation(passive: false, relevance: 0.9)
        case .done: return NotificationPresentation(passive: true, relevance: 0.2)
        }
    }
}

/// A ready-to-post system notification. Every identifier is stable, so the
/// shell can replace or withdraw exactly the notification it posted.
public struct AgentNotification: Equatable, Sendable {
    public let identifier: String
    public let kind: AgentNotificationKind
    public let title: String
    public let body: String
    public let host: UUID
    /// nil for a plain terminal signal: there is no Agent run to locate.
    public let target: AttentionTarget?
    public let threadIdentifier: String
    /// Only waiting notices carry reply actions.
    public let question: AttentionQuestion?
    /// FT21-02: the notice offers 「换 CLI 接着做…」 (`switchCLIAction`).
    public let offersSwitchCLI: Bool
    /// Budget guard: the notice offers 继续观察 / 打开会话 / 打断.
    public let offersBudget: Bool
    /// An update of a notice already on screen (a grouped error's count):
    /// it replaces the content without another sound.
    public let silent: Bool

    /// The notification action identifier of 「换 CLI 接着做…」.
    public static let switchCLIAction = "loom.switchCLI"

    public init(identifier: String, kind: AgentNotificationKind, title: String, body: String,
                host: UUID, target: AttentionTarget?, threadIdentifier: String, question: AttentionQuestion? = nil,
                offersSwitchCLI: Bool = false, offersBudget: Bool = false, silent: Bool = false) {
        self.identifier = identifier; self.kind = kind; self.title = title; self.body = body
        self.host = host; self.target = target; self.threadIdentifier = threadIdentifier; self.question = question
        self.offersSwitchCLI = offersSwitchCLI
        self.offersBudget = offersBudget
        self.silent = silent
    }

    /// MAC-05: a managed run's completion takes a 「继续…」 reply. A plain
    /// terminal signal has no run to queue the message for.
    public var continuable: Bool { kind == .done && target != nil }
}

public enum AgentNotificationEffect: Equatable, Sendable {
    case post(AgentNotification)
    case withdraw([String])
}

/// A plain terminal signal (a hand-started CLI's waiting/done marker) for the
/// shell's notification rules (D58).
public enum TerminalSignalKind: String, Equatable, Sendable {
    case waiting, done
}

/// The page's `terminalSignal` bridge message as the shell receives it (a
/// WKScriptMessage body). The shape is pinned by
/// Tests/LoomKitTests/Fixtures/terminal-signal.json, which the page's tests
/// produce too (R4-3).
public struct TerminalSignalMessage: Equatable, Sendable {
    public let kind: TerminalSignalKind
    public let terminal: String
    public let title: String
    public let body: String
    /// FT18-01: the level of the terminal's workspace, which the page knows
    /// and loomd's snapshot does not carry for a hand-started CLI.
    public let notify: String?
    /// Manual CLI states come from the host snapshot. The page's signal
    /// requests that snapshot, so one transition produces one notification.
    public let manualAgent: Bool

    /// nil for an unknown kind or a missing terminal; title and body are
    /// capped like every other notification text.
    public init?(body message: [String: Any]) {
        guard let raw = message["kind"] as? String, let kind = TerminalSignalKind(rawValue: raw),
              let terminal = message["terminal"] as? String, !terminal.isEmpty else { return nil }
        self.kind = kind
        self.terminal = terminal
        title = String(((message["title"] as? String) ?? "终端").prefix(200))
        body = String(((message["body"] as? String) ?? "").prefix(1000))
        notify = message["notify"] as? String
        manualAgent = message["manualAgent"] as? Bool == true
    }
}

/// A one-off page event that must still follow the shell's notification rules
/// (fixed id, visible suppression, withdraw once seen): currently only the
/// stopped automatic continuation (D57/N-6).
public enum AgentExternalNoticeKind: String, Equatable, Sendable {
    case autoResumeStopped
    /// An SCM build the Agent submitted itself ended (FT108-01).
    case scmBuild
}

/// The single set of local-notification rules (D54/D57): waiting and error
/// notify at once, done after 1.5 s, the first sight of a run never notifies,
/// an error notifies once per identity, and a run whose terminal is visible in
/// a focused window never notifies (a question seen this way is delivered once
/// the user leaves while it is still unanswered). It is pure: callers deliver
/// effects and schedule `tick` at `nextDeadline`.
public struct AgentNotifier: Sendable {
    public static let doneDelay: TimeInterval = 1.5
    /// FT47-03: errors with the same first line on this many runs within
    /// `errorGroupWindow` are one upstream problem and get one notice.
    public static let errorGroupMin = 3
    public static let errorGroupWindow: TimeInterval = 20

    private let host: UUID
    private var previousState: [String: String] = [:]
    private var receivedSnapshot = false
    private var pendingDone: [String: (deadline: Date, agent: AttentionAgent, reply: Bool)] = [:]
    private var errorIdentities: [String: String] = [:]
    private var handledWaiting: [String: Set<String>] = [:]
    private var delivered: [String: Set<String>] = [:]
    /// Plain terminal notices live by terminal id; they are withdrawn when the
    /// terminal is on screen, even though it has no Agent run.
    private var deliveredTerminals: [String: Set<String>] = [:]
    private var externalIdentities: [String: String] = [:]
    /// run → the SCM builds already posted for it, so another window or a
    /// reload reporting the same build posts nothing (FT108-01).
    private var scmPosted: [String: Set<String>] = [:]
    /// run → the budget notice identity already handled (its announcement
    /// time). One notice per crossing; a raised threshold brings a new one.
    private var budgetPosted: [String: String] = [:]
    /// FT56-03: each race's settled state as last seen, and the race notices
    /// delivered (by race id).
    private var raceSettled: [String: Bool] = [:]
    private var deliveredRaces: [String: String] = [:]
    /// The latest visibility report; a done delay rechecks it when it fires.
    private var visible: Set<String> = []
    private var visibleTerminals: Set<String> = []
    /// Single notices of the last `errorGroupWindow` (errors, and FT74-01's
    /// unexpected ends under keys of their own), by group key.
    private var recentErrors: [(run: String, key: String, at: Date, agent: AttentionAgent, id: String)] = []
    private var errorGroups: [String: ErrorGroup] = [:]
    /// FT74-01/FT79-01: each run's unexpected end ("" for none) and closing
    /// question ("" for none, or with the sub-switch off) in the last snapshot.
    private var previousEnd: [String: String] = [:]
    private var previousAsking: [String: String] = [:]
    /// FT99-02/BG118-01: done turns whose 「完成了」 a wakeAt held back; sent
    /// if loomd drops the wakeAt (the CLI exited) while the run is still done.
    private var heldForWakeup: Set<String> = []

    private struct ErrorGroup: Sendable {
        var runs: [String: AttentionAgent]
        var lastAt: Date
        var firstLine: String
        /// Runs that ended the same way (FT74-01), not failed the same way.
        var exit = false
    }
    /// run → the suffix of a same-titled Agent (FT67-02), from the latest snapshot.
    private var nameTags: [String: String] = [:]

    public init(host: UUID) { self.host = host }

    /// The next moment `tick` can produce a done notification; nil when none.
    public var nextDeadline: Date? { pendingDone.values.map(\.deadline).min() }

    /// Apply one snapshot. `questions` is the snapshot's waiting list, used
    /// for reply actions; the agents themselves decide which states changed.
    /// `complete` is false while some run's first transcript read is still in
    /// flight: such a snapshot must not look like a deletion. A run missing
    /// from `agents` and not named in `unreadable` is a deleted terminal
    /// (R2-1). `fresh` is false for a visibility/settings-only evaluation: a
    /// question or error is released only after a new snapshot (R2-5, R2-6).
    public mutating func update(_ agents: [AttentionAgent], questions: [AttentionQuestion],
                                visible: Set<String>, settings: AgentNotificationSettings,
                                now: Date, complete: Bool = true, unreadable: Set<String> = [],
                                fresh: Bool = true, visibleTerminals: Set<String> = []) -> [AgentNotificationEffect] {
        var effects: [AgentNotificationEffect] = []
        let firstSnapshot = !receivedSnapshot
        if fresh { receivedSnapshot = true }
        self.visible = visible
        self.visibleTerminals = visibleTerminals
        nameTags = AgentNameTags.tags(for: agents)
        let runs = Set(agents.map(\.run))
        if complete {
            // An unreadable run is missing from agents for a reason that is
            // not deletion; a present run in error state is unrelated to this
            // decision (R2-1).
            var missing: [String] = []
            for run in previousState.keys where !runs.contains(run) && !unreadable.contains(run) {
                missing.append(run)
            }
            for run in missing { effects += forget(run: run) }
        }

        let hostSettings = settings
        for agent in agents {
            let run = agent.run
            let settings = hostSettings.applying(agent.notify)
            let before = previousState[run]
            previousState[run] = agent.state
            let watching = visible.contains(run) || (run.hasPrefix("unmanaged:") && visibleTerminals.contains(agent.terminal))
            // FT74-01/FT79-01 change on their own, also without a state change
            // (an idle CLI killed at its prompt stays done).
            let end = agent.unexpectedEnd ? (agent.endReason ?? "") : ""
            let endBefore = previousEnd.updateValue(end, forKey: run) ?? end
            let ask = settings.asking ? (agent.asking ?? "") : ""
            let askBefore = previousAsking.updateValue(ask, forKey: run) ?? ask

            // The first sight of a run says nothing: a reload, a restart and a
            // reconnect must not replay what already happened. Viewing a
            // question acknowledges its reminder, even if it remains waiting.
            guard let before else {
                if agent.state == "waiting", agent.notifyNewWaiting == true, fresh, !firstSnapshot {
                    effects += waitingEffects(agent, questions: questions, watching: watching, settings: settings)
                    continue
                }
                // An old budget notice is history, not news: the first sight
                // of a run records it without posting.
                if let at = agent.budgetAt, !at.isEmpty { budgetPosted[run] = at }
                if agent.state == "waiting" {
                    for question in questions where question.run == run {
                        handledWaiting[run, default: []].insert(waitingIdentifier(agent, question))
                    }
                }
                continue
            }
            // Budget guard: one notice per crossed threshold. loomd writes
            // the crossing before the snapshot carries it, so the identity is
            // stable across reloads and reconnects. A visible run shows the
            // pane chip instead; leaving while it still works delivers the
            // notice then (like an error seen while watching).
            if let at = agent.budgetAt, !at.isEmpty, budgetPosted[run] != at,
               settings.needsYou, !watching, fresh {
                budgetPosted[run] = at
                effects.append(.post(budgetNotice(agent, identity: at)))
            }
            if end != endBefore {
                effects += withdrawExit(run)
                if !end.isEmpty, settings.needsYou, !watching { effects += exitEffects(agent, now: now) }
            }
            if ask != askBefore {
                effects += withdrawID(askingIdentifier(run), run: run)
                if !ask.isEmpty, settings.needsYou, !watching {
                    // In place of 「完成了」: the turn did not finish, it asks.
                    pendingDone.removeValue(forKey: run)
                    effects.append(postAsking(agent, ask))
                }
            }

            if before == agent.state {
                if agent.state == "done", heldForWakeup.contains(run), (agent.wakeAt ?? "").isEmpty {
                    heldForWakeup.remove(run)
                    if settings.done, !watching {
                        let notice = doneNotice(agent, reply: settings.reply)
                        delivered[run, default: []].insert(notice.identifier)
                        effects.append(.post(notice))
                    }
                }
                if agent.state == "done", var pending = pendingDone[run] {
                    // The background count can arrive within the 1.5 s delay;
                    // the notice must use the latest snapshot (N-9).
                    pending.agent = agent
                    pendingDone[run] = pending
                }
                if agent.state == "waiting", fresh || watching { // another member may have asked
                    effects += withdrawAnswered(agent, questions: questions)
                    effects += waitingEffects(agent, questions: questions, watching: watching, settings: settings)
                }
                if agent.state == "error", fresh, settings.needsYou, !watching, !agent.unexpectedEnd {
                    // R2-6: an error that arrived while watched is delivered
                    // once the user leaves, after a new snapshot.
                    let identity = agent.errorAt ?? agent.stateStartedAt
                    if !identity.isEmpty, errorIdentities[run] != identity {
                        errorIdentities[run] = identity
                        effects += errorEffects(agent, now: now)
                    }
                }
                continue
            }

            // Leaving a state withdraws exactly what that state posted. A run
            // that stopped being done before the 1.5 s elapsed never notifies.
            effects += withdraw(kind: kind(of: before), run: run)
            if before == "error" { effects += leaveErrorGroup(run) }
            if agent.state != "done" { pendingDone.removeValue(forKey: run); heldForWakeup.remove(run) }

            switch agent.state {
            case "waiting":
                effects += waitingEffects(agent, questions: questions, watching: watching, settings: settings)
            case "error":
                // An error because the CLI ended is told as that end (FT74-01).
                if settings.needsYou, !agent.unexpectedEnd {
                    let identity = agent.errorAt ?? agent.stateStartedAt
                    let same = !identity.isEmpty && errorIdentities[run] == identity
                    if !same && !watching {
                        // Record only a delivered identity: a watched error is
                        // still undelivered and is released on a later snapshot.
                        if !identity.isEmpty { errorIdentities[run] = identity }
                        effects += errorEffects(agent, now: now)
                    }
                }
            case "done" where !agent.interrupted:
                if settings.done, !(settings.needsYou && !ask.isEmpty) {
                    pendingDone[run] = (now.addingTimeInterval(Self.doneDelay), agent, settings.reply)
                }
            default:
                break
            }
        }

        // A run that is visible right now is being read: withdraw its notices.
        for run in visible.sorted() {
            effects += withdrawAll(run: run)
            effects += leaveErrorGroup(run)
        }
        // The same for a plain terminal, which has no Agent run.
        for terminal in visibleTerminals.sorted() {
            effects += withdrawTerminal(terminal)
        }
        return effects
    }

    /// FT56-03: one 「都做完了，可以对比了」 per race, when a race seen
    /// unsettled becomes settled. Like a run, the first sight of a race says
    /// nothing. A settled race uses the done switch (the needs-you switch when
    /// nobody reported done); a race that left the list (picked, aged out or
    /// deleted) withdraws its notice. The members' own completions are not in
    /// the snapshot at all: background tasks have no terminal.
    public mutating func updateRaces(_ races: [AttentionRace],
                                     settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        var effects: [AgentNotificationEffect] = []
        let ids = Set(races.map(\.id))
        for id in raceSettled.keys.sorted() where !ids.contains(id) {
            raceSettled.removeValue(forKey: id)
            if let notice = deliveredRaces.removeValue(forKey: id) { effects.append(.withdraw([notice])) }
        }
        for race in races {
            let before = raceSettled[race.id]
            raceSettled[race.id] = race.settled
            guard before == false, race.settled else { continue }
            let failed = race.failed ?? false
            guard failed ? settings.needsYou : settings.done else { continue }
            let id = "loom.race.\(host.uuidString).\(race.id)"
            deliveredRaces[race.id] = id
            effects.append(.post(AgentNotification(
                identifier: id, kind: failed ? .error : .done,
                title: race.title ?? "同题对比 \(race.id) 都结束了",
                body: [race.workspace, race.body ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                host: host, target: AttentionTarget(host: host, ws: race.ws, run: "", terminal: "", race: race.id),
                threadIdentifier: "\(host.uuidString).race.\(race.id)")))
        }
        return effects
    }

    /// Fire done notifications whose 1.5 s delay has passed.
    public mutating func tick(now: Date) -> [AgentNotificationEffect] {
        var effects: [AgentNotificationEffect] = []
        for (run, pending) in pendingDone.sorted(by: { $0.value.deadline < $1.value.deadline }) where pending.deadline <= now {
            pendingDone.removeValue(forKey: run)
            guard previousState[run] == "done", !visible.contains(run) else { continue }
            // FT99-02: it agreed to continue by itself (also when loomd's
            // wakeAt arrived after the Stop, inside the delay).
            guard (pending.agent.wakeAt ?? "").isEmpty else { heldForWakeup.insert(run); continue }
            let notice = doneNotice(pending.agent, reply: pending.reply)
            delivered[run, default: []].insert(notice.identifier)
            effects.append(.post(notice))
        }
        return effects
    }

    /// A page event (automatic continuation stopped) posted under the same
    /// fixed id and visibility rules as a state notice (D57/N-6). `identity`
    /// is the event's own timestamp, so a page reload reporting the same
    /// event does not post it again (R2-3).
    public mutating func externalNotice(_ kind: AgentExternalNoticeKind, agent: AttentionAgent,
                                        identity: String,
                                        settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        guard kind == .autoResumeStopped, settings.applying(agent.notify).needsYou, !visible.contains(agent.run) else { return [] }
        if !identity.isEmpty, externalIdentities[agent.run] == identity { return [] }
        if !identity.isEmpty { externalIdentities[agent.run] = identity }
        let notice: AgentNotification
        switch kind {
        case .scmBuild:
            return [] // scmBuild(agent:…) carries the build's text
        case .autoResumeStopped:
            let place = place(agent)
            notice = AgentNotification(
                identifier: "loom.notice.\(host.uuidString).\(agent.run).\(kind.rawValue)",
                kind: .error, title: "\(agent.displayName) 自动续跑已停止",
                body: "\(place)\n已连续自动续跑 3 次仍失败，已停止，请手动处理",
                host: host, target: target(of: agent),
                threadIdentifier: "\(host.uuidString).\(agent.run)", offersSwitchCLI: true)
        }
        delivered[agent.run, default: []].insert(notice.identifier)
        return [.post(notice)]
    }

    /// An SCM build the Agent submitted itself ended (FT108-01). The page
    /// gives the text; the rules are the Agent's: a failure follows
    /// 「需要你时通知」 and a success 「完成时通知」, a visible run never
    /// notifies, each build posts once under its own id, and seeing the run
    /// withdraws it. Its id is not a state notice's, so the Agent's own state
    /// changes never withdraw it.
    public mutating func scmBuild(agent: AttentionAgent, build: String, ok: Bool, title: String, body: String,
                                  settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        let settings = settings.applying(agent.notify) // the Agent's own level (FT18-01)
        guard !build.isEmpty, ok ? settings.done : settings.needsYou, !visible.contains(agent.run),
              !(scmPosted[agent.run]?.contains(build) ?? false) else { return [] }
        scmPosted[agent.run, default: []].insert(build)
        let notice = AgentNotification(
            identifier: "loom.scm.\(host.uuidString).\(agent.run).\(build)",
            kind: ok ? .done : .error, title: String(title.prefix(200)),
            body: "\(place(agent))\n\(String(body.prefix(1000)))",
            host: host, target: target(of: agent), threadIdentifier: "\(host.uuidString).\(agent.run)")
        delivered[agent.run, default: []].insert(notice.identifier)
        return [.post(notice)]
    }

    /// A hand-started CLI's waiting/done signal. The shell owns the switch,
    /// the fixed id and the visible check (D58/R2-2).
    public mutating func terminalSignal(_ kind: TerminalSignalKind, terminal: String,
                                        title: String, body: String,
                                        settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        switch kind {
        case .waiting: guard settings.needsYou else { return [] }
        case .done: guard settings.done else { return [] }
        }
        guard !visibleTerminals.contains(terminal) else { return [] }
        let id = "loom.terminal.\(host.uuidString).\(terminal).\(kind.rawValue)"
        let notice = AgentNotification(
            identifier: id, kind: kind == .waiting ? .waiting : .done,
            title: title, body: body, host: host, target: nil,
            threadIdentifier: "\(host.uuidString).\(terminal)")
        deliveredTerminals[terminal, default: []].insert(id)
        return [.post(notice)]
    }

    /// Withdraw everything delivered for a run and forget its state. Called
    /// when the run is deleted and when its host is removed (N-4).
    public mutating func forget(run: String) -> [AgentNotificationEffect] {
        var effects: [AgentNotificationEffect] = []
        if let ids = delivered.removeValue(forKey: run), !ids.isEmpty {
            effects.append(.withdraw(ids.sorted()))
        }
        effects += leaveErrorGroup(run)
        previousState.removeValue(forKey: run)
        previousEnd.removeValue(forKey: run)
        previousAsking.removeValue(forKey: run)
        heldForWakeup.remove(run)
        pendingDone.removeValue(forKey: run)
        errorIdentities.removeValue(forKey: run)
        externalIdentities.removeValue(forKey: run)
        scmPosted.removeValue(forKey: run)
        budgetPosted.removeValue(forKey: run)
        handledWaiting.removeValue(forKey: run)
        return effects
    }

    /// Withdraw every notice this host delivered, for host removal.
    public mutating func withdrawAll() -> [AgentNotificationEffect] {
        let groups = errorGroups.keys.map { AttentionNotice.errorGroupIdentifier(host: host, key: $0) }
        let ids = (delivered.values.flatMap { $0 } + deliveredTerminals.values.flatMap { $0 } + Array(deliveredRaces.values) + groups).sorted()
        delivered.removeAll()
        deliveredTerminals.removeAll()
        deliveredRaces.removeAll()
        errorGroups.removeAll()
        recentErrors.removeAll()
        return ids.isEmpty ? [] : [.withdraw(ids)]
    }

    // MARK: Grouped errors (FT47-03)

    /// The identity of an error's cause: its first line without the parts
    /// that differ per request (UUIDs, long hex or digit runs, times and
    /// dates). Short numbers such as HTTP status codes stay. nil: no text to
    /// compare, so the error is never grouped.
    public static func errorKey(_ error: String?) -> String? {
        let first = (error ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !first.isEmpty else { return nil }
        var key = first.lowercased()
        for pattern in [#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
                        #"\d{4}-\d{2}-\d{2}[t ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(z|[+-]\d{2}:?\d{2})?"#,
                        #"\b\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\b"#,
                        #"\b(?=[0-9a-f]*\d)[0-9a-f]{8,}\b"#, #"\d{5,}"#] {
            key = key.replacingOccurrences(of: pattern, with: "#", options: .regularExpression)
        }
        return key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One run's error notice. A third run failing with the same key within
    /// the window turns the singles into one group notice; while the group is
    /// fresh, later runs only update its count, without a sound.
    private mutating func errorEffects(_ agent: AttentionAgent, now: Date) -> [AgentNotificationEffect] {
        grouped(agent, key: Self.errorKey(agent.error), firstLine: Self.firstLine(agent.error),
                single: errorNotice(agent), exit: false, now: now)
    }

    /// FT74-01: an unexpected end, grouped by FT47-03's rule with the runs
    /// that ended the same way (the sentence without the per-run memory
    /// reading). A lost run is never grouped: the group opens the overview,
    /// where a run without a terminal here is not shown.
    private mutating func exitEffects(_ agent: AttentionAgent, now: Date) -> [AgentNotificationEffect] {
        let headline = Self.exitHeadline(agent)
        let key = agent.endReason == "ptyd_lost" || headline.isEmpty ? nil : "exit\u{1}" + headline
        return grouped(agent, key: key, firstLine: headline, single: exitNotice(agent), exit: true, now: now)
    }

    private mutating func grouped(_ agent: AttentionAgent, key: String?, firstLine: String,
                                  single: AgentNotification, exit: Bool, now: Date) -> [AgentNotificationEffect] {
        recentErrors.removeAll { now.timeIntervalSince($0.at) > Self.errorGroupWindow }
        guard let key else { return [post(single, run: agent.run)] }
        if var group = errorGroups[key], now.timeIntervalSince(group.lastAt) <= Self.errorGroupWindow {
            group.runs[agent.run] = agent
            group.lastAt = now
            errorGroups[key] = group
            return [.post(groupNotice(key, group, silent: true))]
        }
        let same = recentErrors.filter { $0.key == key && $0.run != agent.run }
        guard Set(same.map(\.run)).count + 1 >= Self.errorGroupMin else {
            recentErrors.append((agent.run, key, now, agent, single.identifier))
            return [post(single, run: agent.run)]
        }
        var group = errorGroups[key] ?? ErrorGroup(runs: [:], lastAt: now, firstLine: firstLine, exit: exit)
        var singles: [String] = []
        for entry in same {
            group.runs[entry.run] = entry.agent
            let id = entry.id
            if delivered[entry.run]?.remove(id) != nil { singles.append(id) }
            if delivered[entry.run]?.isEmpty == true { delivered.removeValue(forKey: entry.run) }
        }
        group.runs[agent.run] = agent
        group.lastAt = now
        errorGroups[key] = group
        recentErrors.removeAll { $0.key == key }
        var effects: [AgentNotificationEffect] = singles.isEmpty ? [] : [.withdraw(singles.sorted())]
        effects.append(.post(groupNotice(key, group, silent: false)))
        return effects
    }

    private mutating func post(_ notice: AgentNotification, run: String) -> AgentNotificationEffect {
        delivered[run, default: []].insert(notice.identifier)
        return .post(notice)
    }

    /// A run that recovered, was seen or was deleted no longer counts; the
    /// last one out withdraws the group notice.
    private mutating func leaveErrorGroup(_ run: String) -> [AgentNotificationEffect] {
        recentErrors.removeAll { $0.run == run }
        var effects: [AgentNotificationEffect] = []
        for (key, var group) in errorGroups where group.runs[run] != nil {
            group.runs.removeValue(forKey: run)
            if group.runs.isEmpty {
                errorGroups.removeValue(forKey: key)
                effects.append(.withdraw([AttentionNotice.errorGroupIdentifier(host: host, key: key)]))
            } else {
                errorGroups[key] = group
            }
        }
        return effects
    }

    private func groupNotice(_ key: String, _ group: ErrorGroup, silent: Bool) -> AgentNotification {
        let names = group.runs.keys.sorted().compactMap { group.runs[$0] }
            .map { $0.title.isEmpty ? $0.displayName : $0.title }
        let shown = names.prefix(3).joined(separator: "、") + (names.count > 3 ? " 等" : "")
        if group.exit {
            return AgentNotification(
                identifier: AttentionNotice.errorGroupIdentifier(host: host, key: key), kind: .error,
                title: "\(group.runs.count) 个 Agent 意外退出了",
                body: "\(group.firstLine)\n\(shown)\n可以续接",
                host: host, target: AttentionTarget(host: host, ws: "", run: "", terminal: "", view: AttentionTarget.exitedView),
                threadIdentifier: "\(host.uuidString).exits", silent: silent)
        }
        return AgentNotification(
            identifier: AttentionNotice.errorGroupIdentifier(host: host, key: key), kind: .error,
            title: "\(group.runs.count) 个 Agent 同时出错",
            body: "\(group.firstLine)\n\(shown)\n可能是网关或上游的问题",
            host: host, target: AttentionTarget(host: host, ws: "", run: "", terminal: "", view: AttentionTarget.errorsView),
            threadIdentifier: "\(host.uuidString).errors", silent: silent)
    }

    /// The way a run ended without its per-run reading: loomd's sentence up
    /// to the 「；当时…」 memory part.
    private static func exitHeadline(_ agent: AttentionAgent) -> String {
        String((agent.endText ?? "").split(separator: "；", maxSplits: 1).first ?? "")
    }

    private static func firstLine(_ error: String?) -> String {
        let first = (error ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(first.prefix(300))
    }

    // MARK: Notices

    private mutating func waitingEffects(_ agent: AttentionAgent, questions: [AttentionQuestion],
                                         watching: Bool,
                                         settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        guard settings.needsYou else {
            for question in questions where question.run == agent.run {
                handledWaiting[agent.run, default: []].insert(waitingIdentifier(agent, question))
            }
            return []
        }
        var effects: [AgentNotificationEffect] = []
        for question in questions where question.run == agent.run {
            let id = waitingIdentifier(agent, question)
            if watching || !question.needsReminder {
                handledWaiting[agent.run, default: []].insert(id)
                effects += withdrawID(id, run: agent.run)
                continue
            }
            if handledWaiting[agent.run, default: []].contains(id) { continue }
            handledWaiting[agent.run, default: []].insert(id)
            let place = place(agent)
            let body = ([place, question.question].filter { !$0.isEmpty }).joined(separator: "\n")
            delivered[agent.run, default: []].insert(id)
            // B-01: a browser ask-user names what to do, and where; FT62-02: a
            // permission request is approved, not answered.
            let title = question.isBrowser ? "\(agent.displayName) 等你在浏览器里操作"
                : question.isPermission ? "\(agent.displayName) 要你批准" : "\(agent.displayName) 在等你回答"
            effects.append(.post(AgentNotification(
                identifier: id, kind: .waiting, title: title,
                body: body, host: host, target: question.target(host: host),
                threadIdentifier: "\(host.uuidString).\(agent.run)", question: question)))
        }
        return effects
    }

    private func doneNotice(_ agent: AttentionAgent, reply: Bool) -> AgentNotification {
        var body = place(agent)
        // FT74-02: what the turn's last reply says (loomd masks and cuts it).
        if reply, let text = agent.lastReply, !text.isEmpty { body += "\n" + text }
        if let background = agent.backgroundCommands, background > 0 {
            body += "\n后台还有 \(background) 个命令在运行，完成后 Agent 可能会继续"
        }
        return AgentNotification(
            identifier: doneIdentifier(agent.run), kind: .done,
            title: "\(agent.displayName) 完成了", body: body,
            host: host, target: target(of: agent), threadIdentifier: "\(host.uuidString).\(agent.run)")
    }

    private func errorNotice(_ agent: AttentionAgent) -> AgentNotification {
        let text = [agent.stateText.isEmpty ? "出错" : agent.stateText, Self.firstLine(agent.error)]
            .filter { !$0.isEmpty }.joined(separator: "：")
        return AgentNotification(
            identifier: errorIdentifier(agent.run), kind: .error,
            title: "\(agent.displayName) 出错了", body: "\(place(agent))\n\(text)",
            host: host, target: target(of: agent), threadIdentifier: "\(host.uuidString).\(agent.run)")
    }

    /// FT74-01: 「意外退出了」 with loomd's sentence and what to do next. A run
    /// lost on another ptyd still runs there: it 「失联了」, and its click goes
    /// to the session library, where it can be forked.
    private func exitNotice(_ agent: AttentionAgent) -> AgentNotification {
        let lost = agent.endReason == "ptyd_lost"
        let lines = [place(agent), agent.endText ?? "", lost ? "可以在历史会话里分叉接着做" : "可以续接"]
        return AgentNotification(
            identifier: exitIdentifier(agent.run), kind: .error,
            title: lost ? "\(agent.displayName) 与 Argo 失联了" : "\(agent.displayName) 意外退出了",
            body: lines.filter { !$0.isEmpty }.joined(separator: "\n"), host: host,
            target: lost ? AttentionTarget(host: host, ws: agent.ws, run: agent.run, terminal: "", view: AttentionTarget.sessionsView)
                         : target(of: agent),
            threadIdentifier: "\(host.uuidString).\(agent.run)")
    }

    /// FT79-01: 「在问你」, quoting the question. There is no native question,
    /// so no reply buttons; the click opens the Agent.
    private mutating func postAsking(_ agent: AttentionAgent, _ question: String) -> AgentNotificationEffect {
        let notice = AgentNotification(
            identifier: askingIdentifier(agent.run), kind: .waiting, title: "\(agent.displayName) 在问你",
            body: [place(agent), question].filter { !$0.isEmpty }.joined(separator: "\n"),
            host: host, target: target(of: agent), threadIdentifier: "\(host.uuidString).\(agent.run)")
        delivered[agent.run, default: []].insert(notice.identifier)
        return .post(notice)
    }

    private func place(_ agent: AttentionAgent) -> String {
        [agent.workspace, agent.title.isEmpty ? agent.displayName : agent.title, nameTags[agent.run] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Identity

    private func target(of agent: AttentionAgent) -> AttentionTarget {
        AttentionTarget(host: host, ws: agent.ws, run: agent.run, terminal: agent.terminal)
    }

    /// The one budget notice of a crossing. Its id carries the identity, so
    /// a re-evaluated snapshot cannot post it twice; the category (registered
    /// by the shell) offers 继续观察 / 打开会话 / 打断.
    private func budgetNotice(_ agent: AttentionAgent, identity: String) -> AgentNotification {
        let text = (agent.budgetText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentNotification(
            identifier: "loom.budget.\(host.uuidString).\(agent.run).\(identity)",
            kind: .budget, title: "\(agent.displayName) 超出预算",
            body: text.isEmpty ? "设置的预算已用完" : text,
            host: host, target: target(of: agent),
            threadIdentifier: "\(host.uuidString).\(agent.run)", offersBudget: true)
    }

    private func waitingIdentifier(_ agent: AttentionAgent, _ question: AttentionQuestion) -> String {
        AttentionNotice.waitingIdentifier(host: host, run: agent.run, agent: question.agent, questionID: question.questionID)
    }
    private func doneIdentifier(_ run: String) -> String { AttentionNotice.doneIdentifier(host: host, run: run) }
    private func errorIdentifier(_ run: String) -> String { AttentionNotice.errorIdentifier(host: host, run: run) }
    private func exitIdentifier(_ run: String) -> String { AttentionNotice.exitIdentifier(host: host, run: run) }
    private func askingIdentifier(_ run: String) -> String { AttentionNotice.askingIdentifier(host: host, run: run) }

    private func kind(of state: String) -> AgentNotificationKind? {
        switch state {
        case "waiting": return .waiting
        case "done": return .done
        case "error": return .error
        default: return nil
        }
    }

    private mutating func withdraw(kind: AgentNotificationKind?, run: String) -> [AgentNotificationEffect] {
        guard let kind, var ids = delivered[run] else { return [] }
        let prefix: String
        switch kind {
        case .waiting: prefix = "loom.waiting.\(host.uuidString).\(run)."
        case .done: prefix = doneIdentifier(run)
        case .error: prefix = errorIdentifier(run)
        case .budget: prefix = "loom.budget.\(host.uuidString).\(run)."
        }
        let noticePrefix = "loom.notice.\(host.uuidString).\(run)."
        let gone = ids.filter {
            if kind == .waiting { return $0.hasPrefix(prefix) }
            if kind == .error { return $0 == prefix || $0.hasPrefix(noticePrefix) }
            return $0 == prefix
        }
        ids.subtract(gone)
        if ids.isEmpty { delivered.removeValue(forKey: run) } else { delivered[run] = ids }
        return gone.isEmpty ? [] : [.withdraw(gone.sorted())]
    }

    /// One delivered notice of a run, if it is on screen.
    private mutating func withdrawID(_ id: String, run: String) -> [AgentNotificationEffect] {
        guard delivered[run]?.remove(id) != nil else { return [] }
        if delivered[run]?.isEmpty == true { delivered.removeValue(forKey: run) }
        return [.withdraw([id])]
    }

    /// The run's unexpected end is over (relaunched) or changed: its notice
    /// and its place in a group of ended runs go.
    private mutating func withdrawExit(_ run: String) -> [AgentNotificationEffect] {
        var effects = withdrawID(exitIdentifier(run), run: run)
        let groups = errorGroups.filter { $0.value.exit && $0.value.runs[run] != nil }.map(\.key)
        recentErrors.removeAll { $0.run == run && $0.key.hasPrefix("exit\u{1}") }
        for key in groups {
            errorGroups[key]?.runs.removeValue(forKey: run)
            if errorGroups[key]?.runs.isEmpty == true {
                errorGroups.removeValue(forKey: key)
                effects.append(.withdraw([AttentionNotice.errorGroupIdentifier(host: host, key: key)]))
            }
        }
        return effects
    }

    private mutating func withdrawTerminal(_ terminal: String) -> [AgentNotificationEffect] {
        guard let ids = deliveredTerminals.removeValue(forKey: terminal), !ids.isEmpty else { return [] }
        return [.withdraw(ids.sorted())]
    }

    private mutating func withdrawAll(run: String) -> [AgentNotificationEffect] {
        guard let ids = delivered.removeValue(forKey: run), !ids.isEmpty else { return [] }
        return [.withdraw(ids.sorted())]
    }

    private mutating func withdrawAnswered(_ agent: AttentionAgent,
                                           questions: [AttentionQuestion]) -> [AgentNotificationEffect] {
        guard var ids = delivered[agent.run], !ids.isEmpty else { return [] }
        let prefix = "loom.waiting.\(host.uuidString).\(agent.run)."
        let current = Set(questions.filter { $0.run == agent.run }.map { waitingIdentifier(agent, $0) })
        let gone = ids.filter { $0.hasPrefix(prefix) && !current.contains($0) }
        guard !gone.isEmpty else { return [] }
        ids.subtract(gone)
        if ids.isEmpty { delivered.removeValue(forKey: agent.run) } else { delivered[agent.run] = ids }
        return [.withdraw(gone.sorted())]
    }
}

/// The two switches persisted by host (N-2). A page writes only the host of
/// the window that sent the bridge message; the shell keeps the value across
/// windows and app restarts.
public struct AgentNotificationSettingsStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "loom.agentNotify") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func settings(for host: UUID) -> AgentNotificationSettings {
        let stored = { (field: String) -> Bool in
            let k = self.key(host, field)
            return self.defaults.object(forKey: k) != nil ? self.defaults.bool(forKey: k) : true
        }
        let sound = { (field: String, fallback: AgentNotificationSound) -> AgentNotificationSound in
            guard let raw = self.defaults.string(forKey: self.key(host, field)) else { return fallback }
            return AgentNotificationSound(rawValue: raw) ?? fallback
        }
        let volume = { (field: String) -> Int in
            let k = self.key(host, field)
            return self.defaults.object(forKey: k) == nil ? 100 : AgentNotificationSettings.normalizedVolume(self.defaults.integer(forKey: k))
        }
        return AgentNotificationSettings(needsYou: stored("needsYou"), done: stored("done"), asking: stored("asking"), reply: stored("reply"),
                                        needsYouSound: sound("needsYouSound", .systemDefault), needsYouVolume: volume("needsYouVolume"),
                                        doneSound: sound("doneSound", .none), doneVolume: volume("doneVolume"))
    }

    public func set(_ settings: AgentNotificationSettings, for host: UUID) {
        defaults.set(settings.needsYou, forKey: key(host, "needsYou"))
        defaults.set(settings.done, forKey: key(host, "done"))
        defaults.set(settings.asking, forKey: key(host, "asking"))
        defaults.set(settings.reply, forKey: key(host, "reply"))
        defaults.set(settings.needsYouSound.rawValue, forKey: key(host, "needsYouSound"))
        defaults.set(settings.needsYouVolume, forKey: key(host, "needsYouVolume"))
        defaults.set(settings.doneSound.rawValue, forKey: key(host, "doneSound"))
        defaults.set(settings.doneVolume, forKey: key(host, "doneVolume"))
    }

    /// Whether the shell already owns a value for this host.
    public func hasValue(for host: UUID) -> Bool {
        defaults.object(forKey: key(host, "needsYou")) != nil
            || defaults.object(forKey: key(host, "done")) != nil
    }

    /// The page's proposed value seeds a host the shell has never stored; an
    /// existing shell value always wins (R2-4).
    public func adopt(_ proposed: AgentNotificationSettings, for host: UUID) -> AgentNotificationSettings {
        if !hasValue(for: host) { set(proposed, for: host) }
        return settings(for: host)
    }

    public func remove(host: UUID) {
        for field in ["needsYou", "done", "asking", "reply", "needsYouSound", "needsYouVolume", "doneSound", "doneVolume"] {
            defaults.removeObject(forKey: key(host, field))
        }
    }

    private func key(_ host: UUID, _ field: String) -> String {
        "\(prefix).\(field).\(host.uuidString)"
    }
}

/// Per-host notification state. It lives in the shell, not in an
/// `AttentionHost`: reconnecting, a loomd restart and an exhausted 3/3 stream
/// rebuild the host monitor but must not make unanswered questions look like a
/// first sight or lose the ids of delivered notices (N-1). It is released only
/// when the host is removed (N-4).
public struct AgentNotificationCenter: Sendable {
    private var notifiers: [UUID: AgentNotifier] = [:]

    public init() {}

    public mutating func update(host: UUID, agents: [AttentionAgent], questions: [AttentionQuestion],
                                visible: Set<String>, settings: AgentNotificationSettings,
                                now: Date, complete: Bool = true, unreadable: Set<String> = [],
                                fresh: Bool = true, visibleTerminals: Set<String> = []) -> [AgentNotificationEffect] {
        var notifier = notifiers[host] ?? AgentNotifier(host: host)
        let effects = notifier.update(agents, questions: questions, visible: visible,
                                      settings: settings, now: now, complete: complete,
                                      unreadable: unreadable, fresh: fresh,
                                      visibleTerminals: visibleTerminals)
        notifiers[host] = notifier
        return effects
    }

    /// One fresh `/api/attention` snapshot, as AttentionCenter receives it. A
    /// loomd that predates `agents` produces no local notifications. A run
    /// still loading makes the snapshot incomplete; `unreadable` alone, not
    /// the error count, says which missing runs are not deleted (R2-1).
    /// `fresh` comes from AttentionRefreshPlan: a response requested before
    /// the latest visibility or switch change does not release (O1).
    public mutating func update(host: UUID, snapshot: AttentionSnapshot, visible: Set<String>,
                                settings: AgentNotificationSettings, now: Date, fresh: Bool = true,
                                visibleTerminals: Set<String> = []) -> [AgentNotificationEffect] {
        guard let agents = snapshot.agents else { return [] }
        var effects = update(host: host, agents: agents, questions: snapshot.waiting, visible: visible,
                             settings: settings, now: now, complete: (snapshot.loading ?? 0) == 0 && snapshot.scanning != true,
                             unreadable: Set(snapshot.unreadable ?? []), fresh: fresh,
                             visibleTerminals: visibleTerminals)
        if let races = snapshot.races, fresh {
            var notifier = notifiers[host] ?? AgentNotifier(host: host)
            effects += notifier.updateRaces(races, settings: settings)
            notifiers[host] = notifier
        }
        return effects
    }

    public mutating func tick(host: UUID, now: Date) -> [AgentNotificationEffect] {
        guard var notifier = notifiers[host] else { return [] }
        let effects = notifier.tick(now: now)
        notifiers[host] = notifier
        return effects
    }

    public func nextDeadline(host: UUID) -> Date? { notifiers[host]?.nextDeadline }

    public mutating func externalNotice(host: UUID, kind: AgentExternalNoticeKind,
                                        agent: AttentionAgent, identity: String,
                                        settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        guard var notifier = notifiers[host] else { return [] }
        let effects = notifier.externalNotice(kind, agent: agent, identity: identity, settings: settings)
        notifiers[host] = notifier
        return effects
    }

    public mutating func scmBuild(host: UUID, agent: AttentionAgent, build: String, ok: Bool, title: String,
                                  body: String, settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        guard var notifier = notifiers[host] else { return [] }
        let effects = notifier.scmBuild(agent: agent, build: build, ok: ok, title: title, body: body, settings: settings)
        notifiers[host] = notifier
        return effects
    }

    /// A plain terminal signal does not depend on any Agent snapshot: it is
    /// delivered even before the host's first snapshot arrives (F1). The
    /// windows' live report wins over the last snapshot's visibility.
    public mutating func terminalSignal(host: UUID, message: TerminalSignalMessage,
                                        visibleTerminals: Set<String>,
                                        settings: AgentNotificationSettings) -> [AgentNotificationEffect] {
        guard !visibleTerminals.contains(message.terminal) else { return [] }
        var notifier = notifiers[host] ?? AgentNotifier(host: host)
        let effects = notifier.terminalSignal(message.kind, terminal: message.terminal,
                                              title: message.title, body: message.body,
                                              settings: settings.applying(message.notify))
        notifiers[host] = notifier
        return effects
    }

    public mutating func remove(host: UUID) -> [AgentNotificationEffect] {
        guard var notifier = notifiers.removeValue(forKey: host) else { return [] }
        return notifier.withdrawAll()
    }
}

/// Notifications posted while the permission prompt is open (BH-NEXT-13).
/// The system keeps one notification per identifier, so the queue does too: a
/// newer post replaces the queued content in place, and the limit counts
/// identifiers, so repeats of one notice cannot push out another.
public struct PendingNotifications<Content> {
    public private(set) var items: [(identifier: String, content: Content)] = []
    public let limit: Int

    public init(limit: Int = 20) { self.limit = limit }

    public mutating func add(_ identifier: String, _ content: Content) {
        if let i = items.firstIndex(where: { $0.identifier == identifier }) {
            items[i].content = content
        } else if items.count < limit {
            items.append((identifier, content))
        }
    }

    public mutating func remove(_ identifiers: Set<String>) {
        items.removeAll { identifiers.contains($0.identifier) }
    }

    public mutating func drain() -> [(identifier: String, content: Content)] {
        defer { items = [] }
        return items
    }
}
