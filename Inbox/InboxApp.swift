import SwiftUI

@main
struct InboxApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true

    var body: some Scene {
        Window("Inbox", id: "inbox") {
            InboxView(inbox: appDelegate.inbox, account: appDelegate.account, poller: appDelegate.poller)
                .modifier(HandsOverOpenWindow(to: appDelegate))
        }
        .commands {
            NotificationCommands()
        }
        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuContent(inbox: appDelegate.inbox, poller: appDelegate.poller)
        } label: {
            MenuBarLabel(inbox: appDelegate.inbox)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            SettingsView(showsMenuBarExtra: $showsMenuBarExtra)
                .modifier(HandsOverOpenWindow(to: appDelegate))
        }
        .windowResizability(.contentSize)
    }
}

// `openWindow` exists only in a view's environment, and the app delegate needs it to bring the
// inbox window back when an action fails while another window is showing.
private struct HandsOverOpenWindow: ViewModifier {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    init(to appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func body(content: Content) -> some View {
        content.onAppear { appDelegate.openWindow = openWindow }
    }
}
