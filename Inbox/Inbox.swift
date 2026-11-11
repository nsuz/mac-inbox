import Foundation
import Observation

@Observable
final class Inbox {
    struct Refresh {
        let pollInterval: Duration
        let news: [GitHub.Notification]
    }

    struct Delivery {
        let threadID: GitHub.Notification.ID
        let login: String?
    }

    private(set) var notifications: [GitHub.Notification] = []

    @ObservationIgnored private let client: GitHub.Client
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sightings = Sightings()

    init(client: GitHub.Client) {
        self.client = client
    }

    func refresh() async throws -> Refresh {
        let startedAt = generation
        let unread = try await client.unread(ifNoneMatch: etag)
        guard startedAt == generation, case let .modified(notifications, etag, _) = unread else {
            return Refresh(pollInterval: unread.pollInterval, news: [])
        }
        self.notifications = notifications
        self.etag = etag
        return Refresh(pollInterval: unread.pollInterval, news: sightings.news(in: notifications))
    }

    func markAsRead(_ id: GitHub.Notification.ID) async throws {
        try await client.markAsRead(id)
        generation += 1
        notifications.removeAll { $0.id == id }
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
