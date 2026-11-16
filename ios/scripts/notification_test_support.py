"""Link the real notification model with the existing inert Linux OS adapters."""


def notification_sources(read_source, save_source):
    phone = read_source("ios/Argo/Notifications/PhoneNotifications.swift")
    phone = phone.replace("import UIKit\n", "").replace("import UserNotifications\n", "")
    phone = phone.replace("UserDefaults.standard", "NotificationTestPlatform.defaults")
    phone = phone.replace("Bundle.main", "NotificationTestPlatform.bundle")
    return [
        save_source("PhoneNotifications.swift", phone),
        save_source("NotificationPlatform.swift", read_source("research/repair-notifications/NotificationPlatform.swift")),
    ]


def write_notification_sources(output, read_source):
    output.mkdir(parents=True, exist_ok=True)

    def save(name, source):
        path = output / name
        path.write_text(source)
        return path

    return notification_sources(read_source, save)
