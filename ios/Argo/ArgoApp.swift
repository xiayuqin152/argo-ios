import ArgoMobileKit
import BeautifulUI
import SwiftUI

@main
struct ArgoApp: App {
    @UIApplicationDelegateAdaptor(ArgoAppDelegate.self) private var appDelegate
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup { ArgoBootstrap().preferredColorScheme(appearance.colorScheme) }
    }
}

private struct ArgoBootstrap: View {
    @State private var model: AppModel?
    @State private var problem: String?

    var body: some View {
        Group {
            if let model {
                RootView().environment(model)
            } else if let problem {
                ContentUnavailableView {
                    Label("Argo couldn't open", systemImage: Theme.Icon.warning)
                } description: {
                    Text(verbatim: problem)
                } actions: {
                    Button("Try Again", action: open)
                }
            } else {
                ProgressView("Opening Argo…")
            }
        }
        .tint(Theme.accent)
        .buiTheme(Theme.beautifulUI)
        .task { if model == nil { open() } }
    }

    private func open() {
        do {
            let store = ArgoHostStore(fileURL: try ArgoHostStore.defaultFileURL(), tokens: KeychainDeviceTokens())
            model = AppModel(store: store, announce: { text in
                AccessibilityNotification.Announcement(text).post()
            }) { host, credential in
                try ArgoConnection(host: host, credential: credential)
            }
            PhoneNotifications.shared.attach(store: store) { host, credential in
                try ArgoConnection(host: host, credential: credential)
            }
            model?.unregisterNotifications = { id in try await PhoneNotifications.shared.forgetHost(id) }
            model?.prepareNotificationsForPairing = { id in try await PhoneNotifications.shared.prepareForPairing(id) }
            model?.restoreNotificationsAfterPairing = { id in await PhoneNotifications.shared.restoreAfterPairing(id) }
            problem = nil
        } catch { problem = L10n.error(error) }
    }
}
