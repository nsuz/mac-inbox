import AppKit
import SwiftUI

struct MenuContent: View {
    let inbox: Inbox
    let poller: Poller

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private static let limit = 10

    var body: some View {
        if let problem = poller.failure.map(Problem.init), problem.offersTryAgain {
            Text(problem.title)
            Button("Try Again") {
                inbox.resume()
                poller.resume()
            }
            Divider()
        }
        ForEach(inbox.notifications.prefix(Self.limit)) { notification in
            Button {
                Task { await inbox.open(notification) }
            } label: {
                Text(notification.subject.title)
                Text(notification.repository.fullName)
            }
        }
        if !inbox.notifications.isEmpty {
            Divider()
        }
        // Activating first: a menu bar extra's actions run while the app may be inactive, and
        // the window or settings would then open behind the frontmost app.
        Button("Open Inbox") {
            NSApp.activate()
            openWindow(id: "inbox")
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Inbox") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let inbox: Inbox

    var body: some View {
        Label("Inbox", systemImage: inbox.badgeLabel == nil ? "tray" : "tray.full")
    }
}
