// Linux-only substitutes for OS boundaries. No registration workflow is mocked.
import Foundation

enum UNAuthorizationStatus: Sendable { case notDetermined, denied, authorized, provisional, ephemeral }
struct UNAuthorizationOptions: OptionSet, Sendable {
    let rawValue: Int
    static let alert = Self(rawValue: 1)
    static let sound = Self(rawValue: 2)
}
struct UNNotificationSettings { let authorizationStatus: UNAuthorizationStatus }
struct UNNotificationContent { let userInfo: [AnyHashable: Any] }
struct UNNotificationRequest { let identifier: String; let content: UNNotificationContent }
struct UNNotification { let request: UNNotificationRequest }

@MainActor final class UNUserNotificationCenter {
    private static let instance = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { instance }
    var status = UNAuthorizationStatus.authorized
    var granted = true
    var grantStatus: UNAuthorizationStatus?
    var holdEverySettings = false
    private(set) var queuedSettings: [(UNAuthorizationStatus, CheckedContinuation<UNNotificationSettings, Never>)?] = []
    private(set) var returnedSettings: Set<Int> = []
    var holdRequests = false
    private(set) var requests: [CheckedContinuation<Bool, Error>?] = []
    func releaseRequest(_ index: Int, error: Bool = false) {
        guard let continuation = requests[index] else { return }
        requests[index] = nil
        if error {
            continuation.resume(throwing: NSError(domain: "NotificationFixture", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "synthetic authorization failure"]))
        } else { continuation.resume(returning: granted) }
    }
    func releaseQueuedSettings(_ index: Int) {
        guard let entry = queuedSettings[index] else { return }
        queuedSettings[index] = nil
        entry.1.resume(returning: .init(authorizationStatus: entry.0))
    }
    func releaseAll() {
        releaseSettings()
        for index in queuedSettings.indices { releaseQueuedSettings(index) }
        for index in requests.indices { releaseRequest(index, error: true) }
    }
    var holdNextSettings = false
    private var settings: CheckedContinuation<UNNotificationSettings, Never>?
    private var snapshot: UNAuthorizationStatus?
    private(set) var settingsCalls = 0
    var holdingSettings: Bool { settings != nil }
    func releaseSettings() {
        if let snapshot { settings?.resume(returning: .init(authorizationStatus: snapshot)) }
        settings = nil; snapshot = nil
    }
    func notificationSettings() async -> UNNotificationSettings {
        settingsCalls += 1
        let value = status
        if holdEverySettings {
            let index = queuedSettings.count
            let result = await withCheckedContinuation { queuedSettings.append((value, $0)) }
            returnedSettings.insert(index)
            return result
        }
        if holdNextSettings {
            holdNextSettings = false; snapshot = value
            return await withCheckedContinuation { settings = $0 }
        }
        return .init(authorizationStatus: value)
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        if holdRequests { return try await withCheckedThrowingContinuation { requests.append($0) } }
        if let grantStatus { status = grantStatus; self.grantStatus = nil }
        return granted
    }
    func getDeliveredNotifications(_ completion: ([UNNotification]) -> Void) { completion([]) }
    func getPendingNotificationRequests(_ completion: ([UNNotificationRequest]) -> Void) { completion([]) }
    func removeDeliveredNotifications(withIdentifiers: [String]) {}
    func removePendingNotificationRequests(withIdentifiers: [String]) {}
}

@MainActor final class UIApplication {
    static let shared = UIApplication()
    private(set) var registrations = 0
    func registerForRemoteNotifications() { registrations += 1 }
}

@MainActor enum NotificationTestPlatform {
    static let defaults = MemoryDefaults()
    static let bundle = TestBundle()
    static var preparationBegan = false
    final class MemoryDefaults {
        private var values: [String: Any] = [:]
        func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }
    struct TestBundle {
        let bundleIdentifier: String? = "dev.argo.fixture"
        func object(forInfoDictionaryKey key: String) -> Any? {
            key == "ArgoAPNSEnvironment" ? "sandbox" : nil
        }
    }
}
