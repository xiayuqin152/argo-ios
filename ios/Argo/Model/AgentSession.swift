import ArgoMobileKit
import Foundation

extension ArgoAsk {
    var uiID: String { run + ":" + agent + ":" + questionID }
}

/// The small projection Persona's rows need in place of PersonaModels.Session.
struct AgentSession {
    let card: ArgoAgentCard
    init(_ card: ArgoAgentCard) { self.card = card }

    var state: AgentState {
        if card.ask != nil || card.state == "waiting" { return .needsYou }
        switch card.state {
        case "working": return .working
        case "error": return .error
        case "done":
            // loomd represents a stopped/interrupted run as done + interrupted.
            if card.interrupted { return .offline }
            return card.unread ? .unread : .idle
        default: return card.status == "stopped" ? .offline : .unknown
        }
    }
    var displayTitle: String { card.displayTitle }
    var agentName: String {
        [card.cli, card.profile, card.engine].first { !$0.isEmpty } ?? "Agent"
    }
    var preview: String? { [card.ask?.text ?? "", card.activity, card.reply, card.error].first { !$0.isEmpty } }
    var updated: Date? { ArgoTime.date(card.updated) }
}

nonisolated enum AgentState: String, Sendable {
    case needsYou, working, unread, idle, offline, error, unknown

    var label: String {
        let key = switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .unread: "Unread"
        case .idle: "Done"
        case .offline: "Stopped"
        case .error: "Error"
        case .unknown: "Unknown"
        }
        return L10n.text(key)
    }
}

enum AgentFilter: String, CaseIterable, Identifiable {
    case all, needsYou, working, unread
    var id: String { rawValue }
    var title: String { self == .all ? L10n.text("All") : state?.label ?? "" }
    var state: AgentState? {
        switch self {
        case .all: nil
        case .needsYou: .needsYou
        case .working: .working
        case .unread: .unread
        }
    }
    func includes(_ session: AgentSession) -> Bool { state == nil || state == session.state }
}
