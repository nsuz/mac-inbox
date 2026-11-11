import Foundation
import Testing
@testable import Inbox

struct InboxTests {
    private let server = FakeServer()

    private func makeInbox() -> Inbox {
        Inbox(client: GitHub.Client(token: { "token" }, send: server.send))
    }

    // MARK: - Listing

    @Test func theFirstRefreshListsTheUnreadThreadsWithoutAnnouncingAny() async throws {
        let inbox = makeInbox()
        server.reply(200, headers: ["X-Poll-Interval": "60"], body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))

        let refresh = try await inbox.refresh()

        #expect(inbox.notifications.map(\.id) == ["1", "2"])
        #expect(refresh.news.isEmpty)
        #expect(refresh.pollInterval == .seconds(60))
    }

    @Test func aLaterRefreshAnnouncesNewThreadsAndThreadsWithNewActivity() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1", updatedAt: "2026-11-11T01:00:00Z"), Fixture.thread(id: "2", updatedAt: "2026-11-11T01:00:00Z")))
        _ = try await inbox.refresh()

        server.reply(200, body: Fixture.page(
            Fixture.thread(id: "3", updatedAt: "2026-11-11T03:00:00Z"),
            Fixture.thread(id: "2", updatedAt: "2026-11-11T02:00:00Z"),
            Fixture.thread(id: "1", updatedAt: "2026-11-11T01:00:00Z")
        ))
        let refresh = try await inbox.refresh()

        #expect(refresh.news.map(\.id) == ["3", "2"])
    }

    @Test func aThreadThatReappearsWithoutNewActivityIsNotAnnouncedAgain() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1")))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.page())
        _ = try await inbox.refresh()

        server.reply(200, body: Fixture.page(Fixture.thread(id: "1")))
        let refresh = try await inbox.refresh()

        #expect(refresh.news.isEmpty)
    }

    @Test func anOlderUpdateTimeNeverRewindsWhatHasBeenSeen() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1", updatedAt: "2026-11-11T02:00:00Z")))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1", updatedAt: "2026-11-11T01:00:00Z")))
        _ = try await inbox.refresh()

        server.reply(200, body: Fixture.page(Fixture.thread(id: "1", updatedAt: "2026-11-11T02:00:00Z")))
        let refresh = try await inbox.refresh()

        #expect(refresh.news.isEmpty)
    }

    @Test func anUnchangedInboxKeepsItsListAndAsksWithTheLastETag() async throws {
        let inbox = makeInbox()
        server.reply(200, headers: ["ETag": #""v1""#], body: Fixture.page(Fixture.thread(id: "1")))
        _ = try await inbox.refresh()

        server.reply(304)
        let refresh = try await inbox.refresh()

        #expect(inbox.notifications.map(\.id) == ["1"])
        #expect(refresh.news.isEmpty)
        #expect(server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
    }

    @Test func aFailedRefreshKeepsBothTheListAndTheETag() async throws {
        let inbox = makeInbox()
        server.reply(200, headers: ["ETag": #""v1""#], body: Fixture.page(Fixture.thread(id: "1")))
        _ = try await inbox.refresh()

        server.reply(200, headers: ["ETag": #""v2""#, "Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "2")))
        server.reply(502)
        _ = try? await inbox.refresh()

        #expect(inbox.notifications.map(\.id) == ["1"])
        server.reply(304)
        _ = try await inbox.refresh()
        #expect(server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
    }

    // MARK: - Marking as read

    @Test func markingAThreadAsReadTakesItOffTheList() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        server.reply(205)
        try await inbox.markAsRead("1")

        #expect(inbox.notifications.map(\.id) == ["2"])
    }

    @Test func aThreadThatCouldNotBeMarkedAsReadStaysOnTheList() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1")))
        _ = try await inbox.refresh()

        server.reply(502)
        _ = try? await inbox.markAsRead("1")

        #expect(inbox.notifications.map(\.id) == ["1"])
    }

    @Test func aRefreshThatWasUnderwayWhileAThreadWasMarkedAsReadIsDiscarded() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)
        server.reply(205)
        try await inbox.markAsRead("1")
        gate.open()
        let refresh = try await refreshing.value

        #expect(inbox.notifications.map(\.id) == ["2"])
        #expect(refresh.news.isEmpty)
    }

    // MARK: - Notification Center

    @Test func withdrawsDeliveredNotificationsThatAreNoLongerUnreadOrBelongToAnotherAccount() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        let stale = inbox.staleDeliveries(
            [
                .init(threadID: "1", login: "octo"),
                .init(threadID: "2", login: "someone-else"),
                .init(threadID: "3", login: "octo"),
            ],
            for: "octo"
        )

        #expect(stale == ["2", "3"])
    }
}
