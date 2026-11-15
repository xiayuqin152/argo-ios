// Sidebar hierarchy adapted from nwverse/persona apple/Persona/Views/Shell/UnifiedSidebar.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import SwiftUI

struct HostWorkspaceView: View {
    var close: (() -> Void)? = nil
    @Binding var pairingShown: Bool
    var pairingDismissed: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hostToForget: LoomHost?
    @State private var confirmingForget = false
    @State private var removingHostID: UUID?
    @State private var removalProblem: String?
    @State private var pairingPresentation = SeenPresentation()

    var body: some View {
        NavigationStack {
            List {
                Section("Hosts") {
                    ForEach(model.hosts) { host in
                        HStack(spacing: Theme.Space.s) {
                            Button { model.selectHost(host.id) } label: {
                                HStack(spacing: Theme.Space.m) {
                                    Image(systemName: "desktopcomputer").frame(width: Theme.Size.icon)
                                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                        Text(verbatim: host.displayName).font(Theme.Font.bodyStrong)
                                        Text(verbatim: host.address).font(Theme.Font.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: Theme.Space.s)
                                    if model.hostID == host.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .tapTargetHeight()
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.hostID == host.id ? .isSelected : [])
                            Menu {
                                Button("Forget Host", role: .destructive) {
                                    hostToForget = host
                                    confirmingForget = true
                                }
                            } label: {
                                Image(systemName: "ellipsis").tapTargetFrame()
                            }
                            .accessibilityLabel(Text(verbatim: String(format: L10n.text("Actions for %@"), host.displayName)))
                            .disabled(removingHostID != nil || model.pairing)
                        }
                    }
                    Button { pairingBinding.wrappedValue = true } label: { Label("Connect a Host", systemImage: Theme.Icon.add) }
                        .disabled(removingHostID != nil)
                }
                if model.status.needsPairing {
                    Section {
                        Text(verbatim: model.status.problem ?? "").foregroundStyle(.secondary)
                        Button("Pair Again") { pairingBinding.wrappedValue = true }
                            .disabled(removingHostID != nil)
                    }
                }
                Section("Workspaces") {
                    if model.status == .connecting { ProgressView("Loading workspaces…") }
                    ForEach(model.projects) { project in
                        let spaces = model.workspaces.filter { $0.projectId == project.id }
                        if !spaces.isEmpty {
                            DisclosureGroup {
                                ForEach(spaces) { workspaceRow($0) }
                            } label: {
                                Label { Text(verbatim: project.name) } icon: { Image(systemName: Theme.Icon.folder) }
                            }
                        }
                    }
                    ForEach(model.workspaces.filter { workspace in !model.projects.contains { $0.id == workspace.projectId } }) {
                        workspaceRow($0)
                    }
                    if model.workspaces.isEmpty, model.status.isConnected {
                        Text("No workspaces on this host.").foregroundStyle(.secondary)
                    }
                }
                if let server = model.server {
                    Section {
                        LabeledContent("Host", value: server.machine ?? model.selectedHost?.displayName ?? "")
                        if let version = server.version { LabeledContent("Version", value: version) }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                }
                Section {
                    Button("Reconnect and Refresh") { model.reconnect() }
                        .disabled(model.status == .connecting)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Shell.drawer)
            .navigationTitle("Hosts and Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: finish) } }
        }
        .sheet(isPresented: pairingBinding, onDismiss: {
            pairingPresentation.didDismiss(in: model)
            pairingDismissed()
        }) { PairingView() }
        .confirmationDialog("Forget Host?", isPresented: $confirmingForget,
                            titleVisibility: .visible, presenting: hostToForget) { host in
            Button("Forget Host", role: .destructive) {
                removingHostID = host.id
                Task {
                    defer { removingHostID = nil }
                    do { try await model.removeHost(host.id) }
                    catch { removalProblem = L10n.error(error) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { host in
            Text(verbatim: String(format: L10n.text("Forget “%@” on this device? Saved conversations, drafts and delivery receipts will be cleared. The host's device authorization stays active."), host.displayName))
        }
        .alert("Couldn't forget host", isPresented: Binding(
            get: { removalProblem != nil },
            set: { if !$0 { removalProblem = nil } }
        )) {
            Button("Done", role: .cancel) { removalProblem = nil }
        } message: {
            Text(verbatim: removalProblem ?? "")
        }
    }

    private var pairingBinding: Binding<Bool> {
        Binding(get: { pairingShown }, set: { shown in
            pairingPresentation.setPresented(shown, in: model)
            pairingShown = pairingPresentation.isPresented
        })
    }

    private func workspaceRow(_ workspace: ArgoWorkspace) -> some View {
        Button {
            model.selectWorkspace(workspace.id)
            finish()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: Theme.Icon.workspace)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(verbatim: workspace.name).font(Theme.Font.body)
                    Text(verbatim: workspace.path).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                if workspace.id == model.workspaceID { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .foregroundStyle(.primary)
            .tapTargetHeight()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(workspace.id == model.workspaceID ? .isSelected : [])
    }

    private func finish() { if let close { close() } else { dismiss() } }
}
