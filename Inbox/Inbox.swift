import AppKit
import Observation
import OSLog

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

    private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "inbox")

    private(set) var notifications: [GitHub.Notification] = []
    private(set) var activities: [GitHub.Notification.ID: GitHub.Activity] = [:]
    private(set) var isLoaded = false
    // Showing what the last launch knew until the first refresh replaces it.
    private var isRestored = false
    private(set) var isRefreshing = false
    private(set) var failedAction: FailedAction?

    // Nothing until the first refresh or a restored list: an empty list before then is not
    // "no unread threads".
    var badgeLabel: String? {
        (isLoaded || isRestored) && !notifications.isEmpty ? String(notifications.count) : nil
    }

    // Only what a refresh has confirmed is worth keeping for the next launch.
    var snapshot: Snapshot? {
        guard isLoaded else { return nil }
        let unread = Set(notifications.map(\.id))
        return Snapshot(notifications: notifications, activities: activities.filter { unread.contains($0.key) })
    }

    @ObservationIgnored private let client: GitHub.Client
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private var etag: String?
    // Threads marked as read since the last refresh began, at the activity they were read at.
    @ObservationIgnored private var readSinceRefreshBegan: [GitHub.Notification.ID: Date] = [:]
    @ObservationIgnored private var sightings = Sightings()
    @ObservationIgnored private var threadsInProgress = Set<GitHub.Notification.ID>()
    // Keyed by the thread as it was asked about, so that asking about newer activity does not
    // wait for an answer about older activity.
    @ObservationIgnored private var descriptions: [GitHub.Notification: Task<Bool, Never>] = [:]

    init(client: GitHub.Client, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.client = client
        self.openURL = openURL
    }

    // The restored list stands in for the first load, so the snapshot is no longer worth reading
    // once a refresh has succeeded.
    func restore(_ snapshot: Snapshot) {
        guard !isLoaded else { return }
        notifications = snapshot.notifications
        activities = snapshot.activities
        isRestored = true
    }

    func refresh() async throws -> Refresh {
        readSinceRefreshBegan = [:]
        isRefreshing = true
        defer { isRefreshing = false }
        // Only a first load with nothing restored shows pages as they arrive: otherwise a partial
        // list would make the threads on later pages look read.
        let unread = try await client.unread(ifNoneMatch: etag) { arrived in
            if !isLoaded, !isRestored {
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

    func isUnread(_ notification: GitHub.Notification) -> Bool {
        notifications.contains { $0.id == notification.id }
    }

    // Nil unless the description is of this very activity: an older one would tell of what has
    // already happened as if it were news.
    func activity(describing notification: GitHub.Notification) -> GitHub.Activity? {
        activities[notification.id].flatMap { $0.asOf == notification.updatedAt ? $0 : nil }
    }

    // After every refresh, whether it changed the list, found it unchanged or failed: a pass that
    // failed is taken up again once GitHub may be reachable, not only once the inbox changes.
    func describeAfterEveryRefresh() async {
        for await isRefreshing in Observations({ self.isRefreshing }) where !isRefreshing {
            await describeThreads()
        }
    }

    func describeThreads() async {
        await describe(notifications)
    }

    // In the order given, newest first for the list, a few dozen threads to a query and one query
    // after another, as GitHub asks of integrators. A query that fails whole ends the pass, since
    // the rest would most likely fail the same way; one that fails for some threads does not, or a
    // thread that always fails would keep those after it undescribed. The next pass takes up
    // whatever is left.
    func describe(_ threads: [GitHub.Notification]) async {
        var askable: [GitHub.Notification] = []
        for notification in threads where needsDescribing(notification) {
            if notification.issueOrPullRequest == nil {
                record(.nothingToTell(asOf: notification.updatedAt), for: notification.id)
            } else {
                askable.append(notification)
            }
        }
        for start in stride(from: 0, to: askable.count, by: GitHub.ThreadQuery.limit) {
            let batch = askable[start..<min(start + GitHub.ThreadQuery.limit, askable.count)]
            guard await describe(batch: Array(batch)) else { return }
        }
    }

    // A thread is asked about from the list and from a banner at once; the second waits for the
    // first answer rather than asking GitHub again. False when a query failed whole.
    private func describe(batch threads: [GitHub.Notification]) async -> Bool {
        // Some may have been described from elsewhere while an earlier query was awaited. An open
        // pull request is asked about again even so; it is one thread among a few dozen.
        let threads = threads.filter(needsDescribing)
        let pending = Set(threads.compactMap { descriptions[$0] })
        let unasked = threads.filter { descriptions[$0] == nil }
        var described = true
        if !unasked.isEmpty {
            let query = Task { await ask(about: unasked) }
            for thread in unasked {
                descriptions[thread] = query
            }
            described = await query.value
            for thread in unasked {
                descriptions[thread] = nil
            }
        }
        for query in pending {
            described = await query.value && described
        }
        return described
    }

    private func ask(about threads: [GitHub.Notification]) async -> Bool {
        do {
            for (id, activity) in try await client.describe(threads) {
                record(activity, for: id)
            }
            return true
        } catch {
            Self.log.error("Couldn’t describe \(threads.count, privacy: .public) threads: \(error, privacy: .public)")
            return false
        }
    }

    // Not yet described as the thread is now, or as it has been since (a banner may have asked
    // about newer activity). What was done on a thread stays as it was described, but whether the
    // viewer's review is awaited can change without the thread being updated, so an open or draft
    // pull request is described again every time.
    private func needsDescribing(_ notification: GitHub.Notification) -> Bool {
        guard let activity = activities[notification.id], activity.asOf >= notification.updatedAt else { return true }
        return notification.subject.type == "PullRequest" && (activity.state == .open || activity.state == .draft)
    }

    // An answer about older activity can arrive after one about newer activity. An answer that
    // tells nothing new leaves the description alone, or every pass would count as a change and
    // write the snapshot again.
    private func record(_ activity: GitHub.Activity, for id: GitHub.Notification.ID) {
        if activities[id].map({ $0.asOf <= activity.asOf && $0 != activity }) ?? true {
            activities[id] = activity
        }
    }

    func markAsRead(_ notification: GitHub.Notification) async {
        await perform(on: notification, failing: "Couldn’t Mark “\(notification.subject.title)” as Read") {
            try await recordRead(notification)
        }
    }

    // At the event a banner told of, when it was opened from one: the description that told of it
    // may since have been replaced by one of newer activity.
    func open(_ notification: GitHub.Notification, at event: URL? = nil) async {
        await perform(on: notification, failing: "Couldn’t Open “\(notification.subject.title)”") {
            let page = if let event { event } else { await webPage(of: notification) }
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
        // Where the row points; GitHub's latest comment would miss a review.
        if let event = activity(describing: notification)?.unreadEvent(lastReadAt: notification.lastReadAt)?.url {
            return event
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
