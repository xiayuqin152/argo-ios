import ArgoMobileKit
import Foundation

@main struct ModelRecoveryCheck {
    @MainActor static func main() {
        do { try WireContractCheck.run(); try check() }
        catch { print("CHECK_FAILED: \(error)"); exit(1) }
    }

    @MainActor static func check() throws {
        // Fixed wire shape of agent_model.go's deadline branch at b5453cf4b.
        // /model has already been delivered; the CLI result is unconfirmed.
        let timeout = #"{"switched":false,"message":"已发送 /model fixture-model，但 30s 内没看到 Claude Code 的结果，没有发送续跑；请在终端里查看"}"#
        let receipt = try JSONDecoder().decode(ArgoModelSwitchReceipt.self, from: Data(timeout.utf8))
        guard !receipt.switched, receipt.resume == nil else { throw Failure.fixture }
        let key = SessionKey(host: UUID(), workspace: "fixture-ws", run: "20261115-120000-fixture", terminal: "fixture-terminal")
        let state = ConversationState(key: key)
        let native = ArgoAgentIdentity(run: key.run, engine: "claude", session: "fixture-session")
        let page = #"{"bounded":true,"byteLimit":1048576,"identity":{"run":"20261115-120000-fixture","engine":"claude","session":"fixture-session"},"items":[],"start":"0:0","end":"0:0","size":0,"older":false,"newer":false}"#
        try state.transcript.apply(JSONDecoder().decode(ArgoChatPage.self, from: Data(page.utf8)), cursor: .latest)
        let operation = UUID()
        state.beginModelRecovery(operation, model: "fixture-model")
        // AppModel.modelRecoveryStatus maps every switched:false response to
        // notSwitched; do not interpret the server's translated message text.
        state.finishModelRecovery(operation, status: .notSwitched(receipt.message))
        // AppModel automatically reads back after a receipt. Reproduce a
        // valid waiting chat page: no native conversation is available yet.
        guard state.beginModelRecoveryRefresh(operation) else { throw Failure.refresh }
        let waiting = #"{"bounded":true,"byteLimit":1048576,"waiting":"正在读取"}"#
        try state.transcript.apply(JSONDecoder().decode(ArgoChatPage.self, from: Data(waiting.utf8)), cursor: .latest)
        state.finishModelRecoveryRefresh(operation, native: nil, epoch: UUID(), problem: nil)
        guard state.modelRecoveryNeedsReviewBeforeNewAction, !state.canStartModelRecovery else {
            print("FAIL: unconfirmed /model receipt permits another model write after unavailable native readback")
            throw Failure.retryBeforeReview
        }
        // A successful explicit native read allows the next user action.
        guard state.beginModelRecoveryRefresh(operation) else { throw Failure.refresh }
        try state.transcript.apply(JSONDecoder().decode(ArgoChatPage.self, from: Data(page.utf8)), cursor: .latest)
        state.finishModelRecoveryRefresh(operation, native: native, epoch: UUID(), problem: nil)
        guard state.canStartModelRecovery, !state.modelRecoveryNeedsReviewBeforeNewAction else { throw Failure.review }
        // Definite non-delivery and refusal keep their existing retry behavior.
        for status in [ModelRecoveryOperation.Status.notSent("fixture"), .rejected("fixture")] {
            state.beginModelRecovery(operation, model: "fixture-model")
            state.finishModelRecovery(operation, status: status)
            guard state.canStartModelRecovery else { throw Failure.definiteRefusal }
        }
        print("PASS: timeout receipt requires native review; unavailable read stays blocked; matching read unlocks; non-delivery/refusal unchanged")
    }
    enum Failure: Error {
        case fixture, retryBeforeReview, refresh, review, definiteRefusal
    }
}
