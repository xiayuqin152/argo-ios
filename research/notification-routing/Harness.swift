import ArgoMobileKit
import Foundation

@main enum Harness {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: UserDefaults.domain) }
        let fingerprint = Base64URL.encode(Data(repeating: 9, count: 32))
        let code = "argo1:192.0.2.10:25930:\(fingerprint):\(Base64URL.encode(Data(repeating: 7, count: 16)))"
        let store = ArgoHostStore(fileURL: directory.appendingPathComponent("hosts.json"), tokens: InMemoryDeviceTokens()) { _, _ in
            GatewayCredential(device: "syntheticDevice", token: String(repeating: "b", count: 43))
        }
        let host = try await store.pair(code: code, deviceName: "Synthetic phone")
        let center = UNUserNotificationCenter.current()
        let beforeReceipt = CommandLine.arguments.contains("--cleanup-before-receipt")
        center.snapshotAtCompletion = beforeReceipt || CommandLine.arguments.contains("--snapshot-at-completion")
        let transport = NotificationTransport(host: host) { receipt in
            let cleanupTarget: Int? = await MainActor.run {
                if center.deferCleanup {
                    let request = request(id: "current-" + receipt.registrationID,
                        route: route(host: host, registration: receipt.registrationID))
                    center.pending.append(request)
                    center.delivered.append(.init(request: request))
                    if beforeReceipt { return center.finishCleanup() }
                }
                return nil
            }
            if let cleanupTarget {
                // Wait for those exact removal callbacks, while the transport
                // still owns the PUT response. No product timer is involved.
                await eventually { center.completedRemovalBatches >= cleanupTarget }
                await MainActor.run {
                    precondition(PhoneNotifications.shared.registrations[host.id]?.registrationID != receipt.registrationID,
                                 "PUT receipt must still be unpublished during these assertions")
                    let stage: String
                    switch receipt.registrationID {
                    case "registration2": stage = "token rotation"
                    case "registration3": stage = "re-enable"
                    case "registration4": stage = "permission restoration"
                    default: preconditionFailure("unexpected synthetic registration")
                    }
                    let identifier = "current-" + receipt.registrationID
                    check(center.delivered.contains { $0.request.identifier == identifier },
                          "pre-receipt \(stage) preserves delivered notification")
                    check(center.pending.contains { $0.identifier == identifier },
                          "pre-receipt \(stage) preserves pending notification")
                }
            }
        }
        // Seed only non-secret registration state, as persisted by the previous
        // app launch. The delegate can receive a tap before attach/hostsChanged.
        UserDefaults.standard.set([host.id.uuidString], forKey: "argo.push.enabledHosts.v1")
        let previous = ArgoPushRegistration(enabled: true, hostID: host.id,
            deviceID: host.deviceID, registrationID: "registration1")
        UserDefaults.standard.set(try JSONEncoder().encode([host.id: previous]), forKey: "argo.push.registrations.v1")
        let notifications = PhoneNotifications.shared
        let original = route(host: host, registration: "registration1")
        notifications.receive(original)
        check(notifications.pendingRoute == original, "persisted cold-launch tap survives before store attachment")
        check(!notifications.trusted(original), "foreground presentation waits for the paired host directory")
        notifications.attach(store: store) { paired, _ in ArgoConnection(host: paired, transport: transport) }
        notifications.hostsChanged([host])
        await notifications.setEnabled(true, host: host)
        notifications.didRegister(Data(repeating: 1, count: 32))
        await eventually { notifications.registrations[host.id]?.registrationID == "registration1" }
        await settle()

        check(notifications.takeRoute(hosts: [host]) == original, "cold-launch tap buffered before host handoff")
        check(notifications.trusted(original), "current paired notification can present in the foreground")
        let model = AppModel()
        let root = RootNotificationHarness(model: model)
        notifications.receive(original)
        root.drive()
        check(notifications.pendingRoute == original, "loading host directory preserves a cold-launch tap")
        model.loadingHosts = false
        model.hostProblem = "synthetic temporary host-file read error"
        root.drive()
        check(notifications.pendingRoute == original, "host-file read failure preserves a cold-launch tap")
        model.hostProblem = nil
        model.hosts = [host]
        root.drive()
        check(model.openedRoute == original && notifications.pendingRoute == nil,
              "successful host-file retry opens the original notification exactly once")
        notifications.receive(original)
        check(notifications.takeRoute(hosts: []) == nil, "removed/unpaired host cannot consume a route")
        var repaired = host; repaired.deviceID = "newPairing"
        check(!original.matches(notifications.registrations[host.id]!, hosts: [repaired]), "re-paired device cannot use an old notification")

        let unrelatedHost = LoomHost(name: "Other", address: "192.0.2.11", gatewayPort: 25931,
            fingerprint: fingerprint, deviceID: "otherDevice")
        let unrelated = route(host: unrelatedHost, registration: "otherRegistration")
        populate(center, routes: [("old", original), ("other", unrelated)])
        // Exercise both request-time snapshots and callback-time lists. The
        // new alert can precede both cleanup and the receipt becoming local.
        center.deferCleanup = true
        notifications.didRegister(Data(repeating: 2, count: 32))
        await eventually { notifications.registrations[host.id]?.registrationID == "registration2" }
        notifications.receive(original)
        check(notifications.pendingRoute == nil && !notifications.trusted(original), "rotated registration cannot route or present")
        center.finishCleanup()
        await settle()
        check(Set(center.delivered.map { $0.request.identifier }) == ["current-registration2", "other"], "delayed token cleanup preserves replacement delivered notification")
        check(Set(center.pending.map(\.identifier)) == ["current-registration2", "other"], "delayed token cleanup preserves replacement pending notification")

        // A successful DELETE can also have a delayed cleanup callback while
        // the user enables notifications again with a new registration.
        await notifications.setEnabled(false, host: host)
        check(!notifications.enabledHosts.contains(host.id), "successful DELETE removes enabled intent")
        check(notifications.registrations[host.id] == nil, "successful DELETE removes receipt")
        await notifications.setEnabled(true, host: host)
        await eventually { notifications.registrations[host.id]?.registrationID == "registration3" }
        let reenabled = route(host: host, registration: "registration3")
        center.finishCleanup()
        await settle()
        check(Set(center.delivered.map { $0.request.identifier }) == ["current-registration3", "other"], "delayed DELETE cleanup preserves re-enabled delivered notification")
        check(Set(center.pending.map(\.identifier)) == ["current-registration3", "other"], "delayed DELETE cleanup preserves re-enabled pending notification")

        // Permission denial keeps user intent so Settings restoration can register.
        notifications.receive(reenabled)
        center.authorization = .denied
        await notifications.refresh()
        check(notifications.enabledHosts.contains(host.id), "permission denial retains enabled intent")
        check(notifications.registrations[host.id] == nil, "permission denial unregisters the host")
        check(notifications.pendingRoute == nil, "permission denial clears a pending tap")
        center.authorization = .authorized
        await notifications.refresh()
        check(notifications.registrations[host.id]?.registrationID == "registration4", "permission restoration registers again")
        center.finishCleanup()
        await settle()
        check(Set(center.delivered.map { $0.request.identifier }) == ["current-registration4", "other"], "restored permission preserves current delivered notification")
        check(Set(center.pending.map(\.identifier)) == ["current-registration4", "other"], "restored permission preserves current pending notification")

        transport.setOffline(true)
        do { try await notifications.forgetHost(host.id); check(false, "offline removal must fail") }
        catch { check(notifications.enabledHosts.contains(host.id) && notifications.registrations[host.id] != nil,
                      "offline removal preserves intent and receipt for retry") }
        transport.setOffline(false)
        try await notifications.forgetHost(host.id)
        try await store.remove(host.id)
        notifications.hostsChanged([])
        notifications.receive(route(host: host, registration: "registration4"))
        check(notifications.takeRoute(hosts: []) == nil, "forgotten-host tap is ignored")
        center.finishCleanup()
        await settle()
        check(center.delivered.map { $0.request.identifier } == ["other"] && center.pending.map(\.identifier) == ["other"],
              "successful removal clears this host while retaining other-host notifications")
        check(transport.methods.allSatisfy { $0 == "PUT" || $0 == "DELETE" }, "notification lifecycle never sends a conversation POST")
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: notification protocol harness")
    }

    @MainActor static var failures = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        if value { print("PASS: " + message) }
        else { print("FAIL: " + message); failures += 1 }
    }
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func eventually(_ ready: @MainActor () -> Bool) async {
        for _ in 0..<10000 { if ready() { return }; await Task.yield() }
        preconditionFailure("synthetic lifecycle did not complete")
    }
    static func route(host: LoomHost, registration: String) -> ArgoPushRoute {
        ArgoPushRoute.decode(["argo": ["v": 1, "hostID": host.id.uuidString, "deviceID": host.deviceID,
            "registrationID": registration, "workspace": "syntheticWorkspace", "run": "syntheticRun",
            "event": "agent.done", "eventID": "synthetic-event"]])!
    }
    @MainActor static func populate(_ center: UNUserNotificationCenter, routes: [(String, ArgoPushRoute)]) {
        center.pending = routes.map { request(id: $0.0, route: $0.1) }
        center.delivered = center.pending.map { UNNotification(request: $0) }
    }
    static func request(id: String, route: ArgoPushRoute) -> UNNotificationRequest {
        let info = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as! [String: Any]
        return UNNotificationRequest(identifier: id, content: .init(userInfo: ["argo": info]))
    }
}
