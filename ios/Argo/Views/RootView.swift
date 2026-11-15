// Navigation adapted from nwverse/persona apple/Persona/Views/SplitNavigation.swift and Views/Chats/ChatsView.swift @ 3002eb3 (MIT).
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hostsPresentation = SeenPresentation()
    @State private var pairingPresentation = SeenPresentation()
    @State private var hostPairingShown = false
    @State private var pairingSizeClass: UserInterfaceSizeClass?
    @State private var settingsPresentation = SeenPresentation()
    private var notifications: PhoneNotifications { .shared }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.loadingHosts {
                ProgressView("Loading hosts…")
            } else if let problem = model.hostProblem {
                ContentUnavailableView {
                    Label("Couldn't read hosts", systemImage: Theme.Icon.warning)
                } description: { Text(verbatim: problem) } actions: {
                    Button("Try Again") { Task { await model.loadHosts() } }
                }
            } else if model.hosts.isEmpty {
                welcome
            } else {
                if compactHosts {
                    PersonaDrawerLayout(isPresented: hostsBinding, enabled: model.selectedKey == nil,
                                        onCover: { hostsPresentation.cover(in: model) }) {
                        HostWorkspaceView(close: { hostsBinding.wrappedValue = false }, pairingShown: $hostPairingShown,
                                          pairingDismissed: { pairingSizeClass = nil })
                    } page: {
                        navigation
                    }
                } else {
                    navigation.sheet(isPresented: hostsBinding, onDismiss: { hostsPresentation.didDismiss(in: model) }) {
                        HostWorkspaceView(pairingShown: $hostPairingShown, pairingDismissed: { pairingSizeClass = nil })
                    }
                }
            }
        }
        .background(Theme.pageBackground)
        .environment(\.readingTypeSize, systemTypeSize)
        .dynamicTypeSize(Theme.interfaceTypeSize(systemTypeSize))
        .sheet(isPresented: pairingPresentation.binding(in: model),
               onDismiss: { pairingPresentation.didDismiss(in: model) }) { PairingView() }
        .sheet(isPresented: $model.newSessionShown,
               onDismiss: { model.newSessionPresentation.didDismiss(in: model) }) { NewChatView() }
        .sheet(isPresented: settingsPresentation.binding(in: model),
               onDismiss: { settingsPresentation.didDismiss(in: model) }) { SettingsView() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = model.notificationProblem {
                NoticeBanner(text: problem, tone: .caution, lineLimit: nil) {
                    Button("Close") { model.notificationProblem = nil }
                }
                .padding(Theme.Space.l)
            }
        }
        .task { await model.loadHosts() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase == .active)
            if phase == .active { Task { await notifications.refresh() } }
        }
        .onChange(of: model.hosts) { _, hosts in
            notifications.hostsChanged(hosts)
            openNotification()
        }
        .onChange(of: model.loadingHosts) { _, loading in if !loading { openNotification() } }
        .onChange(of: notifications.pendingRoute) { _, _ in openNotification() }
        .onChange(of: hostPairingShown) { _, shown in
            if shown { pairingSizeClass = horizontalSizeClass }
        }
    }

    private func openNotification() {
        guard !model.loadingHosts, let route = notifications.takeRoute(hosts: model.hosts) else { return }
        hostsBinding.wrappedValue = false
        pairingPresentation.requestDismissal()
        settingsPresentation.requestDismissal()
        hostPairingShown = false
        model.newSessionShown = false
        model.openNotification(route)
    }

    private var compactHosts: Bool {
        // Do not replace the presenting container while its pairing editor is open.
        (pairingSizeClass ?? horizontalSizeClass) == .compact
    }

    private var hostsBinding: Binding<Bool> {
        Binding(get: { hostsPresentation.isPresented }, set: { shown in
            if !shown, compactHosts {
                let owner = hostsPresentation.owner
                withAnimation(reduceMotion ? nil : Theme.Motion.drawer, completionCriteria: .removed) {
                    hostsPresentation.setPresented(false, in: model)
                } completion: {
                    if !hostsPresentation.isPresented { hostsPresentation.didDismiss(owner, in: model) }
                }
            } else { hostsPresentation.setPresented(shown, in: model) }
        })
    }

    private var navigation: some View {
        NavigationSplitView {
            ChatsView(openHosts: { hostsBinding.wrappedValue = true },
                      openSettings: { settingsPresentation.setPresented(true, in: model) })
                .navigationSplitViewColumnWidth(min: Theme.Size.sidebarMin,
                                                ideal: Theme.Size.sidebar, max: Theme.Size.sidebarMax)
        } detail: {
            if let state = model.conversation {
                ChatView(state: state).id(state.key)
            } else {
                ContentUnavailableView("Select an Agent", systemImage: Theme.Icon.terminal,
                                       description: Text("Conversations and tool progress appear here."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionBanner(pair: { pairingPresentation.setPresented(true, in: model) })
        }
    }

    private var welcome: some View {
        VStack(spacing: Theme.Space.xl) {
            Image("ArgoMark")
                .resizable().scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(.rect(cornerRadius: Theme.Radius.bubble))
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.s) {
                Text("Argo").font(Theme.Font.display)
                Text("Your agents, wherever you are.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button { pairingPresentation.setPresented(true, in: model) } label: {
                Label("Connect a Host", systemImage: Theme.Icon.add)
                    .padding(.horizontal, Theme.Space.l)
                    .tapTargetHeight()
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("connect-host")
            Button { settingsPresentation.setPresented(true, in: model) } label: {
                Label("Settings", systemImage: "gearshape").tapTargetHeight()
            }
            .accessibilityIdentifier("open-settings")
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: Theme.Size.readable)
    }
}

private struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model
    let pair: () -> Void

    var body: some View {
        if !model.status.isConnected {
            HStack(spacing: Theme.Space.s) {
                if model.status == .connecting { ProgressView().controlSize(.small) }
                else { ThemedIcon(Theme.Icon.connection).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Font.captionStrong)
                    if let problem = model.status.problem {
                        Text(verbatim: problem).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.status.needsPairing {
                    Button("Pair Again", action: pair).tapTargetHeight()
                } else if model.status != .connecting && model.status != .suspended {
                    Button("Retry") { model.reconnect() }.tapTargetHeight()
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.xs)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("connection-status")
        }
    }

    private var title: String {
        switch model.status {
        case .connecting: L10n.text("Connecting…")
        case .suspended: L10n.text("Connection paused")
        case .failed: L10n.text("Disconnected")
        default: L10n.text("Not connected")
        }
    }
}
