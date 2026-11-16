import ArgoMobileKit
import Foundation
import Glibc

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private struct Fixture: Sendable {
    let name: String
    let state: String
    var status = "active"
    var interrupted = false
    var ask = false
    let readState: AgentState
    let unreadState: AgentState

    static let matrix: [Fixture] = [
        Fixture(name: "waiting", state: "waiting", readState: .needsYou, unreadState: .needsYou),
        Fixture(name: "error", state: "error", readState: .error, unreadState: .error),
        Fixture(name: "working", state: "working", readState: .working, unreadState: .working),
        Fixture(name: "done", state: "done", readState: .idle, unreadState: .unread),
        Fixture(name: "interrupted", state: "done", interrupted: true, readState: .offline, unreadState: .offline),
        Fixture(name: "unknown", state: "unknown", readState: .unknown, unreadState: .unknown),
        Fixture(name: "stopped", state: "unknown", status: "stopped", readState: .offline, unreadState: .offline),
        Fixture(name: "ask-working", state: "working", ask: true, readState: .needsYou, unreadState: .needsYou),
        Fixture(name: "ask-error", state: "error", ask: true, readState: .needsYou, unreadState: .needsYou),
        Fixture(name: "working-stopped", state: "working", status: "stopped", readState: .working, unreadState: .working),
        Fixture(name: "error-stopped", state: "error", status: "stopped", readState: .error, unreadState: .error),
    ]

    func payload(unread: Bool, workspace: String, allRead: Bool = false) -> [String: Any] {
        let run = "r-\(name)-\(unread ? "unread" : "read")"
        var card: [String: Any] = ["run": run, "terminal": "t-" + run, "ws": workspace,
                                  "engine": "claude", "title": "Synthetic " + name, "state": state,
                                  "status": status, "interrupted": interrupted, "unread": unread && !allRead,
                                  "updated": "2026-11-16T01:00:00Z"]
        if ask {
            card["ask"] = ["questionID": "q-" + run, "run": run, "kind": "ask", "text": "Synthetic question"]
        }
        return card
    }
}

/// All responses and credentials are synthetic. No network transport is used.
private actor FilterTransport: ArgoHTTPTransport {
    enum Mode: Sendable { case initial, matrix, allRead }
    private var mode = Mode.initial
    func setMode(_ value: Mode) { mode = value }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async {}

    private func cards(_ workspace: String) -> [[String: Any]] {
        if mode == .initial {
            return [("waiting", "waiting", true), ("error", "error", true),
                    ("working", "working", true), ("done", "done", true), ("read", "done", false)]
                .map { name, state, unread in
                    ["run": "r-" + name, "terminal": "t-" + name, "ws": workspace,
                     "engine": "claude", "state": state, "status": "active", "unread": unread,
                     "updated": "2026-11-16T01:00:00Z"] as [String: Any]
                }
        }
        return Fixture.matrix.flatMap { fixture in
            [false, true].map { fixture.payload(unread: $0, workspace: workspace, allRead: mode == .allRead) }
        }
    }

    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        guard request.method == "GET" else { throw Failure("Unexpected synthetic write: " + request.target) }
        let url = URLComponents(string: "http://synthetic.invalid" + request.target)!
        let workspace = url.queryItems?.first { $0.name == "ws" }?.value ?? "w1"
        let value: Any
        switch url.path {
        case "/api/health": value = ["api": 1, "version": "synthetic"]
        case "/api/projects", "/api/agents/profiles": value = [] as [String]
        case "/api/workspaces": value = [["id": "w1"]]
        case "/api/agents": value = cards(workspace)
        case "/api/terminals":
            value = cards(workspace).map { card in
                ["id": card["terminal"]!, "ws": workspace, "alive": true,
                 "agent": ["run": card["run"]!, "engine": "claude"]] as [String: Any]
            }
        default: throw Failure("Unexpected synthetic request: " + request.target)
        }
        return HTTPResponse(status: 200, headers: [], body: try JSONSerialization.data(withJSONObject: value), reusable: true)
    }
}

@MainActor private final class MemoryCreations: PendingCreationStoring {
    func load() throws -> [PendingAgentCreation] { [] }
    func save(_ pending: [PendingAgentCreation]) throws {}
}

