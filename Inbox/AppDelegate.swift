import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let account = Account()
    let poller = Poller()
    private(set) lazy var inbox = Inbox(client: GitHub.Client(token: { [account] in try await account.token() }))
    private var polling: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted by this app; a test run must not poll the real account.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        polling = Task { [inbox, poller] in
            await poller.run { try await inbox.refresh().pollInterval }
        }
    }

    // The window is only a view onto the inbox; polling and notifications continue without it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
