import Foundation
import UserNotifications

struct Announcement {
    let login: String
    let notification: GitHub.Notification

    static let category = UNNotificationCategory(
        identifier: "thread",
        actions: [],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "New activity"
    )

    static func request(for notification: GitHub.Notification, login: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.subject.title
        content.subtitle = notification.repository.fullName
        content.body = GitHub.Notification.describe(reason: notification.reason)
        content.threadIdentifier = notification.repository.fullName
        content.categoryIdentifier = category.identifier
        content.sound = .default
        content.userInfo = ["login": login, "thread": (try? GitHub.encoder.encode(notification)) ?? Data()]
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
    }

    init?(userInfo: [AnyHashable: Any]) {
        self.init(login: userInfo["login"] as? String, thread: userInfo["thread"] as? Data)
    }

    init?(login: String?, thread: Data?) {
        guard let login, let thread,
              let notification = try? GitHub.decoder.decode(GitHub.Notification.self, from: thread)
        else { return nil }
        self.login = login
        self.notification = notification
    }
}
