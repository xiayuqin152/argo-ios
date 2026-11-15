// Adapted from nwverse/persona apple/Persona/Views/NewChat/NewChatView.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import SwiftUI
import UIKit

/// Persona's NavigationStack + Form, machine cards, pushed choices, permission
/// row, first message and bottom Start/error card, backed by Argo's real API.
struct NewChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool

    var body: some View {
        @Bindable var launch = model.newSession
        NavigationStack {
            Form {
                inputs.disabled(!launch.canEdit)
                if let intent = launch.current { recovery(intent) }
                let previous = launch.pending.filter {
                    $0.host == model.hostID && $0.workspace == model.workspaceID && $0.context != launch.currentContext
                }
                if !previous.isEmpty {
                    Section("Previous Creation Intents") {
                        if previous.contains(where: { $0.receipt == nil }) {
                            Text("A previous result remains unknown. Starting another Agent creates a separate session.")
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        ForEach(previous) { intent in
                            Button { launch.review(intent) } label: {
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Text(verbatim: intent.profile).font(Theme.Font.heading)
                                    Text(verbatim: intent.context).font(Theme.Font.label).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(launch.creating)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(launch.creating)
                }
            }
            .safeAreaInset(edge: .bottom) { startBar }
            .interactiveDismissDisabled(launch.creating)
        }
    }

    private var inputs: some View {
        @Bindable var launch = model.newSession
        return Group {
            Section("Machines") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.m) {
                        ForEach(model.hosts) { host in
                            Button { model.selectHost(host.id) } label: {
                                VStack(alignment: .leading, spacing: Theme.Space.s) {
                                    Image(systemName: "desktopcomputer").font(Theme.Font.heading)
                                    Text(verbatim: host.displayName).font(Theme.Font.heading)
                                    if model.hostID == host.id {
                                        Label("Selected", systemImage: "checkmark.circle.fill").font(Theme.Font.label)
                                    }
                                }
                                .padding(Theme.Space.m)
                                .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.hostID == host.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            }
            Section {
                Picker("Workspace", selection: Binding(get: { model.workspaceID ?? "" }, set: { model.selectWorkspace($0) })) {
                    Text("Choose Workspace").tag("")
                    ForEach(model.workspaces) { workspace in Text(verbatim: workspace.name).tag(workspace.id) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("newChat.workspace")
                Picker("Folder", selection: $launch.draft.cwd) {
                    Text("Choose Folder").tag("")
                    ForEach(model.selectedWorkspace?.roots.filter { !$0.missing } ?? [], id: \.path) { root in
                        VStack(alignment: .leading) {
                            Text(verbatim: root.name.isEmpty ? root.path : root.name)
                            Text(verbatim: root.path).font(Theme.Font.label).foregroundStyle(.secondary)
                        }.tag(root.path)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("newChat.folder")
            } header: { Text("Workspace & Folder") } footer: {
                Text("Choose an existing workspace and a folder that is present on this host.")
            }
            Section {
                NavigationLink {
                    launcherPicker
                } label: {
                    HStack {
                        ThemedIcon(Theme.Icon.commandLine).foregroundStyle(Theme.accent)
                        Text(launch.draft.profile.isEmpty ? L10n.text("Choose Launcher") : launch.draft.profile)
                            .font(Theme.Font.heading.monospaced())
                        Spacer()
                        if launch.profilesLoading { ProgressView().controlSize(.small) }
                    }
                }
                .accessibilityIdentifier("newChat.launcher")
                LabeledContent("Model", value: L10n.text("Use this CLI's settings"))
                    .accessibilityIdentifier("newChat.model")
            } header: { Text("Launcher & Model") } footer: {
                Text("Available Claude and Codex profiles, including wrappers. Model and effort follow the selected CLI's settings.")
            }
            Section {
                Picker("Permission Mode", selection: $launch.draft.permission) {
                    ForEach(ArgoLaunchPermission.allCases, id: \.self) { permission in
                        Text(permission.title).tag(permission)
                            .disabled(permission != .full && launch.selectedProfile?.fixedPermission.isEmpty == false)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                .accessibilityIdentifier("newChat.permission")
                if let reason = launch.selectedProfile?.fixedPermission, !reason.isEmpty {
                    Label(reason, systemImage: "lock.fill")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("newChat.fixedPermission")
                }
            } header: { Text("Permissions") } footer: {
                Text(launch.draft.permission.detail)
            }
            Section {
                TextField(L10n.text("What should this Agent do?"), text: $launch.draft.prompt, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($promptFocused)
                    .accessibilityLabel("First Message")
                    .accessibilityIdentifier("newChat.prompt")
            } header: { Text("First Message") } footer: {
                Text("Required. Submitted once with creation. Delivery waits for the CLI and has no separate receipt.")
            }
        }
    }

    private var launcherPicker: some View {
        @Bindable var launch = model.newSession
        return List {
            if let problem = launch.profilesProblem { Text(verbatim: problem).foregroundStyle(Theme.danger) }
            ForEach(launch.profiles) { profile in
                Button { launch.draft.profile = profile.name } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(verbatim: profile.name).font(Theme.Font.heading.monospaced())
                            Text(verbatim: profile.command).font(Theme.Font.label).foregroundStyle(.secondary)
                            if !profile.available { Text("Not installed on this host").font(Theme.Font.caption) }
                            else if !profile.supported { Text("This engine is not supported for mobile creation").font(Theme.Font.caption) }
                        }
                        Spacer()
                        if launch.draft.profile == profile.name { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
                .disabled(!profile.canLaunch || !launch.canEdit)
            }
            Button("Refresh Launchers") { model.refreshLaunchProfiles() }
                .disabled(launch.profilesLoading || !model.status.isConnected)
        }
        .navigationTitle("Choose Launcher")
    }

    private func recovery(_ intent: PendingAgentCreation) -> some View {
        let launch = model.newSession
        return Section {
            LabeledContent("Launcher", value: intent.profile)
            Text(verbatim: intent.cwd).font(Theme.Font.code).textSelection(.enabled)
            Text(verbatim: intent.context).font(Theme.Font.label).textSelection(.enabled)
            if intent.receipt != nil {
                Button("Open Agent") { model.openCreation(intent) }
            } else if launch.busyContext != intent.context {
                Text("The previous creation may have reached the host. Check this intent before deciding to start another Agent.")
                Button("Check Creation Result") { model.checkCreation(intent) }
                    .disabled(!model.status.isConnected || launch.checking.contains(intent.context))
                if let matches = launch.candidates[intent.context], matches.count > 1 {
                    Text("Multiple exact matches. Choose an Agent explicitly.")
                    ForEach(matches) { terminal in
                        Button {
                            launch.choose(terminal, for: intent) { model.openCreation($0) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: terminal.agent?.run ?? terminal.id)
                                Text(verbatim: terminal.id).font(Theme.Font.label).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Start Another Agent") { launch.startAnother() }
                    .disabled(launch.storageProblem != nil)
            }
            if let prompt = launch.originalPrompt {
                Button("Copy First Message") { UIPasteboard.general.string = prompt }
            }
        } header: { Text(intent.receipt == nil ? L10n.text("Creation Result Pending") : L10n.text("Agent Created")) }
    }

    private var startBar: some View {
        @Bindable var launch = model.newSession
        return VStack(spacing: Theme.Space.s) {
            if let storage = launch.storageProblem {
                statusCard(L10n.text("Creation metadata could not be saved or read. No new Agent can be started.") + "\n" + storage, error: true)
                Button("Retry Local Storage") { launch.retryStorage() }
            } else if let problem = launch.problem {
                statusCard(problem, error: true)
            } else if let reason = notReadyReason {
                statusCard(reason, error: false)
            }
            if launch.current == nil || launch.creating {
                Button {
                    if promptFocused { TypedText.commitFocused(into: $launch.draft.prompt) }
                    promptFocused = false
                    model.startNewSession()
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        if launch.creating { ProgressView() }
                        Text(launch.creating ? L10n.text("Starting…") : L10n.text("Start Agent")).font(Theme.Font.heading)
                    }
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.wellS)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(notReadyReason != nil || !launch.canEdit)
                .accessibilityIdentifier("newChat.start")
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.bottom, Theme.Space.s)
        .background(.bar)
    }

    private func statusCard(_ text: String, error: Bool) -> some View {
        Label(text, systemImage: error ? Theme.Icon.errorFilled : Theme.Icon.info)
            .font(Theme.Font.caption).foregroundStyle(error ? Theme.danger : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.card))
            .accessibilityIdentifier(error ? "newChat.error" : "newChat.notReady")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var notReadyReason: String? {
        let launch = model.newSession
        if launch.current != nil { return nil }
        if !model.status.isConnected { return L10n.text("Connect to the selected host first.") }
        if model.selectedWorkspace == nil { return L10n.text("Choose a workspace first.") }
        if launch.draft.cwd.isEmpty { return L10n.text("Choose an existing folder.") }
        if launch.selectedProfile?.canLaunch != true { return L10n.text("Choose an available Claude or Codex launcher.") }
        if launch.selectedProfile?.fixedPermission.isEmpty == false && launch.draft.permission != .full {
            return launch.selectedProfile?.fixedPermission
        }
        if launch.draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("Enter a first message.") }
        if launch.draft.prompt.utf8.count > 256 * 1024 { return L10n.text("The message exceeds 256 KiB.") }
        return nil
    }
}

private extension ArgoLaunchPermission {
    var title: String {
        let key = switch self {
        case .full: "Full (Argo default)"
        case .workspaceShell: "Workspace + Shell"
        case .workspace: "Workspace"
        case .readonly: "Read Only"
        }
        return L10n.text(key)
    }
    var detail: String {
        let key = switch self {
        case .full: "Keeps the CLI profile's permission settings, as in Argo Web. A restricted profile remains restricted."
        case .workspaceShell: "Workspace files and shell commands. The host enforces this launch's restrictions."
        case .workspace: "Workspace file access. The host enforces this launch's restrictions."
        case .readonly: "Read-only access. The host enforces this launch's restrictions."
        }
        return L10n.text(key)
    }
}
