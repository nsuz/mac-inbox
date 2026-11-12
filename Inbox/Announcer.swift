import AppKit
import Observation
import OSLog
import UserNotifications

final class Announcer: NSObject {
    private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "announcer")

    private let center = UNUserNotificationCenter.current()
    private let inbox: Inbox
    private let account: Account
    private let showInbox: () -> Void

    init(inbox: Inbox, account: Account, showInbox: @escaping () -> Void) {
        self.inbox = inbox
        self.account = account
        self.showInbox = showInbox
    }

    func register() {
        center.delegate = self
        center.setNotificationCategories([Announcement.category])
    }

    func announce(_ news: [GitHub.Notification]) {
        guard let login = account.login, !news.isEmpty else { return }
        Self.log.info("Announcing \(news.count, privacy: .public) threads")
        for notification in news {
            center.add(Announcement.request(for: notification, login: login))
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

    private func respond(login: String?, thread: Data?) async {
        guard let announcement = Announcement(login: login, thread: thread) else {
            NSWorkspace.shared.open(GitHub.inbox)
            return
        }
        do {
            guard try await account.resolve() == announcement.login else {
                NSWorkspace.shared.open(GitHub.inbox)
                return
            }
            await inbox.open(announcement.notification)
        } catch {
            inbox.reportFailure(error, opening: announcement.notification)
        }
        if inbox.failedAction != nil {
            showInbox()
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        await respond(login: userInfo["login"] as? String, thread: userInfo["thread"] as? Data)
    }
}
