// Adapted from nwverse/persona apple/Persona/Views/Chat/APIErrorCard.swift and AssistantModelSheet.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import SwiftUI

/// Persona's error-card surface and typed-model row, adapted only to Argo's
/// managed-Claude model-error recovery endpoint. This is not a model setting.
struct ModelRecoveryCard: View {
    let agent: ArgoAgentCard?
    @Bindable var state: ConversationState
    @Environment(AppModel.self) private var model
    @FocusState private var modelFocused: Bool

    private var draft: Binding<String> {
        Binding(get: { state.modelRecoveryDraft }, set: {
            state.modelRecoveryDraft = $0
            state.modelRecoveryProblem = nil
        })
    }

    private var canSubmit: Bool {
        agent?.offersModelRecovery == true && state.canStartModelRecovery && model.status.isConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let agent {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    ThemedIcon(Theme.Icon.errorFilled).font(Theme.Font.heading).foregroundStyle(Theme.danger)
                    Text(verbatim: agent.failNote.isEmpty ? agent.stateText : agent.failNote)
                        .font(Theme.Font.heading).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                }
            }

            if let operation = state.modelRecovery { receipt(operation) }

            if agent?.offersModelRecovery == true {
                if state.canStartModelRecovery {
                    TextField("Model ID", text: draft)
                        .font(Theme.Font.code)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($modelFocused)
                        .onSubmit(submit)
                        .accessibilityIdentifier("model-recovery.model-id")
                    Text("Letters, digits and . : / @ [ ] - _; up to 80 characters. The host checks whether this model is available.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                    Button("Change Model & Resume", action: submit)
                        .buttonStyle(.glassProminent)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("model-recovery.submit")
                } else if state.modelRecoveryNeedsReviewBeforeNewAction {
                    Text("Review the current card and conversation before starting another model change.")
                        .font(Theme.Font.secondary).foregroundStyle(.secondary)
                }
            }
            if let problem = state.modelRecoveryProblem {
                Text(verbatim: problem).font(Theme.Font.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.danger.opacity(0.22), lineWidth: 1))
        .accessibilityIdentifier("model-recovery.card")
    }

    @ViewBuilder private func receipt(_ operation: ModelRecoveryOperation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if operation.status == .sending { ProgressView().controlSize(.small) }
                else { ThemedIcon(symbol(operation.status)).foregroundStyle(tint(operation.status)) }
                Text(verbatim: title(operation)).font(Theme.Font.secondaryStrong).foregroundStyle(tint(operation.status))
            }
            Text(verbatim: operation.model).font(Theme.Font.code).textSelection(.enabled)
            let message = detail(operation)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(Theme.Font.caption).readingContent().foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if operation.refreshing { ProgressView().controlSize(.small) }
            if state.modelRecoveryNeedsReviewBeforeNewAction || operation.refreshProblem != nil {
                Button("Refresh Conversation") { model.refreshModelRecovery() }
                    .disabled(operation.refreshing || !model.status.isConnected)
                    .accessibilityIdentifier("model-recovery.refresh")
            }
            if let problem = operation.refreshProblem {
                Text(verbatim: problem).font(Theme.Font.caption).foregroundStyle(Theme.danger)
            }
        }
        .accessibilityIdentifier("model-recovery.status")
    }

    private func submit() {
        guard canSubmit else { return }
        if modelFocused { TypedText.commitFocused(into: draft) }
        model.switchModelAndResume()
    }

    private func title(_ operation: ModelRecoveryOperation) -> String {
        switch operation.status {
        case .sending: return L10n.text("Changing model and waiting for Claude…")
        case .notSwitched: return L10n.text("Model change was not confirmed; resume was not sent.")
        case .switchedAndResumed:
            return String(format: L10n.text("Model changed to %@; resume sent."), operation.model)
        case .switchedNotResumed:
            return String(format: L10n.text("Model changed to %@; resume was not sent."), operation.model)
        case .notSent: return L10n.text("Model recovery was not sent.")
        case .unknown: return L10n.text("Model recovery result unknown — refresh first.")
        case .rejected: return L10n.text("Model recovery was refused.")
        }
    }

    private func detail(_ operation: ModelRecoveryOperation) -> String {
        switch operation.status {
        case .notSwitched(let detail), .switchedAndResumed(let detail), .switchedNotResumed(let detail),
             .notSent(let detail), .unknown(let detail), .rejected(let detail): return detail
        case .sending: return ""
        }
    }

    private func symbol(_ status: ModelRecoveryOperation.Status) -> String {
        if case .switchedAndResumed = status { return "checkmark.circle.fill" }
        return Theme.Icon.warning
    }

    private func tint(_ status: ModelRecoveryOperation.Status) -> Color {
        switch status {
        case .switchedAndResumed: return StatusPalette.idle.text
        case .sending: return .secondary
        case .notSwitched, .switchedNotResumed, .unknown: return Theme.cautionText
        case .notSent, .rejected: return Theme.danger
        }
    }
}
