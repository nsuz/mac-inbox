import SwiftUI

@main
struct InboxApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Inbox", id: "inbox") {
            InboxView(inbox: appDelegate.inbox, account: appDelegate.account, poller: appDelegate.poller)
                .modifier(HandsOverOpenWindow(to: appDelegate))
        }
    }
}

// `openWindow` exists only in a view's environment, and the app delegate needs it to bring the
// window back when a notification it handles fails while the window is closed.
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
