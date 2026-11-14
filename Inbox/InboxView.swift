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
        .focusedSceneValue(\.selectedNotification, selected.map { notification in
            SelectedNotification(open: { open(notification) }, markAsRead: { markAsRead(notification) })
        })
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
        List(inbox.shown, selection: $selection) { notification in
            NotificationRow(notification: notification, activity: inbox.activities[notification.id])
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
            if inbox.shown.isEmpty {
                if inbox.isLoaded {
                    ContentUnavailableView("No Unread Notifications", systemImage: "tray")
                } else if inbox.isRefreshing {
                    ProgressView()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem {
                ProblemBanner(problem: problem, tryAgain: tryAgain)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !inbox.isLoaded, inbox.isRefreshing, !inbox.shown.isEmpty {
                LoadingBar()
            }
        }
    }

    private var selected: GitHub.Notification? {
        selection.flatMap { id in inbox.shown.first { $0.id == id } }
    }

    // One row at a time rather than a chosen set: GitHub marks threads as read only one request
    // at a time, so a large set would take far longer than a press seems to, and quitting midway
    // would leave some of it unread.
    private func notification(in ids: Set<GitHub.Notification.ID>) -> GitHub.Notification? {
        ids.first.flatMap { id in inbox.shown.first { $0.id == id } }
    }

    // The row leaves only once the thread is read, which depends on where it opened, so the
    // selection moves then, and only if it is still on that row.
    private func open(_ notification: GitHub.Notification) {
        let successor = inbox.shown.successor(of: notification.id)
        Task {
            await inbox.open(notification)
            if selection == notification.id, !inbox.isUnread(notification) {
                selection = successor
            }
        }
    }

    // Immediate, so that the row has left before the next key press.
    private func markAsRead(_ notification: GitHub.Notification) {
        if selection == notification.id {
            selection = inbox.shown.successor(of: notification.id)
        }
        Task.immediate { await inbox.markAsRead(notification) }
    }

    private func tryAgain() {
        inbox.resume()
        poller.resume()
    }
}

private struct LoadingBar: View {
    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Loading Notifications…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
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

extension [GitHub.Notification] {
    // The row that takes the place of one leaving through the viewer's own action, as Mail moves
    // to the next message. Only then: had the row been read elsewhere, a row the viewer never
    // chose would be selected and could be marked as read unawares.
    func successor(of id: GitHub.Notification.ID) -> GitHub.Notification.ID? {
        guard let index = firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < endIndex {
            return self[index + 1].id
        }
        return index > startIndex ? self[index - 1].id : nil
    }
}
