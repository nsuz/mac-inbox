import AppKit
import Observation
import OSLog
import UserNotifications

final class Announcer: NSObject {
    private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "announcer")

    private let center = UNUserNotificationCenter.current()
    private let inbox: Inbox
    private let account: Account

    init(inbox: Inbox, account: Account) {
        self.inbox = inbox
        self.account = account
    }

    func register() {
        center.delegate = self
        center.setNotificationCategories([Announcement.category()])
    }

    // Described first, so that a banner can tell what happened; a thread whose activity could not
    // be described is still announced, with its reason alone. Each is announced only while it is
    // still unread, since it can be read while it is being described or added.
    func announce(_ news: [GitHub.Notification]) async {
        let news = news.filter { !UserDefaults.standard.mutes(reason: $0.reason) }
        guard let login = account.login, !news.isEmpty else { return }
        await inbox.describe(news)
        for notification in news where inbox.isUnread(notification) {
            Self.log.info("Announcing a thread")
            do {
                try await center.add(Announcement.request(for: notification, activity: inbox.activity(describing: notification), login: login, sound: UserDefaults.standard.notificationSound))
            } catch {
                Self.log.error("Couldn’t announce a thread: \(error, privacy: .public)")
            }
            // Read while it was being added, the withdrawal that the read set off may have looked
            // before the notification was there.
            if !inbox.isUnread(notification) {
                center.removePendingNotificationRequests(withIdentifiers: [notification.id])
                center.removeDeliveredNotifications(withIdentifiers: [notification.id])
            }
        }
    }

    func withdrawWhatIsNoLongerUnread() async {
        for await _ in Observations({ [inbox] in inbox.notifications.map(\.id) }) {
            guard let login = account.login else { continue }
            let delivered = await center.deliveredNotifications().map(\.request)
            let pending = await center.pendingNotificationRequests()
            // Recomputed from the inbox as it is after the awaits, not as it was when the change arrived.
            let stale = inbox.staleDeliveries(
                (delivered + pending).map { .init(threadID: $0.identifier, login: Announcement(userInfo: $0.content.userInfo)?.login) },
                for: login
            )
            guard !stale.isEmpty else { continue }
            Self.log.info("Withdrawing \(stale.count, privacy: .public) threads")
            center.removePendingNotificationRequests(withIdentifiers: stale)
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    // A thread of another account opens GitHub's inbox, where whoever is signed in there can
    // deal with it: the token Inbox holds can neither find it nor mark it as read.
    private func respond(_ reply: Announcement.Reply, login: String?, thread: Data?, event: String?) async {
        guard let announcement = Announcement(login: login, thread: thread, event: event) else {
            NSWorkspace.shared.open(GitHub.inbox)
            return
        }
        do {
            guard try await account.resolve() == announcement.login else {
                NSWorkspace.shared.open(GitHub.inbox)
                return
            }
            switch reply {
            case .open: await inbox.open(announcement.notification, at: announcement.event)
            case .markAsRead: await inbox.markAsRead(announcement.notification)
            }
        } catch {
            switch reply {
            case .open: inbox.reportFailure(error, opening: announcement.notification)
            case .markAsRead: inbox.reportFailure(error, markingAsRead: announcement.notification)
            }
        }
    }
}

extension Announcer: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await NSApp.isActive ? [] : [.banner, .list, .sound]
    }

    // The account is resolved before the response is handled: a click that launches the app
    // arrives before gh has answered, and an unknown account must not count as another one.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let reply = Announcement.Reply(actionIdentifier: response.actionIdentifier) else { return }
        let userInfo = response.notification.request.content.userInfo
        await respond(reply, login: userInfo["login"] as? String, thread: userInfo["thread"] as? Data, event: userInfo["event"] as? String)
    }
}
