@testable import ArgoMobileKit
import Foundation
import Glibc

private struct Failure: Error { let message: String }
private let host = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let otherHost = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let text = "SYNTHETIC_UNBOUND_EVIDENCE\n  原文🙂  "

@MainActor private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private func decode<T: Decodable>(_ object: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
private func item(_ id: String = "same-id", kind: String? = nil) -> [String: Any] {
    var result: [String: Any] = ["id": id, "text": text,
        "target": ["run": "r1", "engine": "codex", "session": "original-thread"]]
    if kind == "legacy" { result["deliveryUnknown"] = "explicit unknown" }
    else if let kind { result["native"] = ["state": kind, "note": "explicit native evidence"] }
    return result
}
private func queue(_ items: [[String: Any]] = [], run: String = "r1") throws -> ArgoQueue {
    try decode(["run": run, "items": items])
}
private func receipt(_ id: String = "same-id", kind: String? = nil, attempt: String) throws -> ArgoSendReceipt {
    ArgoSendReceipt(run: "r1", attempt: attempt, delivered: false, queued: try decode(item(id, kind: kind)),
                    queue: try queue(), pasted: false, note: "", duplicate: false)
}
@MainActor private func makeState(_ key: SessionKey? = nil) -> ConversationState {
    let state = ConversationState(key: key ?? SessionKey(host: host, workspace: "w1", run: "r1", terminal: "t1"))
    appendSend(state)
    return state
}
@MainActor private func appendSend(_ state: ConversationState) {
    let message = ArgoOutgoingMessage(run: state.key.run, text: text,
        target: ArgoAgentIdentity(run: state.key.run, engine: "codex", session: "original-thread"))
    state.append(PendingDelivery(id: message.attempt, operation: .message(message)))
}
@MainActor private func bind(_ state: ConversationState, id: String = "same-id", kind: String? = nil) throws {
    let attempt = state.deliveries.last!.id
    state.record(try receipt(id, kind: kind, attempt: attempt), for: attempt)
}
@MainActor private func requireQueued(_ state: ConversationState) throws {
    guard case .queued = state.deliveries.last?.status else { throw Failure(message: "unrelated evidence crossed its owner/ID") }
}
@MainActor private func requireEvidence(_ state: ConversationState, kind: String) throws {
    guard let delivery = state.deliveries.first else { throw Failure(message: "missing original receipt") }
    if kind == "legacy" {
        try require(delivery.status == .unknown("explicit unknown"), "ordinary unknown erased")
    } else {
        guard case .native(let native) = delivery.status else { throw Failure(message: "native evidence erased") }
        try require(native.state == (kind == "accepted" ? .accepted : .unknown), "native ACK precedence changed")
    }
    try require(!delivery.status.canRetry && !delivery.status.isKnownSuccess, "evidence became retryable/success")
    try require(delivery.queueItemID == "same-id" && delivery.operation.text == text && state.transcript.items.isEmpty, "receipt identity/text or transcript changed")
}

@main private struct EvidenceLifecycleCheck {
    @MainActor static func main() {
        do {
            var checked = 0
            for kind in ["legacy", "unknown", "accepted", "future-state"] {
                let state = makeState()
                let originalAttempt = state.deliveries[0].id
                state.queue = try queue([item(kind: kind)])
                state.queue = try queue()
                // A cold state must keep evidence until the unresolved send can
                // bind its server ID, without retaining its transcript window.
                state.releaseReloadableContent()
                try bind(state)
                try requireEvidence(state, kind: kind)
                try require(state.deliveries[0].id == originalAttempt, "binding replaced attempt")
                state.sessionChanged()
                state.queue = try queue()
                state.releaseReloadableContent()
                try requireEvidence(state, kind: kind)
                checked += 1
                print("PASS \(kind): unbound evidence survives empty/cold/session-change states")
            }

            let differentID = makeState()
            differentID.queue = try queue([item("other-id", kind: "legacy")])
            differentID.queue = try queue()
            try bind(differentID)
            try requireQueued(differentID)
            let wrongRun = makeState()
            wrongRun.queue = try queue([item(kind: "legacy")], run: "r2")
            wrongRun.queue = try queue()
            try bind(wrongRun)
            try requireQueued(wrongRun)
            checked += 2
            print("PASS different ID / run: identical text cannot bind unknown")

            let owner = makeState()
            owner.queue = try queue([item(kind: "legacy")])
            for key in [SessionKey(host: otherHost, workspace: "w1", run: "r1", terminal: "t1"),
                        SessionKey(host: host, workspace: "w2", run: "r1", terminal: "t1"),
                        SessionKey(host: host, workspace: "w1", run: "r1", terminal: "t2")] {
                let other = makeState(key)
                try bind(other)
                try requireQueued(other)
                checked += 1
            }
            try bind(owner)
            try requireEvidence(owner, kind: "legacy")
            print("PASS original SessionKey: host/workspace/terminal evidence stays isolated")

            owner.forget()
            appendSend(owner)
            try bind(owner)
            try requireQueued(owner)
            checked += 1
            print("PASS forget: no retained evidence leaks into fresh state")

            let noLocalSend = ConversationState(key: owner.key)
            noLocalSend.queue = try queue([item(kind: "legacy")])
            noLocalSend.releaseReloadableContent()
            appendSend(noLocalSend)
            try bind(noLocalSend)
            try requireQueued(noLocalSend)
            checked += 1
            print("PASS cold cleanup: unowned evidence is released by existing lifecycle")
            print("Evidence lifecycle: \(checked)/\(checked) passed")
        } catch {
            print("FAIL evidence lifecycle: \(error)")
            exit(1)
        }
    }
}
