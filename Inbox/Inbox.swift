import AppKit
import Observation

@Observable
final class Inbox {
    struct Refresh {
        let pollInterval: Duration
        let news: [GitHub.Notification]
    }

    struct BrowserDidNotOpen: Error {}

    struct FailedAction {
        let title: String
        let problem: Problem
    }

    struct Delivery {
        let threadID: GitHub.Notification.ID
        let login: String?
    }

    private(set) var notifications: [GitHub.Notification] = []
    private(set) var isLoaded = false
    private(set) var isRefreshing = false
    private(set) var failedAction: FailedAction?

    // Nothing until the first refresh: an empty list before then is not "no unread threads".
    var badgeLabel: String? {
        isLoaded && !notifications.isEmpty ? String(notifications.count) : nil
    }

    @ObservationIgnored private let client: GitHub.Client
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private var etag: String?
    // Threads marked as read since the last refresh began, at the activity they were read at.
    @ObservationIgnored private var readSinceRefreshBegan: [GitHub.Notification.ID: Date] = [:]
    @ObservationIgnored private var sightings = Sightings()
    @ObservationIgnored private var threadsInProgress = Set<GitHub.Notification.ID>()

    init(client: GitHub.Client, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.client = client
        self.openURL = openURL
    }

    func refresh() async throws -> Refresh {
        readSinceRefreshBegan = [:]
        isRefreshing = true
        defer { isRefreshing = false }
        // Only the first load shows pages as they arrive: once loaded, a partial list would make
        // the threads on later pages look read.
        let unread = try await client.unread(ifNoneMatch: etag) { arrived in
            if !isLoaded {
                notifications = stillUnread(arrived)
            }
        }
        guard case let .modified(fetched, etag, _) = unread else {
            return Refresh(pollInterval: unread.pollInterval, news: [])
        }
        notifications = stillUnread(fetched)
        self.etag = etag
        isLoaded = true
        return Refresh(pollInterval: unread.pollInterval, news: sightings.news(in: notifications))
    }

    func resume() {
        client.resume()
    }

    func markAsRead(_ notification: GitHub.Notification) async {
        await perform(on: notification, failing: "Couldn’t Mark “\(notification.subject.title)” as Read") {
            try await recordRead(notification)
        }
    }

    func open(_ notification: GitHub.Notification) async {
        await perform(on: notification, failing: "Couldn’t Open “\(notification.subject.title)”") {
            let page = await webPage(of: notification)
            guard openURL(page ?? GitHub.inbox) else { throw BrowserDidNotOpen() }
            if page != nil {
                try await recordRead(notification)
            }
        }
    }

    func reportFailure(_ error: any Error, opening notification: GitHub.Notification) {
        failedAction = FailedAction(title: "Couldn’t Open “\(notification.subject.title)”", problem: Problem(error))
    }

    func dismissFailedAction() {
        failedAction = nil
    }

    private func perform(on notification: GitHub.Notification, failing title: String, _ work: () async throws -> Void) async {
        guard threadsInProgress.insert(notification.id).inserted else { return }
        defer { threadsInProgress.remove(notification.id) }
        do {
            try await work()
        } catch {
            failedAction = FailedAction(title: title, problem: Problem(error))
        }
    }

    private func recordRead(_ notification: GitHub.Notification) async throws {
        try await client.markAsRead(notification.id)
        readSinceRefreshBegan[notification.id] = notification.updatedAt
        notifications.removeAll { $0.id == notification.id }
    }

    // Not discarding the refresh: during the first load that would leave the rest of the inbox
    // unloaded until the next poll. A thread fetched before GitHub recorded the read is dropped;
    // one with activity newer than what was read is unread again.
    private func stillUnread(_ fetched: [GitHub.Notification]) -> [GitHub.Notification] {
        fetched.filter { notification in
            readSinceRefreshBegan[notification.id].map { notification.updatedAt > $0 } ?? true
        }
    }

    private func webPage(of notification: GitHub.Notification) async -> URL? {
        if let runs = notification.workflowRunsPage {
            return runs
        }
        for resource in [notification.subject.latestCommentURL, notification.subject.url].compactMap(\.self) {
            do {
                return try await client.htmlURL(of: resource)
            } catch GitHub.Failure.notFound {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }

    func staleDeliveries(_ deliveries: [Delivery], for login: String) -> [GitHub.Notification.ID] {
        guard isLoaded else { return [] }
        let unread = Set(notifications.map(\.id))
        return deliveries
            .filter { $0.login != login || !unread.contains($0.threadID) }
            .map(\.threadID)
    }
}

private struct Sightings {
    private var latest: [GitHub.Notification.ID: Date] = [:]
    private var hasBaseline = false

    mutating func news(in notifications: [GitHub.Notification]) -> [GitHub.Notification] {
        defer { hasBaseline = true }
        return notifications.filter { notification in
            let previous = latest[notification.id]
            let hasNewActivity = previous.map { notification.updatedAt > $0 } ?? true
            latest[notification.id] = max(previous ?? notification.updatedAt, notification.updatedAt)
            return hasBaseline && hasNewActivity
        }
    }
}
