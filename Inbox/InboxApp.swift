import SwiftUI

@main
struct InboxApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Inbox", id: "inbox") {
            InboxView(inbox: appDelegate.inbox, account: appDelegate.account)
        }
    }
}
