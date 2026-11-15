// Adapted from nwverse/persona apple/Persona/Views/Chat/ChatView.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var state: ConversationState
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    @State private var progressShown = false
    @State private var attachPanel = AttachPanel()
    @State private var photosShown = false
    @State private var filesShown = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickerIdentity: ArgoAgentIdentity?
    @State private var preview: AttachmentPreview?

    var body: some View {
        let fileIdentity = state.transcript.identity
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let creation = state.creation {
                        DisclosureGroup {
                            Text("First message submitted with creation. Delivery has no separate receipt; check the Agent's native conversation.")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                            if let text = creation.text {
                                Text(verbatim: text).font(Theme.Font.secondary).textSelection(.enabled)
                                Button("Copy First Message") { UIPasteboard.general.string = text }
                            } else {
                                Text("The original first message was kept only in memory and is unavailable after restarting the app.")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            Button("Refresh Agent Status") { model.refreshAgents(); model.refreshConversation() }
                        } label: { Label("Agent Created", systemImage: Theme.Icon.info).font(Theme.Font.captionStrong) }
                        .accessibilityIdentifier("chat.creation")
                    }
                    if state.transcript.hasOlder {
                        Button { following = false; model.loadOlder() } label: {
                            HStack {
                                if state.loadingOlder { ProgressView().controlSize(.small) }
                                Text("Load Earlier Messages")
                            }
                            .font(Theme.Font.captionStrong).tapTargetHeight()
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(state.loadingOlder || !model.status.isConnected)
                    }
                    if let note = state.sessionNotice { NoticeBanner(text: note, tone: .caution, lineLimit: nil) }
                    ForEach(state.transcript.items) { item in MessageRow(item: item, openFile: { openRemote($0, identity: fileIdentity) }).id(item.id) }
                    if state.transcript.newer, !state.followingLatest {
                        Button("Load Newer Messages") { model.loadNewer() }
                            .font(Theme.Font.captionStrong).tapTargetHeight()
                            .disabled(state.loadingOlder || !model.status.isConnected)
                    }
                    if state.loading { ProgressView("Loading conversation…").frame(maxWidth: .infinity) }
                    if let note = state.transcript.waiting { NoticeBanner(text: note, tone: .neutral, lineLimit: nil) }
                    if let problem = state.problem {
                        NoticeBanner(text: problem, tone: .danger, lineLimit: nil) {
                            Button("Retry") { model.refreshConversation() }
                        }
                    }
                    if state.transcript.skipped > 0 {
                        Text("\(state.transcript.skipped) oversized records were omitted by the host.")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    if model.selectedAgent?.offersModelRecovery == true || state.modelRecovery != nil {
                        ModelRecoveryCard(agent: model.selectedAgent, state: state)
                    }
                    if let team = state.team {
                        ForEach(team.asks, id: \.uiID) { ask in QuestionCard(ask: ask, state: state) }
                    } else if !ArgoRun.isManaged(state.key.run), let ask = model.selectedAgent?.ask {
                        QuestionCard(ask: ask, state: state).id(ask.uiID)
                    }
                    queue
                    if !state.deliveries.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("Delivery Receipts").font(Theme.Font.sectionHeader).foregroundStyle(.secondary)
                            ForEach(state.deliveries) { message in
                                PendingBubble(message: message, retry: { model.retry(message) }, refresh: { model.showLatest() }, preview: openLocal)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) {
                $0.visibleRect.maxY >= $0.contentSize.height - Theme.Space.xxl
            } action: { _, atBottom in following = atBottom }
            .onChange(of: state.transcript.items.last) { _, _ in
                if following { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: state.deliveries.count) { _, _ in
                following = true
                withAnimation(reduceMotion ? nil : Theme.Motion.state) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following || !state.followingLatest {
                    Button {
                        following = true
                        if !state.followingLatest { model.showLatest() }
                        withAnimation(reduceMotion ? nil : Theme.Motion.layout) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    } label: { Image(systemName: "arrow.down").tapTargetFrame() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Jump to Latest Message")
                        .padding(Theme.Space.l)
                }
            }
        }
        .background(Theme.pageBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(model.selectedAgent?.displayTitle ?? L10n.text("Conversation"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.showsInterrupt || state.isInterruptBusy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.interruptCurrentTurn) {
                        if state.isInterruptBusy { ProgressView() }
                        else { ThemedIcon(Theme.Icon.interrupt).tapTargetFrame() }
                    }
                    .disabled(!model.canInterrupt)
                    .accessibilityLabel("Stop Current Turn")
                    .accessibilityIdentifier("toolbar-stop")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { progressShown = true } label: {
                    if let agent = model.selectedAgent {
                        HStack(spacing: Theme.Space.s) {
                            StatusDot(state: AgentSession(agent).state)
                            Image(systemName: "list.bullet.clipboard")
                        }
                        .tapTargetFrame()
                    } else { Image(systemName: "list.bullet.clipboard").tapTargetFrame() }
                }
                .accessibilityLabel("Agent Progress")
                .accessibilityValue(Text(verbatim: model.selectedAgent.map { AgentSession($0).state.label } ?? AgentState.unknown.label))
            }
        }
        .sheet(isPresented: $progressShown) {
            ChatProgressView(team: state.team, managed: ArgoRun.isManaged(state.key.run))
        }
        .sheet(isPresented: $attachPanel.shown, onDismiss: attachmentSheetClosed) {
            AttachSheet(panel: attachPanel, caption: $state.draft,
                        room: ArgoAttachmentPolicy.countLimit - state.attachments.count,
                        canSend: model.status.isConnected && state.canSendToIdentity && !state.isSending && !state.isInterruptBusy)
        }
        .photosPicker(isPresented: $photosShown, selection: $photoItems,
                      maxSelectionCount: max(1, ArgoAttachmentPolicy.countLimit - state.attachments.count),
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty, let identity = pickerIdentity else { return }
            model.addAttachments(PhotoAttach.inputs(items), to: state, identity: identity)
            photoItems = []
        }
        .fileImporter(isPresented: $filesShown, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if let identity = pickerIdentity { model.addAttachments(FileAttach.inputs(urls), to: state, identity: identity) }
            case .failure(let error): state.attachmentProblem = L10n.error(error)
            }
        }
        .sheet(item: $preview) { AttachmentViewer(preview: $0) }
        .environment(\.openURL, OpenURLAction { url in
            do {
                if let ref = try ArgoFileReference.link(url) { openRemote(ref, identity: fileIdentity); return .handled }
                if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return .systemAction }
                return .discarded
            } catch { state.attachmentProblem = L10n.error(error); return .handled }
        })
        .onAppear { model.showConversation(state.key, visible: true) }
        .onDisappear { model.showConversation(state.key, visible: false) }
        .onChange(of: progressShown) { _, shown in model.showConversation(state.key, visible: !shown) }
    }

    private var composer: some View {
        VStack(spacing: Theme.Space.s) {
            if let result = state.interruptStatus {
                NoticeBanner(text: result.message, tone: state.interruptNeedsReview ? .caution : .neutral, lineLimit: nil) {
                    if !state.isInterruptBusy {
                        Button("Refresh Agent Status") { model.refreshInterrupt() }
                            .disabled(!model.status.isConnected)
                    }
                }
            }
            if !state.canSendToIdentity {
                Text(L10n.text(ArgoRun.isManaged(state.key.run) ? "Waiting for the native conversation before sending." : "This session can be viewed here. Send messages from your computer."))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            DraftAttachments(state: state, open: openLocal)
            PromptComposer(placeholder: model.selectedAgent?.state == "working" ? L10n.text("Add a note (queued)") : L10n.text("Message Agent"),
                           text: $state.draft,
                           canSend: model.status.isConnected && state.canSendToIdentity && !state.isSending && !state.isInterruptBusy &&
                               (!state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.attachments.isEmpty),
                           sending: state.isMessageSending, showsStop: model.showsInterrupt || state.isInterruptBusy,
                           canStop: model.canInterrupt, stopping: state.isInterruptBusy,
                           agentName: model.selectedAgent.map { AgentSession($0).agentName } ?? "Agent",
                           send: { model.sendDraft(for: state.key) }, stop: { model.interruptCurrentTurn() },
                           canAttach: state.canSendToIdentity && !state.isSending && !state.isInterruptBusy && state.attachments.count < ArgoAttachmentPolicy.countLimit,
                           hasAttachments: !state.attachments.isEmpty,
                           attach: {
                               attachPanel.identity = state.transcript.identity
                               attachPanel.outcome = .closed
                               attachPanel.shown = true
                           })
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .background { Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom) }
    }

    private func attachmentSheetClosed() {
        let outcome = attachPanel.outcome
        if let identity = attachPanel.identity {
            model.addAttachments(PhotoAttach.inputs(assetIDs: attachPanel.picked), to: state, identity: identity)
            pickerIdentity = identity
        }
        attachPanel.picked = []
        attachPanel.outcome = .closed
        switch outcome {
        case .closed: break
        case .send: model.sendDraft(for: state.key)
        case .allPhotos:
            if state.attachments.count < ArgoAttachmentPolicy.countLimit { photosShown = true }
        case .files:
            if state.attachments.count < ArgoAttachmentPolicy.countLimit { filesShown = true }
        }
    }

    private func openLocal(_ file: ArgoLocalAttachment) { preview = AttachmentPreview(source: .local(file)) }
    private func openRemote(_ reference: ArgoFileReference, identity: ArgoAgentIdentity?) {
        guard let identity else { return }
        preview = AttachmentPreview(source: .remote(reference, state.key, identity))
    }

    @ViewBuilder private var queue: some View {
        if let queue = state.queue, !queue.items.isEmpty {
            DisclosureGroup {
                if !queue.hold.isEmpty { Text(verbatim: queue.hold).font(Theme.Font.caption).foregroundStyle(.secondary) }
                ForEach(queue.items) { item in
                    Text(verbatim: item.text).font(Theme.Font.secondary).readingContent().textSelection(.enabled)
                        .padding(.vertical, Theme.Space.xs)
                }
            } label: {
                Label("\(queue.items.count) messages queued on host", systemImage: Theme.Icon.time)
                    .font(Theme.Font.captionStrong)
            }
            .padding(Theme.Space.m)
            .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
        }
    }
}
