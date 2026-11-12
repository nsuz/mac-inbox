import AppKit
import Observation
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    let account = Account()
    let poller = Poller()
    private(set) lazy var inbox = Inbox(client: GitHub.Client(token: { [account] in try await account.token() }))
    private var tasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted by this app; a test run must not poll the real account.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Not awaited before polling: the inbox should fill in while the permission prompt is still open.
        tasks.append(Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        })
        tasks.append(Task { [inbox, poller] in
            await poller.run { try await inbox.refresh().pollInterval }
        })
        tasks.append(Task { [inbox] in
            for await unread in Observations({ inbox.notifications.count }) {
                try? await UNUserNotificationCenter.current().setBadgeCount(unread)
            }
        })
    }

    // The window is only a view onto the inbox; polling and notifications continue without it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
