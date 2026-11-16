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
        if holdNextSettings {
            holdNextSettings = false; snapshot = value
            return await withCheckedContinuation { settings = $0 }
        }
        return .init(authorizationStatus: value)
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { granted }
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
