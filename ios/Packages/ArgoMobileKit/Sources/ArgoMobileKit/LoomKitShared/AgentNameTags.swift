import Foundation

/// One Agent as the same-title rule sees it. `group` is the workspace; `place`
/// the worktree, `cli` the CLI's display name and `time` the start time as
/// HH:MM, each "" when unknown.
public struct AgentNameItem: Decodable, Equatable, Sendable {
    public let key: String
    public let group: String
    public let title: String
    public let place: String
    public let cli: String
    public let time: String

    public init(key: String, group: String, title: String, place: String = "", cli: String = "", time: String = "") {
        self.key = key; self.group = group; self.title = title
        self.place = place; self.cli = cli; self.time = time
    }
}

/// FT67-02: Agents with the same title in one workspace get the shortest
/// suffix that tells them apart, tried in a fixed order: worktree, then CLI,
/// then start time. Display only: the stored title never changes. This is the
/// page's web/js/name-tags.js; both are pinned by
/// Tests/LoomKitTests/Fixtures/name-tags.json.
public enum AgentNameTags {
    private static let fields: [KeyPath<AgentNameItem, String>] = [\.place, \.cli, \.time]

    /// The worktree a terminal context names: a task's name, or the last
    /// directory of a root context (`root:/w/repos/loom/feat-a` → feat-a).
    public static func contextName(_ key: String) -> String {
        if key.hasPrefix("task:") { return String(key.dropFirst(5)) }
        guard key.hasPrefix("root:") else { return "" }
        return key.dropFirst(5).split(separator: "/").last.map(String.init) ?? ""
    }

    /// key → suffix for every item whose title is shared in its group. A field
    /// that is the same for the whole group says nothing and is skipped;
    /// fields are added in order until every member reads differently.
    public static func tags(_ items: [AgentNameItem]) -> [String: String] {
        var groups: [String: [AgentNameItem]] = [:]
        var order: [String] = []
        for item in items where !item.title.isEmpty {
            let id = item.group + "\u{0}" + item.title
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(item)
        }
        var out: [String: String] = [:]
        for id in order {
            let members = groups[id] ?? []
            guard members.count > 1 else { continue }
            var used: [KeyPath<AgentNameItem, String>] = []
            for field in fields {
                guard Set(members.map { $0[keyPath: field] }).count > 1 else { continue }
                used.append(field)
                let read = Set(members.map { m in used.map { m[keyPath: $0] }.joined(separator: "\u{0}") })
                if read.count == members.count { break }
            }
            for m in members {
                let tag = used.map { m[keyPath: $0] }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !tag.isEmpty { out[m.key] = tag }
            }
        }
        return out
    }

    /// run → suffix for one host's attention agents, as the 「等你回答」 panel and
    /// the notifications show them next to the title.
    public static func tags(for agents: [AttentionAgent], zone: TimeZone = .current) -> [String: String] {
        tags(agents.map { a in
            AgentNameItem(key: a.run, group: a.ws, title: a.title.isEmpty ? a.displayName : a.title,
                          place: contextName(a.context ?? ""),
                          cli: a.label?.isEmpty == false ? a.label ?? "" : a.profile,
                          time: clock(a.created ?? "", zone: zone))
        })
    }

    /// An RFC 3339 instant as HH:MM in `zone`; "" when absent or unparsable.
    public static func clock(_ iso: String, zone: TimeZone = .current) -> String {
        // Go writes up to nine fractional digits; the minute does not need them.
        let whole = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let date = ISO8601DateFormatter().date(from: whole),
              date > Date(timeIntervalSince1970: 946_684_800) else { return "" } // 2000-01-01: zero time
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
