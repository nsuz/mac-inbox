import AppKit
import Observation

@Observable
final class Inbox {
    struct Refresh {
        let pollInterval: Duration
        let news: [GitHub.Notification]
    }

    struct BrowserDidNotOpen: Error {}

    struct Delivery {
        let threadID: GitHub.Notification.ID
        let login: String?
    }

    private(set) var notifications: [GitHub.Notification] = []
    private(set) var isLoaded = false

    @ObservationIgnored private let client: GitHub.Client
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sightings = Sightings()
    @ObservationIgnored private var threadsInProgress = Set<GitHub.Notification.ID>()

    init(client: GitHub.Client, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.client = client
        self.openURL = openURL
    }

    func refresh() async throws -> Refresh {
        let startedAt = generation
        let unread = try await client.unread(ifNoneMatch: etag)
        guard startedAt == generation, case let .modified(notifications, etag, _) = unread else {
            return Refresh(pollInterval: unread.pollInterval, news: [])
        }
        self.notifications = notifications
        self.etag = etag
        isLoaded = true
        return Refresh(pollInterval: unread.pollInterval, news: sightings.news(in: notifications))
    }

    func resume() {
        client.resume()
    }

    func markAsRead(_ id: GitHub.Notification.ID) async throws {
        try await exclusively(id) {
            try await recordRead(id)
        }
    }

    func open(_ notification: GitHub.Notification) async throws {
        try await exclusively(notification.id) {
            let page = await webPage(of: notification)
            guard openURL(page ?? GitHub.inbox) else { throw BrowserDidNotOpen() }
            if page != nil {
                try await recordRead(notification.id)
            }
        }
    }

    private func exclusively(_ id: GitHub.Notification.ID, _ work: () async throws -> Void) async throws {
        guard threadsInProgress.insert(id).inserted else { return }
        defer { threadsInProgress.remove(id) }
        try await work()
    }

    private func recordRead(_ id: GitHub.Notification.ID) async throws {
        try await client.markAsRead(id)
        generation += 1
        notifications.removeAll { $0.id == id }
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
