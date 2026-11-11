import SwiftUI

struct InboxView: View {
    let inbox: Inbox
    let account: Account

    var body: some View {
        List(inbox.notifications) { notification in
            VStack(alignment: .leading) {
                Text(notification.subject.title)
                Text(notification.repository.fullName)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if inbox.notifications.isEmpty {
                ContentUnavailableView("No Unread Notifications", systemImage: "tray")
            }
        }
        .navigationSubtitle(account.login ?? "")
    }
}
