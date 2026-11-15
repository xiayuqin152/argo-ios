// Registration sequencing and foreground permission refresh follow Persona's
// PushRegistrar approach; the only backend here is the user's paired Argo host.
import ArgoMobileKit
import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor @Observable
final class PhoneNotifications {
    static let shared = PhoneNotifications()
    private(set) var enabledHosts: Set<UUID>
    private(set) var registrations: [UUID: ArgoPushRegistration]
    private(set) var pendingRoute: ArgoPushRoute?
    private var hostProblems: [UUID: String] = [:]
    private var authorizationProblem: String?
    private var registrationProblem: String?
    private var synchronizationProblem: String?
    private(set) var busy = false
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var store: ArgoHostStore?
    @ObservationIgnored private var makeConnection: AppModel.ConnectionFactory?
    @ObservationIgnored private var hosts: [LoomHost] = []
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var last: Task<Void, Never>?
    private static let enabledKey = "argo.push.enabledHosts.v1"
    private static let registrationsKey = "argo.push.registrations.v1"

    private init() {
        enabledHosts = Set((UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []).compactMap(UUID.init))
        registrations = UserDefaults.standard.data(forKey: Self.registrationsKey)
            .flatMap { try? JSONDecoder().decode([UUID: ArgoPushRegistration].self, from: $0) } ?? [:]
    }

    func attach(store: ArgoHostStore, makeConnection: @escaping AppModel.ConnectionFactory) {
        self.store = store; self.makeConnection = makeConnection
    }

    func hostsChanged(_ value: [LoomHost]) {
        hosts = value
        Task { await refresh() }
    }

