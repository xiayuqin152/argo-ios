import Foundation

/// UD-02: the terminals a ptyd-protocol upgrade leaves behind. Pushing a loomd
/// that speaks another ptyd protocol (`UpgradePlan.ptydConflict`) makes every
/// terminal of the running ptyd unreachable from Argo, so the confirmation
/// names the Agents and counts the shells first. Read from the running
/// loomd's `GET /api/terminals` through the window's local tunnel.
public struct LiveTerminals: Equatable, Sendable {
    /// Display names of the running Agents, in the listing's order.
    public var agents: [String]
    /// Running terminals that are not Agents.
    public var shells: Int

    public init(agents: [String], shells: Int) { self.agents = agents; self.shells = shells }

    private struct Row: Decodable {
        struct Agent: Decodable { let run: String?; let profile: String? }
        let title: String?
        let alive: Bool?
        let agent: Agent?
    }

    /// Parses the `GET /api/terminals` body; only live terminals count.
    public static func parse(_ data: Data) throws -> LiveTerminals {
        let rows = try JSONDecoder().decode([Row].self, from: data)
        var out = LiveTerminals(agents: [], shells: 0)
        for row in rows where row.alive == true {
            if let agent = row.agent, !(agent.run ?? "").isEmpty {
                let title = (row.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out.agents.append(title.isEmpty ? (agent.profile ?? "Agent") : title)
            } else {
                out.shells += 1
            }
        }
        return out
    }
}

public enum PtydUpgradeNotice {
    public static let title = "升级会结束远程上的终端"
    static let tail = "选「暂不升级」会继续使用远程上现有的 Argo。"

    /// The confirmation's body. `live` is nil when the running loomd could not
    /// be asked; the text then says so instead of claiming there is nothing.
    public static func informativeText(_ live: LiveTerminals?, maxNames: Int = 5) -> String {
        let lead = "这个版本的 Argo 使用新的终端守护进程协议。"
        guard let live else {
            return lead + "升级后，远程上正在运行的终端和 Agent 不能再从 Argo 接回（没能读到它们的列表）。" + tail
        }
        var parts: [String] = []
        if !live.agents.isEmpty {
            let shown = live.agents.prefix(maxNames).joined(separator: "、")
            let more = live.agents.count > maxNames ? " 等" : ""
            parts.append("\(live.agents.count) 个 Agent（\(shown)\(more)）")
        }
        if live.shells > 0 { parts.append("\(live.shells) 个终端") }
        if parts.isEmpty {
            return lead + "远程上现在没有运行中的终端或 Agent，升级不会结束任何终端。" + tail
        }
        return lead + "升级后，远程上正在运行的 " + parts.joined(separator: "和 ") + "不能再从 Argo 接回。" + tail
    }

    /// At most this many stranded terminals are named; the rest are counted.
    public static let shownStranded = 8

    /// The body when a gateway with `upgrade-preflight` listed exactly the
    /// terminals the new ptyd would strand (D68): their labels, one a line.
    public static func informativeText(stranded terminals: [String]) -> String {
        var list = terminals.prefix(shownStranded).map { "• " + $0 }.joined(separator: "\n")
        if terminals.count > shownStranded { list += "\n…另有 \(terminals.count - shownStranded) 个" }
        return "这个版本的 Argo 使用新的终端守护进程协议。升级后，下面这些终端还会在远程上继续运行，但 Argo 接不回它们：\n"
            + list + "\n" + tail
    }
}
