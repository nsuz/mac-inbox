import Foundation
import UserNotifications

struct Announcement {
    let login: String
    let notification: GitHub.Notification
    // The event the banner told of, if any.
    let event: URL?

    static let category = UNNotificationCategory(
        identifier: "thread",
        actions: [],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "New activity"
    )

    // The event is carried in the notification, since by the time it is clicked the description
    // that told of it may be gone or replaced by one of newer activity.
    static func request(for notification: GitHub.Notification, activity: GitHub.Activity?, login: String) -> UNNotificationRequest {
        let event = activity?.unreadEvent(lastReadAt: notification.lastReadAt)
        let content = UNMutableNotificationContent()
        content.title = notification.subject.title
        content.subtitle = "\(notification.repository.fullName) · \(GitHub.Notification.describe(reason: notification.reason, type: notification.subject.type))"
        content.body = event.map(news) ?? ""
        content.threadIdentifier = notification.repository.fullName
        content.categoryIdentifier = category.identifier
        content.sound = .default
        content.userInfo = ["login": login, "thread": (try? GitHub.encoder.encode(notification)) ?? Data()]
        if let url = event?.url {
            content.userInfo["event"] = url.absoluteString
        }
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
    }

    // What someone wrote, in their own words as a message notification gives them; otherwise what
    // they did. The reason is only why the thread is in the inbox.
    private static func news(_ event: GitHub.Event) -> String {
        let excerpt = event.excerpt
        return excerpt.isEmpty ? event.phrase : "\(event.actorName): \(excerpt)"
    }

    init?(userInfo: [AnyHashable: Any]) {
        self.init(login: userInfo["login"] as? String, thread: userInfo["thread"] as? Data, event: userInfo["event"] as? String)
    }

    init?(login: String?, thread: Data?, event: String?) {
        guard let login, let thread,
              let notification = try? GitHub.decoder.decode(GitHub.Notification.self, from: thread)
        else { return nil }
        self.login = login
        self.notification = notification
        self.event = event.flatMap(URL.init(string:))
    }
}

extension GitHub.Event {
    // One line, as a preview shows it: without the lines quoted from earlier comments and the
    // hidden notes that bots leave, both of which GitHub keeps in the plain text.
    var excerpt: String {
        (text ?? "")
            .replacing(/<!--[\s\S]*?-->/, with: "")
            .split(whereSeparator: \.isNewline)
            .filter { !$0.drop(while: \.isWhitespace).hasPrefix(">") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
