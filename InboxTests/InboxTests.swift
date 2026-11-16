import Foundation
import Synchronization
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

    @Test func theFirstLoadListsThreadsAsTheirPagesArrive() async throws {
        let inbox = makeInbox()
        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "1")))
        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "2")))

        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)

        #expect(inbox.notifications.map(\.id) == ["1"])
        #expect(!inbox.isLoaded)
        gate.open()
        _ = try await refreshing.value
        #expect(inbox.notifications.map(\.id) == ["1", "2"])
        #expect(inbox.isLoaded)
    }

    @Test func aLaterRefreshReplacesTheListOnlyOnceEveryPageHasArrived() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1")))
        _ = try await inbox.refresh()

        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "2")))
        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "3")))
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(3)

        #expect(inbox.notifications.map(\.id) == ["1"])
        gate.open()
        _ = try await refreshing.value
        #expect(inbox.notifications.map(\.id) == ["2", "3"])
    }

    @Test func theFirstLoadFinishesAroundAThreadMarkedAsReadMeanwhile() async throws {
        let inbox = makeInbox()
        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "3")))
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)

        server.reply(205)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))
        gate.open()
        _ = try await refreshing.value

        #expect(inbox.notifications.map(\.id) == ["2", "3"])
        #expect(inbox.isLoaded)
    }

    @Test func aFirstLoadThatFailsPartwayKeepsWhatArrivedWithoutLookingLoadedOrBusy() async throws {
        let inbox = makeInbox()
        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "1")))
        server.reply(502)

        _ = try? await inbox.refresh()

        #expect(inbox.notifications.map(\.id) == ["1"])
        #expect(!inbox.isLoaded)
        #expect(!inbox.isRefreshing)
    }

    @Test func isRefreshingOnlyWhileARefreshIsUnderway() async throws {
        let inbox = makeInbox()
        let gate = server.replyLater(502)
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(1)

        #expect(inbox.isRefreshing)
        gate.open()
        _ = try? await refreshing.value
        #expect(!inbox.isRefreshing)
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
        #expect(inbox.failedAction?.title.english == "Couldn’t Mark “Fix popup position” as Read")
        #expect(inbox.failedAction?.problem.actionMessage.english == "GitHub returned an error. The notification is still unread.")
    }

    @Test func aFailureToMarkAsReadNamesTheThreadInJapaneseWordOrder() async throws {
        let inbox = makeInbox()
        server.reply(502)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))

        #expect(inbox.failedAction?.title.japanese == "“Fix popup position”を既読にできませんでした")
    }

    @Test func aFailureBeforeMarkingAsReadFromABannerNamesTheThread() {
        let inbox = makeInbox()

        inbox.reportFailure(URLError(.notConnectedToInternet), markingAsRead: Fixture.notification(Fixture.pullRequest))

        #expect(inbox.failedAction?.title.english == "Couldn’t Mark “Fix popup position” as Read")
    }

    @Test func aReportedFailureCanBeDismissed() async throws {
        let inbox = makeInbox()
        server.reply(502)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))

        inbox.dismissFailedAction()

        #expect(inbox.failedAction == nil)
    }

    @Test func aThreadBeingMarkedAsReadLeavesWhatIsShownAtOnceButStaysUnreadUntilGitHubAnswers() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        let gate = server.replyLater(205)
        let marking = Task.immediate { await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1"))) }

        #expect(inbox.shown.map(\.id) == ["2"])
        #expect(inbox.notifications.map(\.id) == ["1", "2"])
        #expect(inbox.badgeLabel == "2")
        gate.open()
        await marking.value
        #expect(inbox.shown.map(\.id) == ["2"])
        #expect(inbox.notifications.map(\.id) == ["2"])
        #expect(inbox.badgeLabel == "1")
    }

    @Test func aThreadThatCouldNotBeMarkedAsReadIsShownAgainWhereItWas() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2"), Fixture.thread(id: "3")))
        _ = try await inbox.refresh()

        server.reply(502)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "2")))

        #expect(inbox.shown.map(\.id) == ["1", "2", "3"])
    }

    @Test func aThreadBeingMarkedAsReadIsNotShownAgainByARefreshThatStillListsItUnread() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        let gate = server.replyLater(205)
        let marking = Task.immediate { await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1"))) }
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        #expect(inbox.shown.map(\.id) == ["2"])
        gate.open()
        await marking.value
        #expect(inbox.notifications.map(\.id) == ["2"])
    }

    // An alert's content cannot change once it is presented; a thread that failed later is
    // back in the list for all to see.
    @Test func aFailureWhileAnotherIsReportedLeavesTheReportAsItIs() async throws {
        let inbox = makeInbox()
        server.reply(502)
        server.reply(502)

        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "2", title: "Another thread")))

        #expect(inbox.failedAction?.title.english == "Couldn’t Mark “Fix popup position” as Read")
    }

    @Test func aThreadMarkedAsReadWhileARefreshIsUnderwayDoesNotComeBack() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()

        let gate = server.replyLater(200, headers: ["ETag": #""v2""#], body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)
        server.reply(205)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))
        gate.open()
        let refresh = try await refreshing.value

        #expect(inbox.notifications.map(\.id) == ["2"])
        #expect(refresh.news.isEmpty)
        server.reply(304)
        _ = try await inbox.refresh()
        #expect(server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #""v2""#)
    }

    @Test func aThreadMarkedAsReadWhileARefreshIsUnderwayComesBackWithNewerActivity() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1", updatedAt: "2026-11-11T01:00:00Z")))
        _ = try await inbox.refresh()

        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "1", updatedAt: "2026-11-11T02:00:00Z")))
        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)
        server.reply(205)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1", updatedAt: "2026-11-11T01:00:00Z")))
        gate.open()
        _ = try await refreshing.value

        #expect(inbox.notifications.map(\.id) == ["1"])
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

    @Test func opensTheUnreadEventItKnowsOfWithoutAskingGitHubWhereItIs() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.mergedByHubot)
        await inbox.describeThreads()

        server.reply(205)
        await inbox.open(Fixture.notification(Fixture.pullRequest))

        #expect(server.requests.dropFirst(2).map { $0.url?.absoluteString } == ["https://api.github.com/notifications/threads/1001"])
        #expect(browser.opened == [URL(string: "https://github.com/octo/app/pull/42#event-hubot")!])
        #expect(inbox.notifications.isEmpty)
    }

    @Test func opensTheLatestCommentRatherThanAnEventAlreadyRead() async throws {
        let inbox = makeInbox()
        let thread = Fixture.thread(id: "1001", lastReadAt: "2026-11-11T02:45:00Z")
        server.reply(200, body: Fixture.page(thread))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.mergedByHubot)
        await inbox.describeThreads()

        server.reply(200, body: #"{"html_url":"https://github.com/octo/app/pull/42#issuecomment-7"}"#)
        server.reply(205)
        await inbox.open(Fixture.notification(thread))

        #expect(browser.opened == [URL(string: "https://github.com/octo/app/pull/42#issuecomment-7")!])
    }

    @Test func opensTheEventABannerToldOfWithoutAskingGitHubWhereItIs() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()

        server.reply(205)
        await inbox.open(Fixture.notification(Fixture.pullRequest), at: URL(string: "https://github.com/octo/app/pull/42#pullrequestreview-9")!)

        #expect(server.requests.dropFirst().map { $0.url?.absoluteString } == ["https://api.github.com/notifications/threads/1001"])
        #expect(browser.opened == [URL(string: "https://github.com/octo/app/pull/42#pullrequestreview-9")!])
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
        #expect(inbox.failedAction?.title.english == "Couldn’t Open “Fix popup position”")
        #expect(inbox.failedAction?.problem.title.english == "Couldn’t Open the Browser")
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

    // MARK: - Describing threads

    private static let mergedByHubot = Fixture.answer(Fixture.pullRequest(state: "MERGED", items: Fixture.event("MergedEvent", by: "hubot", at: "2026-11-11T02:40:00Z")))

    private static func threads(_ count: Int) -> [String] {
        (1...count).map { Fixture.thread(id: String($0)) }
    }

    // Merged, so that nothing about them can change without new activity.
    private static func answer(describing count: Int, errors: [String] = []) -> String {
        Fixture.answer(subjects: Array(repeating: Fixture.pullRequest(state: "MERGED"), count: count), errors: errors)
    }

    private func variables(of request: URLRequest) throws -> [String: Any] {
        let body = try #require(try request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        return try #require(body["variables"] as? [String: Any])
    }

    @Test func describesAThreadByWhereItsSubjectStandsAndTheLatestThingSomeoneElseDid() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.mergedByHubot)

        await inbox.describeThreads()

        #expect(inbox.activities["1001"] == GitHub.Activity(
            asOf: Date(timeIntervalSince1970: 1_794_365_172),
            state: .merged,
            event: GitHub.Event(action: .merged, actor: "hubot", date: Fixture.date("2026-11-11T02:40:00Z"), url: URL(string: "https://github.com/octo/app/pull/42#event-hubot"), text: nil),
            awaitsYourReview: false
        ))
    }

    @Test func asksAboutTwentyFiveThreadsAtATimeOneQueryAfterAnother() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Self.threads(30)))
        _ = try await inbox.refresh()
        let gate = server.replyLater(200, body: Self.answer(describing: 25))
        server.reply(200, body: Self.answer(describing: 5))

        let describing = Task { await inbox.describeThreads() }
        await server.waitForRequests(2)
        for _ in 1...10 { await Task.yield() }
        #expect(server.requests.count == 2)
        gate.open()
        await describing.value

        #expect(try server.requests.dropFirst().map { try variables(of: $0).count } == [75, 15])
        #expect(inbox.activities.count == 30)
    }

    @Test func remembersAThreadThatIsNeitherAPullRequestNorAnIssueAsHavingNothingToTellWithoutAsking() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.checkSuite, Fixture.thread(id: "1003", type: "Release", url: "https://api.github.com/repos/octo/app/releases/3")))
        _ = try await inbox.refresh()

        await inbox.describeThreads()

        #expect(server.requests.count == 1)
        #expect(inbox.activities["1002"] == .nothingToTell(asOf: Date(timeIntervalSince1970: 1_794_365_172)))
        #expect(inbox.activities["1003"] == .nothingToTell(asOf: Date(timeIntervalSince1970: 1_794_365_172)))
    }

    // Nothing about a merged or closed pull request or about an issue changes without new activity.
    @Test(arguments: [
        ("PullRequest", "MERGED"),
        ("PullRequest", "CLOSED"),
        ("Issue", "OPEN"),
    ])
    func asksNothingMoreAboutASettledThreadWithoutNewActivity(type: String, state: String) async throws {
        let inbox = makeInbox()
        let thread = Fixture.thread(id: "1001", type: type, url: "https://api.github.com/repos/octo/app/issues/9")
        server.reply(200, body: Fixture.page(thread))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.answer(type == "Issue" ? Fixture.issue(state: state) : Fixture.pullRequest(state: state)))
        await inbox.describeThreads()

        await inbox.describeThreads()

        #expect(server.requests.count == 2)
    }

    // Whether the viewer's review is awaited can change without the thread being updated.
    @Test(arguments: [false, true])
    func asksAgainAboutAnOpenOrDraftPullRequestWithoutNewActivity(isDraft: Bool) async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.answer(Fixture.pullRequest(isDraft: isDraft)))
        await inbox.describeThreads()

        server.reply(200, body: Fixture.answer(Fixture.pullRequest(isDraft: isDraft)))
        await inbox.describeThreads()

        #expect(server.requests.count == 3)
    }

    @Test func learnsThatTheViewersReviewIsNoLongerAwaitedWithoutNewActivity() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.answer(Fixture.pullRequest(awaiting: Fixture.user("octocat"))))
        await inbox.describeThreads()
        #expect(inbox.activities["1001"]?.awaitsYourReview == true)

        server.reply(200, body: Fixture.answer(Fixture.pullRequest()))
        await inbox.describeThreads()

        #expect(inbox.activities["1001"]?.awaitsYourReview == false)
    }

    @Test func learnsThatTheViewersReviewIsAwaitedOnceADraftIsReadyWithoutNewActivity() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.answer(Fixture.pullRequest(isDraft: true, awaiting: Fixture.user("octocat"))))
        await inbox.describeThreads()
        #expect(inbox.activities["1001"]?.awaitsYourReview == false)

        server.reply(200, body: Fixture.answer(Fixture.pullRequest(awaiting: Fixture.user("octocat"))))
        await inbox.describeThreads()

        #expect(inbox.activities["1001"]?.awaitsYourReview == true)
    }

    // Replacing it with its equal would count as a change, and the snapshot would be written again.
    @Test func leavesTheDescriptionAloneWhenAskingAgainTellsNothingNew() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.answer(Fixture.pullRequest()))
        await inbox.describeThreads()
        let changed = Mutex(false)
        withObservationTracking { _ = inbox.activities } onChange: { changed.withLock { $0 = true } }

        server.reply(200, body: Fixture.answer(Fixture.pullRequest()))
        await inbox.describeThreads()

        #expect(server.requests.count == 3)
        #expect(!changed.withLock { $0 })
    }

    @Test func describesAThreadAgainOnceItHasNewActivity() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.mergedByHubot)
        await inbox.describeThreads()

        server.reply(200, body: Fixture.page(Fixture.thread(id: "1001", updatedAt: "2026-11-11T03:00:00Z")))
        _ = try await inbox.refresh()
        server.reply(200, body: Fixture.answer(Fixture.pullRequest(state: "MERGED", items: Fixture.comment(by: "alice", at: "2026-11-11T03:00:00Z"))))
        await inbox.describeThreads()

        #expect(inbox.activities["1001"]?.event?.actor == "alice")
    }

    @Test func stopsDescribingWhenAQueryFailsWholeAndTakesItUpAgainLater() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Self.threads(30)))
        _ = try await inbox.refresh()
        server.reply(502)

        await inbox.describeThreads()

        #expect(server.requests.count == 2)
        #expect(inbox.activities.isEmpty)
        server.reply(200, body: Self.answer(describing: 25))
        server.reply(200, body: Self.answer(describing: 5))
        await inbox.describeThreads()
        #expect(inbox.activities.count == 30)
    }

    @Test func goesOnToTheNextQueryWhenSomeThreadsFailedAndAsksAboutThemAgainLater() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Self.threads(30)))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.answer(describing: 25, errors: [Fixture.error("FORBIDDEN", at: #"["t0"]"#)]))
        server.reply(200, body: Self.answer(describing: 5))

        await inbox.describeThreads()

        #expect(inbox.activities.count == 29)
        #expect(inbox.activities["1"] == nil)
        server.reply(200, body: Self.answer(describing: 1))
        await inbox.describeThreads()
        #expect(try variables(of: try #require(server.requests.last)).count == 3)
        #expect(inbox.activities["1"] != nil)
    }

    @Test func describesOnlyTheThreadsItIsAskedAbout() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.mergedByHubot)

        await inbox.describe([Fixture.notification(Fixture.thread(id: "2"))])

        #expect(inbox.activities.keys.sorted() == ["2"])
    }

    @Test func asksGitHubOnceAboutAThreadThatIsAskedAboutTwiceAtOnce() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        let gate = server.replyLater(200, body: Self.mergedByHubot)

        let first = Task { await inbox.describeThreads() }
        await server.waitForRequests(2)
        let second = Task { await inbox.describe([Fixture.notification(Fixture.pullRequest)]) }
        for _ in 1...10 { await Task.yield() }
        gate.open()
        await first.value
        await second.value

        #expect(server.requests.count == 2)
        #expect(inbox.activities["1001"]?.state == .merged)
    }

    @Test func asksNothingAboutAThreadDescribedElsewhereWhileAnEarlierQueryWasUnderway() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Self.threads(26)))
        _ = try await inbox.refresh()
        let gate = server.replyLater(200, body: Self.answer(describing: 25))
        server.reply(200, body: Self.answer(describing: 1))

        let listing = Task { await inbox.describeThreads() }
        await server.waitForRequests(2)
        await inbox.describe([Fixture.notification(Fixture.thread(id: "26"))])
        gate.open()
        await listing.value

        #expect(server.requests.count == 3)
        #expect(inbox.activities.count == 26)
    }

    @Test func anAnswerAboutOlderActivityThatArrivesLastDoesNotReplaceTheNewerOne() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        let newer = Fixture.notification(Fixture.thread(id: "1001", updatedAt: "2026-11-11T03:00:00Z"))
        let gate = server.replyLater(200, body: Self.mergedByHubot)
        server.reply(200, body: Fixture.answer(Fixture.pullRequest()))

        let older = Task { await inbox.describeThreads() }
        await server.waitForRequests(2)
        await inbox.describe([newer])
        gate.open()
        await older.value

        #expect(inbox.activities["1001"]?.asOf == newer.updatedAt)
        #expect(inbox.activities["1001"]?.state == .open)
    }

    @Test func offersADescriptionOnlyOfTheActivityItDescribes() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.mergedByHubot)
        await inbox.describeThreads()

        let described = Fixture.notification(Fixture.pullRequest)
        let newer = Fixture.notification(Fixture.thread(id: "1001", updatedAt: "2026-11-11T03:00:00Z"))

        #expect(inbox.activity(describing: described)?.state == .merged)
        #expect(inbox.activity(describing: newer) == nil)
    }

    @Test func aThreadReadWhileItIsBeingDescribedIsNoLongerUnread() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.pullRequest))
        _ = try await inbox.refresh()
        let notification = Fixture.notification(Fixture.pullRequest)
        let gate = server.replyLater(200, body: Self.mergedByHubot)
        server.reply(205)

        let describing = Task { await inbox.describe([notification]) }
        await server.waitForRequests(2)
        await inbox.markAsRead(notification)
        gate.open()
        await describing.value

        #expect(!inbox.isUnread(notification))
    }

    @Test func describingResumesAfterTheNextRefreshEvenWhenTheInboxHasNotChanged() async throws {
        let inbox = makeInbox()
        let describing = Task { await inbox.describeAfterEveryRefresh() }
        defer { describing.cancel() }
        server.reply(200, headers: ["ETag": #""a""#], body: Fixture.page(Fixture.pullRequest))
        server.reply(502)
        _ = try await inbox.refresh()
        await server.waitForRequests(2)

        server.reply(304)
        server.reply(200, body: Self.mergedByHubot)
        _ = try await inbox.refresh()
        // Bounded, so that a pass that never comes fails the test rather than hanging it.
        for _ in 1...1_000 where inbox.activities["1001"] == nil {
            await Task.yield()
        }

        #expect(inbox.activities["1001"]?.state == .merged)
    }

    // MARK: - Restoring the last launch

    private static func snapshot(_ threads: String..., activities: [GitHub.Notification.ID: GitHub.Activity] = [:]) -> Snapshot {
        Snapshot(notifications: threads.map(Fixture.notification), activities: activities)
    }

    @Test func showsTheRestoredThreadsAndTheirBadgeBeforeGitHubAnswers() {
        let inbox = makeInbox()

        inbox.restore(Self.snapshot(Fixture.thread(id: "1"), Fixture.thread(id: "2")))

        #expect(inbox.notifications.map(\.id) == ["1", "2"])
        #expect(inbox.badgeLabel == "2")
        #expect(!inbox.isLoaded)
    }

    @Test func replacesTheRestoredThreadsOnlyOnceEveryPageHasArrived() async throws {
        let inbox = makeInbox()
        inbox.restore(Self.snapshot(Fixture.thread(id: "1"), Fixture.thread(id: "2"), Fixture.thread(id: "3")))
        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "4")))
        let gate = server.replyLater(200, body: Fixture.page(Fixture.thread(id: "1")))

        let refreshing = Task { try await inbox.refresh() }
        await server.waitForRequests(2)

        #expect(inbox.notifications.map(\.id) == ["1", "2", "3"])
        gate.open()
        _ = try await refreshing.value
        #expect(inbox.notifications.map(\.id) == ["4", "1"])
    }

    @Test func announcesNothingOnTheFirstRefreshAfterRestoring() async throws {
        let inbox = makeInbox()
        inbox.restore(Self.snapshot(Fixture.thread(id: "1")))
        server.reply(200, body: Fixture.page(Fixture.thread(id: "2"), Fixture.thread(id: "1", updatedAt: "2026-11-11T03:00:00Z")))

        let refresh = try await inbox.refresh()

        #expect(refresh.news.isEmpty)
    }

    @Test func withdrawsNoDeliveredNotificationOnTheStrengthOfRestoredThreads() {
        let inbox = makeInbox()

        inbox.restore(Self.snapshot(Fixture.thread(id: "1")))

        #expect(inbox.staleDeliveries([.init(threadID: "2", login: "octo")], for: "octo").isEmpty)
    }

    @Test func asksNothingAboutAThreadTheRestoredActivityStillDescribes() async {
        let inbox = makeInbox()
        let activity = GitHub.Activity(asOf: Date(timeIntervalSince1970: 1_794_365_172), state: .merged, event: nil, awaitsYourReview: false)

        inbox.restore(Self.snapshot(Fixture.pullRequest, activities: ["1001": activity]))
        await inbox.describeThreads()

        #expect(server.requests.isEmpty)
        #expect(inbox.activities["1001"] == activity)
    }

    @Test func asksAgainAboutARestoredOpenPullRequest() async {
        let inbox = makeInbox()
        let activity = GitHub.Activity(asOf: Date(timeIntervalSince1970: 1_794_365_172), state: .open, event: nil, awaitsYourReview: true)
        inbox.restore(Self.snapshot(Fixture.pullRequest, activities: ["1001": activity]))
        server.reply(200, body: Fixture.answer(Fixture.pullRequest()))

        await inbox.describeThreads()

        #expect(inbox.activities["1001"]?.awaitsYourReview == false)
    }

    @Test func offersNothingToSaveUntilLoaded() {
        let inbox = makeInbox()

        inbox.restore(Self.snapshot(Fixture.thread(id: "1")))

        #expect(inbox.snapshot == nil)
    }

    @Test func savesTheLoadedThreadsWithTheActivityOfOnlyThoseStillUnread() async throws {
        let inbox = makeInbox()
        server.reply(200, body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        _ = try await inbox.refresh()
        server.reply(200, body: Self.answer(describing: 2))
        await inbox.describeThreads()

        server.reply(205)
        await inbox.markAsRead(Fixture.notification(Fixture.thread(id: "1")))

        let snapshot = try #require(inbox.snapshot)
        #expect(snapshot.notifications.map(\.id) == ["2"])
        #expect(snapshot.activities.keys.sorted() == ["2"])
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

