import AppKit
import Combine
import Observation
import OSLog
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "badge")

    let account = Account()
    let poller = Poller()
    private(set) lazy var inbox = Inbox(client: GitHub.Client(token: { [account] in try await account.token() }))
    private lazy var announcer = Announcer(inbox: inbox, account: account) { [weak self] in self?.showInbox() }
    var openWindow: OpenWindowAction?
    private var tasks: [Task<Void, Never>] = []
    private var dockRelaunches: AnyCancellable?

    // Unit tests are hosted by this app; a test run must not poll the real account or post notifications.
    private let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isHostingTests else { return }
        announcer.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isHostingTests else { return }

        // Not awaited before polling: the inbox should fill in while the permission prompt is still open.
        tasks.append(Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        })
        tasks.append(Task { [inbox, poller, announcer] in
            await poller.run {
                let refresh = try await inbox.refresh()
                announcer.announce(refresh.news)
                return refresh.pollInterval
            }
        })
        tasks.append(Task { [announcer] in
            await announcer.withdrawWhatIsNoLongerUnread()
        })
        // The Dock tile, not `setBadgeCount`: unless the app is kept in the Dock, its relaunched icon
        // does not show the count the system kept, and sending that same count again does not bring
        // it back.
        tasks.append(Task { [inbox] in
            for await _ in Observations({ inbox.badgeLabel }) {
                NSApp.dockTile.badgeLabel = inbox.badgeLabel
                Self.log.info("Badge set to \(inbox.badgeLabel ?? "nothing", privacy: .public)")
            }
        })
        // A relaunched Dock has forgotten the badge, and AppKit does not pass on a label it has
        // already set, so the label is cleared before it is set again. A sink, not `values`: through
        // `values` the workspace's observation delivers only its first value.
        dockRelaunches = Dock.relaunches.sink { [inbox] in
            NSApp.dockTile.badgeLabel = nil
            NSApp.dockTile.badgeLabel = inbox.badgeLabel
            Self.log.info("Badge set again to \(inbox.badgeLabel ?? "nothing", privacy: .public) for the relaunched Dock")
        }
    }

    func showInbox() {
        NSApp.activate()
        openWindow?(id: "inbox")
    }

    // The window is only a view onto the inbox; polling and notifications continue without it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
