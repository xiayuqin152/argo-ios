// Linux-only protocol harness. All values and credentials are synthetic.
import ArgoMobileKit
import Foundation

@MainActor final class AppModel {
    typealias ConnectionFactory = @Sendable (LoomHost, GatewayCredential) throws -> ArgoConnection
    var hosts: [LoomHost] = []
    var loadingHosts = true
    var hostProblem: String?
    var newSessionShown = false
    var openedRoute: ArgoPushRoute?
    func openNotification(_ route: ArgoPushRoute) { openedRoute = route }
}

enum L10n {
    static func text(_ text: String) -> String { text }
    static func error(_ error: Error) -> String { error.localizedDescription }
}

@MainActor enum UserDefaults {
    static let domain = "dev.argo.notification-harness." + UUID().uuidString
    static let standard = Foundation.UserDefaults(suiteName: domain)!
}

@MainActor final class HarnessBinding { var wrappedValue = false }
@MainActor final class HarnessPresentation { func requestDismissal() {} }

enum Bundle {
    static let main = HarnessBundle()
    struct HarnessBundle {
        var bundleIdentifier: String? { "dev.argo.harness" }
        func object(forInfoDictionaryKey key: String) -> Any? {
            key == "ArgoAPNSEnvironment" ? "sandbox" : nil
        }
    }
}

enum UNAuthorizationStatus: Sendable { case notDetermined, denied, authorized, provisional, ephemeral }
struct UNAuthorizationOptions: OptionSet, Sendable {
    let rawValue: Int
    static let alert = Self(rawValue: 1)
    static let sound = Self(rawValue: 2)
}
struct UNNotificationSettings: Sendable { let authorizationStatus: UNAuthorizationStatus }
struct UNNotificationContent: @unchecked Sendable { let userInfo: [AnyHashable: Any] }
struct UNNotificationRequest: Sendable { let identifier: String; let content: UNNotificationContent }
struct UNNotification: Sendable { let request: UNNotificationRequest }

@MainActor final class UIApplication {
    static let shared = UIApplication()
    private(set) var registrationCalls = 0
    func registerForRemoteNotifications() { registrationCalls += 1 }
}

@MainActor final class UNUserNotificationCenter {
    static let shared = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { shared }
    var authorization: UNAuthorizationStatus = .authorized
    var deferCleanup = false
    var snapshotAtCompletion = false
    private(set) var completedRemovalBatches = 0
    var delivered: [UNNotification] = []
    var pending: [UNNotificationRequest] = []
    private var deliveredCallbacks: [@Sendable ([UNNotification]) -> Void] = []
    private var pendingCallbacks: [@Sendable ([UNNotificationRequest]) -> Void] = []

    func notificationSettings() async -> UNNotificationSettings { .init(authorizationStatus: authorization) }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { authorization == .authorized }
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        if deferCleanup {
            if snapshotAtCompletion { deliveredCallbacks.append(completionHandler) }
            else {
                let snapshot = delivered
                deliveredCallbacks.append { _ in completionHandler(snapshot) }
            }
        }
        else { completionHandler(delivered) }
    }
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
        if deferCleanup {
            if snapshotAtCompletion { pendingCallbacks.append(completionHandler) }
            else {
                let snapshot = pending
                pendingCallbacks.append { _ in completionHandler(snapshot) }
            }
        }
        else { completionHandler(pending) }
    }
    // Apple's center is usable from any queue. The harness calls these on MainActor.
    nonisolated func removeDeliveredNotifications(withIdentifiers ids: [String]) {
        MainActor.assumeIsolated {
            delivered.removeAll { ids.contains($0.request.identifier) }
            completedRemovalBatches += 1
        }
    }
    nonisolated func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        MainActor.assumeIsolated {
            pending.removeAll { ids.contains($0.identifier) }
            completedRemovalBatches += 1
        }
    }
    @discardableResult func finishCleanup() -> Int {
        let deliveredWork = deliveredCallbacks; deliveredCallbacks = []
        let pendingWork = pendingCallbacks; pendingCallbacks = []
        let expected = completedRemovalBatches + deliveredWork.count + pendingWork.count
        for callback in deliveredWork { callback(delivered) }
        for callback in pendingWork { callback(pending) }
        return expected
    }
}

final class NotificationTransport: ArgoHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var currentToken: String?
    private var nextRegistration = 0
    private var requests: [String] = []
    private var offline = false
    let host: LoomHost
    let onReceipt: @Sendable (ArgoPushRegistration) async -> Void
    init(host: LoomHost, onReceipt: @escaping @Sendable (ArgoPushRegistration) async -> Void) {
        self.host = host; self.onReceipt = onReceipt
    }
    func setOffline(_ value: Bool) { lock.lock(); defer { lock.unlock() }; offline = value }
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    func loomdToken() async throws -> String { String(repeating: "a", count: 64) }
    func close() async {}
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        let response = try respond(request)
        if request.method == "PUT" {
            // The backend has installed this registration and may deliver an
            // alert before the PUT response reaches the phone.
            await onReceipt(try JSONDecoder().decode(ArgoPushRegistration.self, from: response.body))
        }
        return response
    }
    private func respond(_ request: HTTPRequest) throws -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        precondition(request.target == "/api/notify/device")
        precondition(request.method == "PUT" || request.method == "DELETE")
        requests.append(request.method)
        if offline { throw TransportFailure.noReply("synthetic offline host") }
        let body: Data
        if request.method == "DELETE" {
            currentToken = nil
            body = Data(#"{"enabled":false}"#.utf8)
        } else {
            let input = try JSONSerialization.jsonObject(with: request.body!) as! [String: String]
            if currentToken != input["token"] { nextRegistration += 1; currentToken = input["token"] }
            body = try JSONEncoder().encode(ArgoPushRegistration(enabled: true, hostID: host.id,
                deviceID: host.deviceID, registrationID: "registration\(nextRegistration)"))
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body, reusable: false)
    }
}
