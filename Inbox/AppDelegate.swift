import AppKit
import Combine
import Observation
import OSLog
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "app")

    let account = Account()
    let poller = Poller()
    private(set) lazy var inbox = Inbox(client: GitHub.Client(token: { [account] in try await account.token() }))
    private lazy var announcer = Announcer(inbox: inbox, account: account)
    // Handed over by the view of each window when it appears; see `showInbox()`.
    var openWindow: OpenWindowAction?
    private var tasks: [Task<Void, Never>] = []
    private var dockRelaunches: AnyCancellable?
    private var badgeOverwrites: AnyCancellable?

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
        // A failed action is told in the window's alert, so the window comes forward whenever one
        // appears, whether it came from the window, a notification or the menu bar.
        tasks.append(Task { [inbox] in
            for await hasFailed in Observations({ inbox.failedAction != nil }) where hasFailed {
                await self.showInbox()
            }
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
            Self.log.notice("Badge set again to \(inbox.badgeLabel ?? "nothing", privacy: .public) for the relaunched Dock")
        }
        // SwiftUI also sets the tile's label, to the badge of its scenes, when the first window
        // comes on screen; for an app opened at login that is long after the inbox has loaded.
        // Scenes cannot be given a badge through public API, so the label is put back instead.
        badgeOverwrites = NSApp.dockTile.publisher(for: \.badgeLabel).sink { [inbox] label in
            guard label != inbox.badgeLabel else { return }
            NSApp.dockTile.badgeLabel = inbox.badgeLabel
            Self.log.notice("Badge set back to \(inbox.badgeLabel ?? "nothing", privacy: .public) over \(label ?? "nothing", privacy: .public)")
        }
    }

    // Reopening the app, as a click on its Dock icon does, brings it forward even when it is
    // hidden, where `NSApp.activate()` outside a click does not, and opens the inbox if no window
    // is showing. With another window showing, such as Settings, it opens nothing, so `openWindow`
    // follows; that action exists only in views, and some window's view has handed it over
    // whenever a window is showing.
    private func showInbox() async {
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            Self.log.error("Couldn’t bring the inbox forward: \(error, privacy: .public)")
        }
        openWindow?(id: "inbox")
    }

    // The window is only a view onto the inbox; polling and notifications continue without it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
