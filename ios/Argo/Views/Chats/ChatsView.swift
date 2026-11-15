// Adapted from nwverse/persona apple/Persona/Views/Chats/ChatsView.swift @ 3002eb3 (MIT).
import SwiftUI

struct ChatsView: View {
    @Environment(AppModel.self) private var model
    let openHosts: () -> Void
    let openSettings: () -> Void

    var body: some View {
        @Bindable var model = model
        let list = List(selection: Binding(get: { model.selectedKey }, set: { model.selectSession($0) })) {
            ForEach(model.startingCreations) { intent in
                if let key = intent.key {
                    NavigationLink(value: key) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(verbatim: intent.profile).font(Theme.Font.heading)
                            Text(intent.receipt?.alive == false ? L10n.text("Agent Stopped") : L10n.text("Agent Created · Waiting for Status"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Theme.Space.s)
                    }
                    .accessibilityIdentifier("agents.created")
                }
            }
            ForEach(model.visibleAgents) { card in
                if let key = model.key(for: card) {
                    NavigationLink(value: key) { SlotRow(session: AgentSession(card)) }
                        .accessibilityValue(card.unread && AgentSession(card).state != .unread ? Text("Unread") : Text(""))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Theme.Space.s, leading: Theme.Space.l,
                                                  bottom: Theme.Space.s, trailing: Theme.Space.l))
                }
            }
        }
        Group {
            if model.agentRefreshAvailable {
                list.refreshable { model.refreshAgents() }
            } else {
                list
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.pageBackground)
        .overlay { emptyState }
        .searchable(text: $model.search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search agents"))
        .safeAreaInset(edge: .top, spacing: Theme.Space.s) {
            CapsuleFilterBar(items: filterItems, selection: model.filter.rawValue,
                             choose: { if let choice = AgentFilter(rawValue: $0) { model.filter = choice } }) {
                Button { model.refreshAgents() } label: {
                    if model.refreshingAgents {
                        ProgressView().controlSize(.small).tapTargetFrame()
                    } else {
                        Image(systemName: Theme.Icon.retry).tapTargetFrame()
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.canRefreshAgents)
                .accessibilityLabel("Refresh Agents")
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.s)
            .background(Theme.pageBackground)
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.presentNewSession() } label: { Image(systemName: Theme.Icon.add).tapTargetFrame() }
                    .accessibilityLabel("New Agent")
                    .accessibilityIdentifier("agents.new")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("open-settings")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openHosts) {
                    Image("ArgoMark").resizable().scaledToFit()
                        .scaledFrame(width: Theme.Size.wellS, height: Theme.Size.wellS)
                        .clipShape(.rect(cornerRadius: Theme.Radius.control))
                        .tapTargetFrame()
                }
                .accessibilityLabel("Hosts and Workspaces")
                .accessibilityValue(Text(verbatim: selectionAccessibilityValue))
                .accessibilityIdentifier("hosts-workspaces")
            }
            ToolbarItem(placement: .principal) {
                Button(action: openHosts) {
                    VStack(spacing: Theme.Space.xxs) {
                        Text("Argo").font(Theme.Font.heading)
                        Text(verbatim: model.selectedWorkspace?.name ?? model.selectedHost?.displayName ?? "")
                            .font(Theme.Font.label).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose Host or Workspace")
                .accessibilityValue(Text(verbatim: selectionAccessibilityValue))
            }
        }
    }

    private var selectionAccessibilityValue: String {
        String(format: L10n.text("Host: %@. Workspace: %@."),
               model.selectedHost?.displayName ?? L10n.text("No host selected"),
               model.selectedWorkspace?.name ?? L10n.text("No workspace selected"))
    }

    @ViewBuilder private var emptyState: some View {
        if model.loadingAgents {
            ProgressView("Loading agents…")
        } else if model.visibleAgents.isEmpty && model.startingCreations.isEmpty {
            if !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else if model.workspaceID == nil {
                ContentUnavailableView("No Workspaces", systemImage: Theme.Icon.workspace,
                                       description: Text("Create a workspace on your computer, then reconnect to refresh."))
            } else {
                ContentUnavailableView {
                    Label("No Agents", systemImage: Theme.Icon.terminal)
                } description: {
                    Text(L10n.text(model.filter == .all ? "Start an Agent in this workspace." : "No agents match this filter."))
                } actions: {
                    Button("New Agent") { model.presentNewSession() }
                }
            }
        }
    }

    private var filterItems: [CapsuleFilterItemData] {
        AgentFilter.allCases.map { filter in
            CapsuleFilterItemData(id: filter.rawValue, title: filter.title,
                                  count: model.agents.filter { filter.includes(AgentSession($0)) }.count,
                                  tone: filter.state?.tone, symbol: nil)
        }
    }
}
