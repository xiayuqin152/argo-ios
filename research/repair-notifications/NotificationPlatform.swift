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
    func notificationSettings() async -> UNNotificationSettings { .init(authorizationStatus: .authorized) }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func getDeliveredNotifications(_ completion: ([UNNotification]) -> Void) { completion([]) }
    func getPendingNotificationRequests(_ completion: ([UNNotificationRequest]) -> Void) { completion([]) }
    func removeDeliveredNotifications(withIdentifiers: [String]) {}
    func removePendingNotificationRequests(withIdentifiers: [String]) {}
}

@MainActor final class UIApplication {
    static let shared = UIApplication()
    func registerForRemoteNotifications() {}
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
