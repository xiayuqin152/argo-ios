import ArgoMobileKit
import SwiftUI

struct QuestionCard: View {
    let ask: ArgoAsk
    @Bindable var state: ConversationState
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var questionVisible = false
    @FocusState private var answerFocused: Bool

    private var answered: Bool { state.hasAnswered(ask) }
    private var engine: String { model.selectedAgent?.engine ?? "" }

    private var answer: Binding<String> {
        Binding(get: { state.replyDrafts[ask.uiID] ?? "" }, set: { state.replyDrafts[ask.uiID] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(LocalizedStringKey(answered ? "Answered" : "Needs You"), systemImage: answered ? "checkmark.circle" : "questionmark.circle")
                .font(Theme.Font.captionStrong).foregroundStyle(answered ? StatusPalette.idle.text : StatusPalette.needsYou.text)
            Text(verbatim: ask.text).font(Theme.Font.body).readingContent().textSelection(.enabled)
                .onScrollVisibilityChange(threshold: 0.1) { visible in
                    questionVisible = visible
                    reportDisplayedQuestion()
                }
            if answered {
                Text("Answer sent. Waiting for the agent to update.")
                    .font(Theme.Font.secondary).foregroundStyle(.secondary)
            } else if let pending = state.pendingReply(to: ask) {
                Text(L10n.text(pending.status.canRetry ? "Not Sent" : pending.status == .sending ? "Sending…" : "Delivery Unknown — Refresh First"))
                    .font(Theme.Font.secondary).foregroundStyle(.secondary)
                Text("Review the answer's delivery receipt below.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            } else if !ArgoRun.isManaged(state.key.run) {
                Text("Answer this request in your computer's terminal.")
                    .font(Theme.Font.secondary).foregroundStyle(.secondary)
            } else if ask.acceptsReply {
                ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                    Button { answer.wrappedValue = option } label: {
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Image(systemName: answer.wrappedValue == option ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(verbatim: option)
                                if ask.optionNotes.indices.contains(index), !ask.optionNotes[index].isEmpty {
                                    Text(verbatim: ask.optionNotes[index]).font(Theme.Font.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .font(Theme.Font.secondary)
                        .tapTargetHeight()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!ask.acceptsReply(option, engine: engine))
                    .accessibilityAddTraits(answer.wrappedValue == option ? .isSelected : [])
                }
                if ask.acceptsCustomReply(engine: engine) {
                    TextField("Your answer", text: answer, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($answerFocused)
                        .readingContent()
                } else {
                    Text("For a custom answer, use your computer's terminal.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if !ask.risk.isEmpty {
                    Text(L10n.text(ask.risk == "destructive" ? "This answer may trigger a destructive action." : "This answer may trigger an external action."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
                }
                Button("Send Answer") {
                    if answerFocused { TypedText.commitFocused(into: answer) }
                    if ask.risk.isEmpty { model.reply(to: ask) } else { confirming = true }
                }
                .buttonStyle(.glassProminent)
                .disabled(state.isSending || !state.canReply(to: ask) || !model.status.isConnected || !ask.acceptsReply(answer.wrappedValue, engine: engine))
            } else {
                Text(verbatim: ask.terminalOnly ?? L10n.text("Answer this request in your computer's terminal."))
                    .font(Theme.Font.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.l)
        .background(answered ? StatusPalette.idle.tint : StatusPalette.needsYouWash, in: .rect(cornerRadius: Theme.Radius.panel))
        .confirmationDialog("Send this answer?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Send Answer", role: ask.risk == "destructive" ? .destructive : nil) { model.reply(to: ask) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(verbatim: answer.wrappedValue) }
        .accessibilityIdentifier("question-" + ask.questionID)
        .onChange(of: ask) { _, _ in reportDisplayedQuestion() }
        .onChange(of: model.conversationVisible) { _, _ in reportDisplayedQuestion() }
        .onChange(of: model.status.isConnected) { _, _ in reportDisplayedQuestion() }
    }

    private func reportDisplayedQuestion() {
        if questionVisible { model.questionDisplayed(ask, in: state.key) }
    }
}
