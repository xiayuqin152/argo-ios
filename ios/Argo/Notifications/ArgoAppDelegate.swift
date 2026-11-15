import ArgoMobileKit
import UIKit
import UserNotifications

@MainActor
final class ArgoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PhoneNotifications.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PhoneNotifications.shared.didFailRegistration()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = ArgoPushRoute.decode(response.notification.request.content.userInfo) else { return }
        await MainActor.run { PhoneNotifications.shared.receive(route) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let route = ArgoPushRoute.decode(notification.request.content.userInfo) else { return [] }
        return await MainActor.run { PhoneNotifications.shared.trusted(route) ? [.banner, .sound] : [] }
    }
}