    func problem(for host: UUID?) -> String? {
        let messages = [authorizationProblem, registrationProblem, synchronizationProblem,
                        host.flatMap { hostProblems[$0] }].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if Self.allowed(authorization) { authorizationProblem = nil }
        else if authorization == .denied, !enabledHosts.isEmpty {
            authorizationProblem = L10n.text("Allow notifications in iOS Settings to receive Agent alerts.")
        }
        guard !enabledHosts.isEmpty else { return }
        if Self.allowed(authorization) { UIApplication.shared.registerForRemoteNotifications() }
        do {
            try await sequence { [self] in
                if Self.allowed(authorization) { try await synchronize() }
                else { await unregisterEnabled(keepIntent: true) }
            }
        } catch { synchronizationProblem = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool, host: LoomHost) async {
        busy = true; defer { busy = false }
        do {
            if enabled {
                let granted: Bool
                do { granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                catch { authorizationProblem = error.localizedDescription; return }
                authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                guard granted else {
                    authorizationProblem = L10n.text("Allow notifications in iOS Settings to receive Agent alerts.")
                    return
                }
                authorizationProblem = nil
                // Persist intent before PUT: even a lost receipt must later be unregistered.
                enabledHosts.insert(host.id); save()
                UIApplication.shared.registerForRemoteNotifications()
                try await sequence { [self] in try await synchronize() }
            } else {
                try await sequence { [self] in try await unregister(host, keepIntent: false) }
            }
        } catch {
            if enabled { synchronizationProblem = error.localizedDescription }
            else { hostProblems[host.id] = host.displayName + ": " + error.localizedDescription }
        }
    }

    /// Called before deleting the host credential. An offline failure keeps the
    /// credential and intent available so the user can retry the same DELETE.
    func forgetHost(_ id: UUID) async throws {
        do {
            try await sequence { [self] in
                guard enabledHosts.contains(id) || registrations[id] != nil else { return }
                guard let host = hosts.first(where: { $0.id == id }) else {
                    throw ArgoClientError.refusedLocally(.message("Select the paired host and retry notification removal."))
                }
                try await unregister(host, keepIntent: false)
            }
        } catch { hostProblems[id] = error.localizedDescription; throw error }
    }

    func didRegister(_ data: Data) {
        let next = data.map { String(format: "%02x", $0) }.joined()
        guard !next.isEmpty else { return }
        if let token, token != next {
            for id in enabledHosts { clearNotifications(host: id) }
            registrations.removeAll(); save()
        }
        token = next
        registrationProblem = nil
        Task {
            do { try await sequence { [self] in try await synchronize() } }
            catch { synchronizationProblem = error.localizedDescription }
        }
    }

    func didFailRegistration() { registrationProblem = L10n.text("Apple could not register this signed app for notifications. Retry when connected.") }

    func receive(_ route: ArgoPushRoute) {
        guard let receipt = registrations[route.hostID], enabledHosts.contains(route.hostID),
              receipt.deviceID == route.deviceID, receipt.registrationID == route.registrationID else { return }
        pendingRoute = route
    }

    func takeRoute(hosts: [LoomHost]) -> ArgoPushRoute? {
        guard let route = pendingRoute else { return nil }
        pendingRoute = nil
        guard let receipt = registrations[route.hostID], enabledHosts.contains(route.hostID), route.matches(receipt, hosts: hosts) else { return nil }
        return route
    }

    func trusted(_ route: ArgoPushRoute) -> Bool {
        guard let receipt = registrations[route.hostID], enabledHosts.contains(route.hostID) else { return false }
        return route.matches(receipt, hosts: hosts)
    }

    private func synchronize() async throws {
        guard Self.allowed(authorization), let token, let store, let makeConnection else { return }
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "ArgoAPNSEnvironment") as? String,
              ["sandbox", "production"].contains(environment), let topic = Bundle.main.bundleIdentifier else {
            throw ArgoClientError.refusedLocally(.message("The signed app needs an explicit APNs environment and bundle topic."))
        }
        let currentHosts = try await store.hosts()
        synchronizationProblem = nil
        for host in currentHosts where enabledHosts.contains(host.id) {
            do {
                let credential = try await store.credential(for: host)
                let client = try makeConnection(host, credential)
                let receipt: ArgoPushRegistration
                do { receipt = try await client.registerNotifications(token: token, environment: environment, topic: topic, credential: credential) }
                catch { await client.close(); throw error }
                await client.close()
                guard token == self.token, enabledHosts.contains(host.id) else { continue }
                if registrations[host.id] != receipt { clearNotifications(host: host.id) }
                registrations[host.id] = receipt; save()
                hostProblems.removeValue(forKey: host.id)
            } catch { hostProblems[host.id] = host.displayName + ": " + error.localizedDescription }
        }
    }

    private func unregisterEnabled(keepIntent: Bool) async {
        for host in hosts where enabledHosts.contains(host.id) || registrations[host.id] != nil {
            do { try await unregister(host, keepIntent: keepIntent) }
            catch { hostProblems[host.id] = host.displayName + ": " + error.localizedDescription }
        }
    }

    private func unregister(_ host: LoomHost, keepIntent: Bool) async throws {
        guard let store, let makeConnection else { throw ArgoClientError.closed }
        let credential = try await store.credential(for: host)
        let client = try makeConnection(host, credential)
        do { try await client.unregisterNotifications(credential: credential) }
        catch { await client.close(); throw error }
        await client.close()
        registrations.removeValue(forKey: host.id)
        if !keepIntent { enabledHosts.remove(host.id) }
        if pendingRoute?.hostID == host.id { pendingRoute = nil }
        clearNotifications(host: host.id); save()
        hostProblems.removeValue(forKey: host.id)
    }

    private func sequence(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = last
        let task = Task { await previous?.value; try await work() }
        last = Task { _ = try? await task.value }
        try await task.value
    }

    private func save() {
        UserDefaults.standard.set(enabledHosts.map(\.uuidString), forKey: Self.enabledKey)
        if let data = try? JSONEncoder().encode(registrations) { UserDefaults.standard.set(data, forKey: Self.registrationsKey) }
    }

    private func clearNotifications(host: UUID) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
                ArgoPushRoute.decode($0.request.content.userInfo)?.hostID == host
            }.map { $0.request.identifier })
        }
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                ArgoPushRoute.decode($0.content.userInfo)?.hostID == host
            }.map(\.identifier))
        }
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }
}
