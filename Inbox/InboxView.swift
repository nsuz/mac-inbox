import SwiftUI

struct InboxView: View {
    let inbox: Inbox
    let account: Account
    let poller: Poller

    @State private var selection: GitHub.Notification.ID?
    @Environment(\.openURL) private var openURL

    private var problem: Problem? {
        poller.failure.map(Problem.init)
    }

    var body: some View {
        Group {
            if let problem, problem.replacesList {
                ContentUnavailableView {
                    Label(problem.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.refreshMessage)
                }
            } else {
                list
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .navigationSubtitle(account.login ?? "")
        .toolbar {
            Button("Open Notifications on GitHub", systemImage: "safari") {
                openURL(GitHub.inbox)
            }
            .help("Open Notifications on GitHub")
        }
        .alert(
            inbox.failedAction?.title ?? "",
            isPresented: Binding(get: { inbox.failedAction != nil }, set: { if !$0 { inbox.dismissFailedAction() } }),
            presenting: inbox.failedAction
        ) { _ in
        } message: { failedAction in
            Text(failedAction.problem.actionMessage)
        }
    }

    private var list: some View {
        List(inbox.notifications, selection: $selection) { notification in
            NotificationRow(notification: notification)
        }
        .contextMenu(forSelectionType: GitHub.Notification.ID.self) { ids in
            if let notification = notification(in: ids) {
                Button("Open") { open(notification) }
                Button("Mark as Read") { markAsRead(notification) }
            }
        } primaryAction: { ids in
            notification(in: ids).map(open)
        }
        .overlay {
            if !inbox.isLoaded {
                ProgressView()
            } else if inbox.notifications.isEmpty {
                ContentUnavailableView("No Unread Notifications", systemImage: "tray")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem {
                ProblemBanner(problem: problem, tryAgain: tryAgain)
            }
        }
    }

    // The list selects one thread at a time: GitHub has no endpoint that marks a chosen set
    // of threads as read, and one request per selected row would flood it.
    private func notification(in ids: Set<GitHub.Notification.ID>) -> GitHub.Notification? {
        ids.first.flatMap { id in inbox.notifications.first { $0.id == id } }
    }

    private func open(_ notification: GitHub.Notification) {
        Task { await inbox.open(notification) }
    }

    private func markAsRead(_ notification: GitHub.Notification) {
        Task { await inbox.markAsRead(notification) }
    }

    private func tryAgain() {
        inbox.resume()
        poller.resume()
    }
}

private struct ProblemBanner: View {
    let problem: Problem
    let tryAgain: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title)
                    .font(.headline)
                Text(problem.refreshMessage)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if problem.offersTryAgain {
                Button("Try Again", action: tryAgain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
