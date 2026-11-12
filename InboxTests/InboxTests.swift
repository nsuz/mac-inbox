import Foundation
import Testing
@testable import Inbox

struct InboxTests {
    private let server = FakeServer()
    private let browser = FakeBrowser()

    private func makeInbox() -> Inbox {
        Inbox(client: GitHub.Client(token: { "token" }, send: server.send), openURL: browser.open)
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

    @Test func isLoadedOnlyOnceARefreshHasSucceeded() async throws {
        let inbox = makeInbox()
        server.reply(502)
        _ = try? await inbox.refresh()
        #expect(!inbox.isLoaded)

        server.reply(200, body: Fixture.page())
        _ = try await inbox.refresh()
        #expect(inbox.isLoaded)
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
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))

        #expect(inbox.notifications.map(\.id) == ["2"])
        #expect(inbox.failedAction == nil)
    }

    @Test func aThreadThatCouldNotBeMarkedAsReadStaysOnTheListAndTheFailureIsReported() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1")))
        _ = try await inbox.refresh()

        server.reply(502)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))

        #expect(inbox.notifications.map(\.id) == ["1"])
        #expect(inbox.failedAction?.title == "Couldn’t Mark “Fix popup position” as Read")
        #expect(inbox.failedAction?.problem.actionMessage == "GitHub returned an error. The notification is still unread.")
    }

    @Test func aReportedFailureCanBeDismissed() async throws {
        let inbox = makeInbox()
        server.reply(502)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))

        inbox.dismissFailedAction()

        #expect(inbox.failedAction == nil)
    }

    @Test func aRefreshThatWasUnderwayWhileAThreadWasMarkedAsReadIsDiscarded() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)
        server.reply(205)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))
        gate.open()
        let refresh = try await refreshing.value

        #expect(inbox.notifications.map(\.id) == ["2"])
        #expect(refresh.news.isEmpty)
    }

    // MARK: - Opening

    @Test func opensTheLatestCommentAndMarksTheThreadAsRead() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()

        server.reply(200, body: #"{"html_url":"https://github.com/octo/app/pull/42#issuecomment-7"}"#)
        server.reply(205)
        await inbox.open(Fixture.notification(Fixture.pullRequest))

        #expect(server.requests.dropFirst().map { $0.url?.absoluteString } == [
            "https://api.github.com/repos/octo/app/issues/comments/7",
            "https://api.github.com/notifications/threads/1001",
        ])
        #expect(browser.opened == [URL(string: "https://github.com/octo/app/pull/42#issuecomment-7")!])
        #expect(inbox.notifications.isEmpty)
    }

    @Test func opensTheThreadItselfWhenTheLatestCommentIsGone() async throws {
        let inbox = makeInbox()
        server.reply(404, body: #"{"message":"Not Found"}"#)
        server.reply(200, body: #"{"html_url":"https://github.com/octo/app/pull/42"}"#)
        server.reply(205)

        await inbox.open(Fixture.notification(Fixture.pullRequest))

        #expect(server.requests.map { $0.url?.absoluteString } == [
            "https://api.github.com/repos/octo/app/issues/comments/7",
            "https://api.github.com/repos/octo/app/pulls/42",
            "https://api.github.com/notifications/threads/1001",
        ])
        #expect(browser.opened == [URL(string: "https://github.com/octo/app/pull/42")!])
    }

    @Test func opensTheMatchingWorkflowRunsForACheckSuiteAndMarksItAsRead() async throws {
        let inbox = makeInbox()
        let checkSuite = Fixture.thread(id: "1003", reason: "ci_activity", title: "CI workflow run failed for main branch", type: "CheckSuite", url: nil, latestCommentURL: nil)
        server.reply(200, body: Fixture.page(checkSuite))
        _ = try await inbox.refresh()

        server.reply(205)
        await inbox.open(Fixture.notification(checkSuite))

        #expect(browser.opened.map(\.path) == ["/octo/app/actions"])
        #expect(server.requests.last?.url?.absoluteString == "https://api.github.com/notifications/threads/1003")
        #expect(inbox.notifications.isEmpty)
    }

    @Test func opensGitHubsInboxAndLeavesTheThreadUnreadWhenItHasNoPageOfItsOwn() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.checkSuite))
        _ = try await inbox.refresh()

        await inbox.open(Fixture.notification(Fixture.checkSuite))

        #expect(server.requests.count == 1)
        #expect(browser.opened == [URL(string: "https://github.com/notifications")!])
        #expect(inbox.notifications.map(\.id) == ["1002"])
    }

    @Test(arguments: [
        (429, ["Retry-After": "30"], #"{"message":"You have exceeded a secondary rate limit."}"#),
        (502, [:], ""),
    ])
    func stopsAskingGitHubAndOpensItsInboxWhenResolvingFails(status: Int, headers: [String: String], body: String) async throws {
        let inbox = makeInbox()
        server.reply(status, headers: headers, body: body)

        await inbox.open(Fixture.notification(Fixture.pullRequest))

        #expect(server.requests.count == 1)
        #expect(browser.opened == [URL(string: "https://github.com/notifications")!])
    }

    @Test func leavesTheThreadUnreadAndReportsItWhenTheBrowserCannotOpenIt() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        browser.accepts = false
        server.reply(200, body: #"{"html_url":"https://github.com/octo/app/pull/42#issuecomment-7"}"#)

        await inbox.open(Fixture.notification(Fixture.pullRequest))

        #expect(server.requests.count == 2)
        #expect(inbox.notifications.map(\.id) == ["1001"])
        #expect(inbox.failedAction?.title == "Couldn’t Open “Fix popup position”")
        #expect(inbox.failedAction?.problem.title == "Couldn’t Open the Browser")
    }

    @Test func aThreadThatIsBeingOpenedIsNotOpenedOrMarkedAgainMeanwhile() async throws {
        let inbox = makeInbox()
        let notification = Fixture.notification(Fixture.pullRequest)
        let gate = server.replyLater(200, body: #"{"html_url":"https://github.com/octo/app/pull/42"}"#)
        let opening = Task { await inbox.open(notification) }
        await server.waitForRequests(1)

        await inbox.open(notification)
        await inbox.markAsRead(notification)
        server.reply(205)
        gate.open()
        await opening.value

        #expect(server.requests.count == 2)
        #expect(browser.opened.count == 1)
    }

    // MARK: - Notification Center

    @Test func showsNoBadgeUntilTheFirstRefreshHasSucceeded() async throws {
        let inbox = makeInbox()
        server.reply(502)
        _ = try? await inbox.refresh()

        #expect(inbox.badgeLabel == nil)
    }

    @Test func showsNoBadgeWhenNothingIsUnread() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page())
        _ = try await inbox.refresh()

        #expect(inbox.badgeLabel == nil)
    }

    @Test func badgesTheNumberOfUnreadThreadsOnceLoaded() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        #expect(inbox.badgeLabel == "2")
    }

    @Test func withdrawsNothingBeforeTheFirstRefreshHasSucceeded() {
        let inbox = makeInbox()

        #expect(inbox.staleDeliveries([.init(threadID: "1", login: "octo")], for: "octo").isEmpty)
    }

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

final class FakeBrowser {
    var accepts = true
    private(set) var opened: [URL] = []

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return accepts
    }
}

