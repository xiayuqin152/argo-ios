// Adapted from nwverse/persona apple/Persona/Views/Chat/ChatView.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var state: ConversationState
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    @State private var progressPresentation = SeenPresentation()
    @State private var photosPresentation = SeenPresentation()
    @State private var filesPresentation = SeenPresentation()
    @State private var previewPresentation = SeenPresentation()
    @State private var attachPanel = AttachPanel()
    @State private var photosShown = false
    @State private var filesShown = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickerIdentity: ArgoAgentIdentity?
    @State private var preview: AttachmentPreview?
    @State private var inputOwner: ComposerInputOwner?
    @State private var nativeToHide: (item: ArgoQueuedMessage, key: SessionKey)?
    @State private var queuePresentation = SeenPresentation()
    @State private var historyPresentation = SeenPresentation()

    private var attachPresentation: SeenPresentation { attachPanel.presentation }

    var body: some View {
        let fileIdentity = state.transcript.identity
        let fileKey = state.key
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let creation = state.creation {
                        DisclosureGroup {
                            Text("First message submitted with creation. Delivery has no separate receipt; check the Agent's native conversation.")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                            if let text = creation.text {
                                Text(verbatim: text).font(Theme.Font.secondary).readingContent().textSelection(.enabled)
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
                    ForEach(state.transcript.items) { item in
                        MessageRow(item: item, openFile: { openRemote($0, key: fileKey, identity: fileIdentity, message: item) })
                            .id(item.id)
                            .environment(\.openURL, OpenURLAction { url in
                                openMessageURL(url, item: item, key: fileKey, identity: fileIdentity)
                            })
                    }
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
                    if !state.deliveryReceipts.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text("Delivery Receipts").font(Theme.Font.sectionHeader).foregroundStyle(.secondary)
                            ForEach(state.deliveryReceipts) { message in
                                PendingBubble(message: message, currentIdentity: state.transcript.identity,
                                              retry: { model.retry(message) }, refresh: { model.showLatest() }, preview: openLocal)
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
        .confirmationDialog("Hide Handoff Record?", isPresented: Binding(get: { nativeToHide != nil }, set: { if !$0 { nativeToHide = nil } }),
                            titleVisibility: .visible, presenting: nativeToHide) { selection in
            Button("Hide Record", role: .destructive) { model.hideNativeHandoff(selection.item, for: selection.key) }
        } message: { _ in
            Text("This only hides the Argo status record. It does not cancel or retract input already received by Codex.")
        }
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
                    .accessibilityValue(Text(verbatim: state.interruptStatus?.message ?? ""))
                    .accessibilityIdentifier("toolbar-stop")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { progressPresentation.setPresented(true, in: model, conversation: state.key) } label: {
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
        .sheet(isPresented: progressPresentation.binding(in: model, conversation: state.key),
               onDismiss: { progressPresentation.didDismiss(in: model) }) {
            ChatProgressView(team: state.team, managed: ArgoRun.isManaged(state.key.run))
        }
        .sheet(isPresented: attachPresentation.binding(in: model, conversation: state.key), onDismiss: attachmentSheetClosed) {
            AttachSheet(panel: attachPanel, caption: $state.draft,
                        room: ArgoAttachmentPolicy.countLimit - state.attachments.count,
                        canSend: model.status.isConnected && state.canSendToIdentity && !state.isSending && !state.isInterruptBusy)
        }
        .sheet(isPresented: photosPresentation.binding(in: model, conversation: state.key),
               onDismiss: { photosPresentation.didDismiss(in: model) }) {
            pickerCover {
                photosShown = false
                photosPresentation.setPresented(false, in: model)
            }
            .photosPicker(isPresented: $photosShown, selection: $photoItems,
                          maxSelectionCount: max(1, ArgoAttachmentPolicy.countLimit - state.attachments.count),
                          selectionBehavior: .ordered, matching: .images)
            .onChange(of: photosShown) { _, shown in
                if !shown { photosPresentation.setPresented(false, in: model) }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty, let identity = pickerIdentity else { return }
            model.addAttachments(PhotoAttach.inputs(items), to: state, identity: identity)
            photoItems = []
        }
        .sheet(isPresented: filesPresentation.binding(in: model, conversation: state.key),
               onDismiss: { filesPresentation.didDismiss(in: model) }) {
            pickerCover {
                filesShown = false
                filesPresentation.setPresented(false, in: model)
            }
            .fileImporter(isPresented: $filesShown, allowedContentTypes: [.item], allowsMultipleSelection: true,
                          onCompletion: { result in
                switch result {
                case .success(let urls):
                    if let identity = pickerIdentity { model.addAttachments(FileAttach.inputs(urls), to: state, identity: identity) }
                case .failure(let error): state.attachmentProblem = L10n.error(error)
                }
                filesPresentation.setPresented(false, in: model)
            }, onCancellation: { filesPresentation.setPresented(false, in: model) })
        }
        .sheet(item: $preview, onDismiss: { previewPresentation.didDismiss(in: model) }) { AttachmentViewer(preview: $0) }
        .sheet(item: Binding(get: { state.queueItemRead }, set: { value in
            if value == nil, let read = state.queueItemRead { model.closeQueueItem(read) }
        }), onDismiss: { queuePresentation.didDismiss(in: model) }) { read in
            QueueFullMessageView(read: read)
        }
        .sheet(item: Binding(get: { state.nativeHistoryRead }, set: { value in
            if value == nil, let read = state.nativeHistoryRead { model.closeNativeHistory(read) }
        }), onDismiss: { historyPresentation.didDismiss(in: model) }) { read in
            NativeHistoryView(read: read)
        }
        .environment(\.openURL, OpenURLAction { url in
            openMessageURL(url, item: nil, key: fileKey, identity: fileIdentity)
        })
        .onAppear {
            renewInputOwner()
            model.showConversation(state.key, visible: true)
        }
        .onDisappear {
            inputOwner?.invalidate()
            model.showConversation(state.key, visible: false)
        }
        .onChange(of: model.selectedKey) { _, key in
            if key != state.key { inputOwner?.invalidate() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { renewInputOwner() }
        }
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
                .readingContent()
            }
            if !state.canSendToIdentity {
                Text(L10n.text(ArgoRun.isManaged(state.key.run) ? "Waiting for the native conversation before sending." : "This session can be viewed here. Send messages from your computer."))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            DraftAttachments(state: state, open: openLocal)
            if let inputOwner {
                let target = inputOwner.state
                let identity = target.transcript.identity
                PromptComposer(placeholder: model.selectedAgent?.state == "working" ? L10n.text("Add a note (queued)") : L10n.text("Message Agent"),
                           input: inputOwner,
                           canSend: model.status.isConnected && state.canSendToIdentity && !state.isSending && !state.isInterruptBusy &&
                               (!state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.attachments.isEmpty),
                           sending: state.isMessageSending, showsStop: model.showsInterrupt || state.isInterruptBusy,
                           canStop: model.canInterrupt, stopping: state.isInterruptBusy,
                           stopStatus: state.interruptStatus?.message,
                           agentName: model.selectedAgent.map { AgentSession($0).agentName } ?? "Agent",
                           send: {
                               if inputOwner.acceptsInput { model.sendDraft(for: target.key) }
                           }, stop: {
                               if inputOwner.acceptsInput { model.interruptCurrentTurn() }
                           },
                           canAttach: state.canSendToIdentity && !state.isSending && !state.isInterruptBusy && state.attachments.count < ArgoAttachmentPolicy.countLimit,
                           hasAttachments: !state.attachments.isEmpty,
                           attach: {
                               attachPresentation.setPresented(true, in: model, conversation: state.key)
                               guard attachPresentation.isPresented else { return }
                               attachPanel.identity = state.transcript.identity
                               attachPanel.outcome = .closed
                           }, paste: { providers in
                               guard inputOwner.acceptsInput, target.canSendToIdentity,
                                     !target.isSending, !target.isInterruptBusy, let identity,
                                     target.transcript.identity == identity else { return }
                               model.addAttachments(PhotoAttach.inputs(providers: providers), to: target, identity: identity)
                           })
                .id(inputOwner.id)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .background { Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom) }
    }

    private func renewInputOwner() {
        guard inputOwner?.acceptsInput != true else { return }
        inputOwner?.invalidate()
        let target = state
        inputOwner = ComposerInputOwner(state: target,
            destinationIsCurrent: { model.selectedKey == target.key && model.conversation === target },
            foreground: { model.acceptsComposerInput })
    }

    private func attachmentSheetClosed() {
        let completedOwner = attachPresentation.owner
        defer { attachPresentation.didDismiss(completedOwner, in: model) }
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
            if state.attachments.count < ArgoAttachmentPolicy.countLimit {
                photosPresentation.setPresented(true, in: model, conversation: state.key)
                if photosPresentation.isPresented { photosShown = true }
            }
        case .files:
            if state.attachments.count < ArgoAttachmentPolicy.countLimit {
                filesPresentation.setPresented(true, in: model, conversation: state.key)
                if filesPresentation.isPresented { filesShown = true }
            }
        }
    }

    // System picker bindings/results request closure. Only this enclosing
    // sheet's onDismiss releases coverage, including cancellation/animation.
    private func pickerCover(cancel: @escaping () -> Void) -> some View {
        NavigationStack {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
    }

    private func openLocal(_ file: ArgoLocalAttachment) {
        guard previewPresentation.owner == nil else { return }
        previewPresentation.setPresented(true, in: model, conversation: state.key)
        preview = AttachmentPreview(source: .local(file))
    }
    private func openMessageURL(_ url: URL, item: ArgoChatItem?, key: SessionKey,
                                identity: ArgoAgentIdentity?) -> OpenURLAction.Result {
        do {
            switch try model.messageLink(url, item: item, key: key, identity: identity) {
            case .remote(let ref):
                openRemote(ref, key: key, identity: identity, message: item)
                return .handled
            case .external: return .systemAction
            case .discarded: return .discarded
            }
        } catch { state.attachmentProblem = L10n.error(error); return .handled }
    }
    private func openRemote(_ reference: ArgoFileReference, key: SessionKey,
                            identity: ArgoAgentIdentity?, message: ArgoChatItem?) {
        guard let identity, previewPresentation.owner == nil else { return }
        previewPresentation.setPresented(true, in: model, conversation: key)
        preview = AttachmentPreview(source: .remote(reference, key, identity, message))
    }

    @ViewBuilder private var queue: some View {
        if let problem = state.nativeHideProblem {
            NoticeBanner(text: problem, tone: .caution, lineLimit: nil) {
                Button("Refresh Conversation") { model.refreshConversation() }
            }
        }
        if let queue = state.queue, state.pendingQueueCount > 0 || !state.ordinaryQueueItems.isEmpty {
            DisclosureGroup {
                if !queue.hold.isEmpty { Text(verbatim: queue.hold).font(Theme.Font.caption).foregroundStyle(.secondary) }
                if !queue.truncatedFields.isEmpty { Text("Queue details are a shortened preview.").font(Theme.Font.caption).foregroundStyle(.secondary) }
                ForEach(state.ordinaryQueueItems) { item in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        if let reason = state.deliveryUnknown(for: item) {
                            Label("Delivery Unknown — Refresh First", systemImage: Theme.Icon.warning)
                                .font(Theme.Font.captionStrong).foregroundStyle(Theme.cautionText)
                            Text(verbatim: reason).font(Theme.Font.caption).foregroundStyle(.secondary)
                                .readingContent()
                        }
                        queueMessage(item)
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            } label: {
                if state.ordinaryQueueItems.contains(where: { state.deliveryUnknown(for: $0) != nil }) {
                    Label("Delivery Unknown — Refresh First", systemImage: Theme.Icon.warning)
                        .font(Theme.Font.captionStrong).foregroundStyle(Theme.cautionText)
                } else {
                    Label("\(state.pendingQueueCount) messages queued on host", systemImage: Theme.Icon.time)
                        .font(Theme.Font.captionStrong)
                }
            }
            .padding(Theme.Space.m)
            .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
        }
        if state.nativeHistoryCount > 0 {
            DisclosureGroup {
                ForEach(state.nativeQueueItems) { item in
                    if let native = item.native {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Label(L10n.text(native.state == .accepted ? "Codex Received" : "Native Receipt Unknown"),
                                  systemImage: native.state == .accepted ? "tray" : Theme.Icon.warning)
                                .font(Theme.Font.captionStrong)
                            NativeHandoffDetails(native: native, target: item.target, currentIdentity: state.transcript.identity)
                            queueMessage(item)
                            HStack(spacing: Theme.Space.l) {
                                Button("Hide Record") { nativeToHide = (item, state.key) }
                                    .disabled(state.hidingNativeIDs.contains(item.id) || !model.status.isConnected)
                                    .tapTargetHeight()
                            }
                            .font(Theme.Font.captionStrong)
                        }
                        .padding(.vertical, Theme.Space.s)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("Native records: \(state.nativeHistoryCount)", systemImage: "tray")
                    if state.nativeQueueItems.contains(where: { $0.native?.state == .unknown }) {
                        Label("Native Receipt Unknown", systemImage: Theme.Icon.warning).foregroundStyle(Theme.cautionText)
                    }
                }
                .font(Theme.Font.captionStrong)
            }
            .padding(Theme.Space.m)
            .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
        }
        if !state.nativeHistorySources.isEmpty || model.sourceHistoryProblem != nil {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label("Records Before Resume", systemImage: "clock.arrow.circlepath")
                    .font(Theme.Font.captionStrong)
                Text("Read-only records from the original conversation. These are not pending messages or confirmation of model completion.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary).readingContent()
                if let problem = model.sourceHistoryProblem {
                    NoticeBanner(text: L10n.text("Some earlier records could not be loaded. Current messages and receipts remain available.") + "\n" + problem,
                                 tone: .caution, lineLimit: nil) {
                        Button("Refresh Records") { model.refreshConversation() }
                            .disabled(!model.status.isConnected)
                    }
                }
                ForEach(Array(state.nativeHistorySources.enumerated()), id: \.offset) { _, source in
                    Button {
                        guard historyPresentation.owner == nil else { return }
                        model.openNativeHistory(source, for: state.key)
                        if state.nativeHistoryRead != nil { historyPresentation.cover(in: model, conversation: state.key) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(verbatim: source.sourceRun).lineLimit(2)
                                Text("Read-only records: \(source.nativeHistory)").font(Theme.Font.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).tapTargetHeight()
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.status.isConnected)
                }
            }
            .padding(Theme.Space.m)
            .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
        }
    }

    @ViewBuilder private func queueMessage(_ item: ArgoQueuedMessage) -> some View {
        if item.isIncomplete {
            Text("Shortened preview — original content remains on the host.")
                .font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
        }
        Text(verbatim: item.text).font(Theme.Font.secondary).readingContent().textSelection(.disabled)
        HStack(spacing: Theme.Space.l) {
            Button("Copy Full Message") { openQueueItem(item, copy: true) }.disabled(!model.status.isConnected).tapTargetHeight()
            Button("View Full Message") { openQueueItem(item, copy: false) }.disabled(!model.status.isConnected).tapTargetHeight()
        }
        .font(Theme.Font.captionStrong)
    }

    private func openQueueItem(_ item: ArgoQueuedMessage, copy: Bool) {
        guard queuePresentation.owner == nil else { return }
        model.openQueueItem(item, for: state.key, copy: copy)
        if state.queueItemRead != nil { queuePresentation.cover(in: model, conversation: state.key) }
    }
}

private struct NativeHistoryView: View {
    @Bindable var read: NativeHistoryRead
    @Environment(AppModel.self) private var model
    @State private var nativeToHide: ArgoQueuedMessage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Read-only records from the original conversation. These are not pending messages or confirmation of model completion.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary).readingContent()
                    Text(verbatim: [read.key.workspace, read.source.sourceRun, read.source.target.engine,
                                    read.source.target.session].joined(separator: "\n"))
                        .font(Theme.Font.caption).readingContent().textSelection(.enabled)
                    if read.loading { ProgressView("Loading Original Records…") }
                    if let problem = read.problem {
                        NoticeBanner(text: L10n.text("Original records could not be loaded.") + "\n" + problem,
                                     tone: .caution, lineLimit: nil)
                    }
                    if let problem = read.hideProblem {
                        NoticeBanner(text: problem, tone: .caution, lineLimit: nil)
                    }
                    if let problem = read.queue?.nativeSourcesError, !problem.isEmpty {
                        NoticeBanner(text: L10n.text("Some earlier records could not be loaded. Current messages and receipts remain available.") + "\n" + problem,
                                     tone: .caution, lineLimit: nil)
                    }
                    if !read.loading {
                        Button("Refresh Records") { model.refreshNativeHistory(read) }
                            .disabled(!model.status.isConnected || !read.hidingIDs.isEmpty).tapTargetHeight()
                    }
                    ForEach(read.rows) { item in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            if let native = item.native {
                                Label(L10n.text(native.state == .accepted ? "Codex Received" : "Native Receipt Unknown"),
                                      systemImage: native.state == .accepted ? "tray" : Theme.Icon.warning)
                                    .font(Theme.Font.captionStrong)
                                NativeHandoffDetails(native: native, target: item.target, currentIdentity: read.source.target)
                            } else {
                                Label("Delivery Unknown — Refresh First", systemImage: Theme.Icon.warning)
                                    .font(Theme.Font.captionStrong).foregroundStyle(Theme.cautionText)
                                Text("The original terminal may have received this input. Review the original conversation before sending it again.")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary).readingContent()
                                Text(verbatim: item.deliveryUnknown).font(Theme.Font.caption).readingContent()
                            }
                            if item.isIncomplete {
                                Text("Shortened preview — original content remains on the host.")
                                    .font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
                            }
                            Text(verbatim: item.text).font(Theme.Font.secondary).readingContent().textSelection(.disabled)
                            HStack(spacing: Theme.Space.l) {
                                Button("Copy Full Message") { model.openNativeHistoryItem(item, in: read, copy: true) }.tapTargetHeight()
                                Button("View Full Message") { model.openNativeHistoryItem(item, in: read) }.tapTargetHeight()
                            }
                            .font(Theme.Font.captionStrong).disabled(!model.status.isConnected)
                            if item.native != nil {
                                Button("Hide Record") { nativeToHide = item }
                                    .font(Theme.Font.captionStrong).tapTargetHeight()
                                    .disabled(!model.status.isConnected || read.hidingIDs.contains(item.id) || read.hideProblem != nil)
                            }
                        }
                        .padding(Theme.Space.m)
                        .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
                    }
                    if !read.loading, read.problem == nil, read.rows.isEmpty {
                        Text("No remaining visible records for this source. Refresh the conversation to update its sources.")
                            .font(Theme.Font.caption).readingContent()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.m)
            }
            .navigationTitle("Records Before Resume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.closeNativeHistory(read) } } }
        }
        .confirmationDialog("Hide Handoff Record?", isPresented: Binding(get: { nativeToHide != nil }, set: { if !$0 { nativeToHide = nil } }),
                            titleVisibility: .visible, presenting: nativeToHide) { item in
            Button("Hide Record", role: .destructive) { model.hideNativeHistoryItem(item, in: read) }
        } message: { _ in
            Text("This only hides the Argo status record. It does not cancel or retract input already received by Codex.")
        }
        .sheet(item: Binding(get: { read.queueItemRead }, set: { value in
            if value == nil, let full = read.queueItemRead { model.closeQueueItem(full) }
        })) { full in
            QueueFullMessageView(read: full)
        }
    }
}

private struct QueueFullMessageView: View {
    @Bindable var read: QueueItemRead
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let problem = read.problem {
                        Text("The complete message could not be loaded. The queue record is unchanged.").font(Theme.Font.captionStrong)
                        Text(verbatim: problem).readingContent()
                    } else if let item = read.item {
                        if item.isIncomplete {
                            Text("Queue details are a shortened preview.").font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        if let native = item.native {
                            NativeHandoffDetails(native: native, target: item.target, currentIdentity: read.identity)
                        } else {
                            Text("Original Conversation").font(Theme.Font.captionStrong)
                            Text(verbatim: [read.key.workspace, read.run, item.target?.session ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary).readingContent()
                        }
                        Text(verbatim: item.text).readingContent().textSelection(.enabled)
                        if !item.deliveryUnknown.isEmpty { Text(verbatim: item.deliveryUnknown).readingContent() }
                        Button {
                            if let text = model.queueItemText(read) { UIPasteboard.general.string = text; copied = true }
                        } label: { Label("Copy", systemImage: Theme.Icon.copy) }
                        .tapTargetHeight()
                        if copied { Text("Copied").font(Theme.Font.caption).foregroundStyle(.secondary) }
                    } else { ProgressView("Loading Full Message…") }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.m)
            }
            .navigationTitle("Full Message")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.closeQueueItem(read) } } }
        }
        .onChange(of: read.item, initial: true) { _, _ in
            guard read.copyWhenLoaded, !copied, let text = model.queueItemText(read) else { return }
            UIPasteboard.general.string = text
            copied = true
        }
    }
}