@main private struct UnreadCheck {
    @MainActor private static func eventually(_ name: String, _ condition: () -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < until {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(name)
    }

    @MainActor static func main() async {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unread-check-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
                GatewayCredential(device: "synthetic-device", token: String(repeating: "b", count: 43))
            }
            let transport = FilterTransport()
            let model = AppModel(store: store, pendingCreations: MemoryCreations()) { host, _ in
                ArgoConnection(host: host, transport: transport)
            }
            defer { model.setActive(false) }
            let fingerprint = Base64URL.encode(Data(repeating: 1, count: 32))
            let secret = Base64URL.encode(Data(repeating: 2, count: 16))
            _ = try await store.pair(code: "argo1:synthetic.invalid:6779:\(fingerprint):\(secret)", deviceName: "synthetic")
            await model.loadHosts()
            model.setActive(true)
            try await eventually("Initial five-card list") { model.agents.count == 5 && !model.refreshingAgents }

            func badge(_ filter: AgentFilter) -> Int? {
                BadgeProjection(model: model).filterItems.first { $0.id == filter.rawValue }?.count
            }
            let fourUnread: Set<String> = ["r-waiting", "r-error", "r-working", "r-done"]
            guard Set(model.agents.filter(\.unread).map(\.run)) == fourUnread else { throw Failure("Initial unread fixture mismatch") }
            model.filter = .unread
            if CommandLine.arguments.contains("--expect-baseline-bug") {
                guard model.visibleAgents.map(\.run) == ["r-done"], badge(.unread) == 1 else {
                    throw Failure("Expected exact baseline 4-to-1 defect")
                }
                print("REPRO P2 flag=4 visible=1 badge=1 runs=\(model.visibleAgents.map(\.run))")
                return
            }
            guard Set(model.visibleAgents.map(\.run)) == fourUnread, badge(.unread) == 4 else {
                throw Failure("Expected 4-to-4: flag=4 visible=\(model.visibleAgents.count) badge=\(badge(.unread) ?? -1)")
            }
            print("PASS original reproduction: flag=4 visible=4 badge=4")

            await transport.setMode(.matrix)
            model.refreshAgents()
            try await eventually("Boundary matrix") { model.agents.count == Fixture.matrix.count * 2 && !model.refreshingAgents }
            var expectedNeedsYou: Set<String> = []
            var expectedWorking: Set<String> = []
            var expectedUnread: Set<String> = []
            for fixture in Fixture.matrix {
                for unread in [false, true] {
                    let run = "r-\(fixture.name)-\(unread ? "unread" : "read")"
                    let expectedState = unread ? fixture.unreadState : fixture.readState
                    guard let card = model.agents.first(where: { $0.run == run }),
                          AgentSession(card).state == expectedState else { throw Failure("Display priority changed: " + run) }
                    if expectedState == .needsYou { expectedNeedsYou.insert(run) }
                    if expectedState == .working { expectedWorking.insert(run) }
                    if unread { expectedUnread.insert(run) }
                }
            }
            print("PASS \(model.agents.count) state/unread boundaries: waiting/error/working/done/interrupted/stopped/unknown/ask priorities")
            let expected: [AgentFilter: Set<String>] = [
                .all: Set(model.agents.map(\.run)), .needsYou: expectedNeedsYou,
                .working: expectedWorking, .unread: expectedUnread,
            ]
            for filter in AgentFilter.allCases {
                model.filter = filter
                guard Set(model.visibleAgents.map(\.run)) == expected[filter], badge(filter) == expected[filter]?.count else {
                    throw Failure("List/badge mismatch: " + filter.rawValue)
                }
                print("PASS filter=\(filter.rawValue) visible=\(model.visibleAgents.count) badge=\(badge(filter) ?? -1)")
            }
            model.filter = .unread
            guard model.visibleAgents.allSatisfy(\.unread) else { throw Failure("Read=false card entered Unread") }
            model.search = "  R-WORKING-UNREAD  "
            guard model.visibleAgents.map(\.run) == ["r-working-unread"], badge(.unread) == expectedUnread.count else {
                throw Failure("Search/filter intersection or global badge scope changed")
            }
            model.search = ""
            print("PASS unread excludes every false flag; search intersects list while badge retains global count")

            await transport.setMode(.allRead)
            model.refreshAgents()
            try await eventually("All-read matrix") { !model.agents.contains(where: \.unread) && !model.refreshingAgents }
            guard model.agents.count == Fixture.matrix.count * 2, model.visibleAgents.isEmpty, badge(.unread) == 0 else {
                throw Failure("All-read cards entered Unread list/badge")
            }
            print("PASS all 22 unread=false cards excluded; Unread list=0 badge=0")
            print("Unread production-model checks completed")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}
