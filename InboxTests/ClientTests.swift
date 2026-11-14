import Foundation
import Testing
@testable import Inbox

struct ClientTests {
    private let server = FakeServer()
    private let clock = FakeWallClock()
    private let tokens = TokenSource()

    private func makeClient() -> GitHub.Client {
        GitHub.Client(token: tokens.next, send: server.send, now: clock.now)
    }

    // MARK: - Unread notifications

    @Test func sendsTheTokenAndTheAPIVersion() async throws {
        server.reply(200, body: Fixture.page())
        _ = try await makeClient().unread(ifNoneMatch: nil)

        let request = try #require(server.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/notifications?per_page=50")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func reportsNoChangeWhenTheETagStillMatches() async throws {
        server.reply(304, headers: ["X-Poll-Interval": "90"])

        let unread = try await makeClient().unread(ifNoneMatch: #""abc""#)

        #expect(unread == .notModified(pollInterval: .seconds(90)))
        #expect(server.requests.first?.value(forHTTPHeaderField: "If-None-Match") == #""abc""#)
    }

    @Test func collectsEveryPageAndKeepsTheFirstPagesETag() async throws {
        server.reply(200, headers: ["ETag": #""first""#, "Link": #"<https://api.github.com/notifications?per_page=50&page=2>; rel="next", <https://api.github.com/notifications?per_page=50&page=3>; rel="last""#],
                     body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        server.reply(200, headers: ["ETag": #""second""#],
                     body: Fixture.page(Fixture.thread(id: "2"), Fixture.thread(id: "3")))

        let unread = try await makeClient().unread(ifNoneMatch: nil)

        guard case let .modified(notifications, etag, _) = unread else {
            Issue.record("expected a modified inbox, got \(unread)")
            return
        }
        #expect(notifications.map(\.id) == ["1", "2", "3"])
        #expect(etag == #""first""#)
        #expect(server.requests.last?.url?.absoluteString == "https://api.github.com/notifications?per_page=50&page=2")
        #expect(server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func reportsWhatHasArrivedAfterEachPage() async throws {
        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#],
                     body: Fixture.page(Fixture.thread(id: "1"), Fixture.thread(id: "2")))
        server.reply(200, body: Fixture.page(Fixture.thread(id: "2"), Fixture.thread(id: "3")))
        var reports: [[String]] = []

        _ = try await makeClient().unread(ifNoneMatch: nil) { reports.append($0.map(\.id)) }

        #expect(reports == [["1", "2"], ["1", "2", "3"]])
    }

    @Test(arguments: [
        (["X-Poll-Interval": "120"], 120),
        (["X-Poll-Interval": "30"], 60),
        ([:], 60),
    ])
    func pollsNoMoreOftenThanGitHubAsksAndNeverUnderAMinute(headers: [String: String], seconds: Int) async throws {
        server.reply(200, headers: headers, body: Fixture.page())

        let unread = try await makeClient().unread(ifNoneMatch: nil)

        #expect(unread.pollInterval == .seconds(seconds))
    }

    @Test func failsWholeWhenALaterPageFails() async {
        server.reply(200, headers: ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#], body: Fixture.page(Fixture.thread(id: "1")))
        server.reply(502)

        await #expect(throws: GitHub.Failure.server(status: 502)) {
            try await makeClient().unread(ifNoneMatch: nil)
        }
    }

    // MARK: - Credentials

    @Test func fetchesTheTokenOnceAndReusesIt() async throws {
        let client = makeClient()
        server.reply(200, body: Fixture.page())
        server.reply(200, body: Fixture.page())

        _ = try await client.unread(ifNoneMatch: nil)
        _ = try await client.unread(ifNoneMatch: nil)

        #expect(tokens.issued == 1)
    }

    @Test func refetchesTheTokenOnceWhenGitHubRejectsIt() async throws {
        server.reply(401)
        server.reply(200, body: Fixture.page())

        _ = try await makeClient().unread(ifNoneMatch: nil)

        #expect(server.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test func givesUpWhenTheFreshTokenIsRejectedToo() async {
        server.reply(401)
        server.reply(401)

        await #expect(throws: GitHub.Failure.unauthorized) {
            try await makeClient().unread(ifNoneMatch: nil)
        }
        #expect(server.requests.count == 2)
    }

    // MARK: - Rate limits

    @Test func retryAfterStopsEveryCallUntilItHasPassed() async throws {
        let client = makeClient()
        server.reply(429, headers: ["Retry-After": "30"], body: #"{"message":"You have exceeded a secondary rate limit."}"#)

        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 30)) {
            try await client.unread(ifNoneMatch: nil)
        }
        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 30)) {
            try await client.markAsRead("1")
        }
        #expect(server.requests.count == 1)

        clock.advance(by: 30)
        server.reply(205)
        try await client.markAsRead("1")
        #expect(server.requests.count == 2)
    }

    @Test func anExhaustedPrimaryLimitStopsCallsUntilTheReset() async {
        let client = makeClient()
        let reset = clock.current + 600
        server.reply(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))],
                     body: #"{"message":"API rate limit exceeded"}"#)

        await #expect(throws: GitHub.Failure.rateLimited(until: reset)) {
            try await client.unread(ifNoneMatch: nil)
        }
        clock.advance(by: 599)
        await #expect(throws: GitHub.Failure.rateLimited(until: reset)) {
            try await client.htmlURL(of: URL(string: "https://api.github.com/repos/octo/app/pulls/42")!)
        }
        #expect(server.requests.count == 1)
    }

    @Test func repeatedSecondaryLimitsDoubleTheWaitAndThenStopRetrying() async {
        let client = makeClient()
        for seconds in [60.0, 120, 240, 480] {
            server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#)
            await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + seconds)) {
                try await client.unread(ifNoneMatch: nil)
            }
            clock.advance(by: seconds)
        }

        server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        await #expect(throws: GitHub.Failure.suspended) {
            try await client.unread(ifNoneMatch: nil)
        }
        clock.advance(by: 3600)
        await #expect(throws: GitHub.Failure.suspended) {
            try await client.markAsRead("1")
        }
        #expect(server.requests.count == 5)
    }

    @Test func resumingAfterASuspensionStillHonorsTheLastStopGitHubAskedFor() async {
        let client = makeClient()
        for _ in 1...4 {
            server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit."}"#)
            _ = try? await client.unread(ifNoneMatch: nil)
            clock.advance(by: 3600)
        }
        server.reply(429, headers: ["Retry-After": "600"], body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        _ = try? await client.unread(ifNoneMatch: nil)

        client.resume()

        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 600)) {
            try await client.unread(ifNoneMatch: nil)
        }
        #expect(server.requests.count == 5)
    }

    @Test func aRetryAfterARejectedTokenRespectsAStopThatBeganMeanwhile() async throws {
        let client = makeClient()
        let gate = server.replyLater(401)
        let listing = Task { try await client.unread(ifNoneMatch: nil) }
        await server.waitForRequests(1)

        server.reply(429, headers: ["Retry-After": "30"], body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        _ = try? await client.markAsRead("1")
        gate.open()

        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 30)) {
            try await listing.value
        }
        #expect(server.requests.count == 2)
    }

    @Test func resumingAfterASuspensionStartsCountingAgain() async throws {
        let client = makeClient()
        for _ in 1...5 {
            server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit."}"#)
            _ = try? await client.unread(ifNoneMatch: nil)
            clock.advance(by: 3600)
        }

        client.resume()
        server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit."}"#)

        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 60)) {
            try await client.unread(ifNoneMatch: nil)
        }
    }

    @Test func aSuccessResetsTheSecondaryLimitBackoff() async throws {
        let client = makeClient()
        server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        _ = try? await client.unread(ifNoneMatch: nil)
        clock.advance(by: 60)
        server.reply(304)
        _ = try await client.unread(ifNoneMatch: #""abc""#)

        server.reply(403, body: #"{"message":"You have exceeded a secondary rate limit."}"#)
        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 60)) {
            try await client.unread(ifNoneMatch: nil)
        }
    }

    @Test func aForbiddenResponseThatIsNotARateLimitDoesNotStopOtherCalls() async throws {
        let client = makeClient()
        server.reply(403, body: #"{"message":"Resource protected by organization SAML enforcement."}"#)

        await #expect(throws: GitHub.Failure.forbidden("Resource protected by organization SAML enforcement.")) {
            try await client.unread(ifNoneMatch: nil)
        }
        server.reply(205)
        try await client.markAsRead("1")
        #expect(server.requests.count == 2)
    }

    // GraphQL is counted apart from REST, and reports its exhausted limit with a 200.
    @Test func anExhaustedGraphQLLimitStopsOnlyDescribingUntilTheReset() async throws {
        let client = makeClient()
        let reset = clock.current + 600
        server.reply(200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))],
                     body: #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit already exceeded for user ID 1."}]}"#)

        await #expect(throws: GitHub.Failure.rateLimited(until: reset)) {
            try await client.describe([Fixture.notification(Fixture.pullRequest)])
        }
        await #expect(throws: GitHub.Failure.rateLimited(until: reset)) {
            try await client.describe([Fixture.notification(Fixture.pullRequest)])
        }
        #expect(server.requests.count == 1)

        server.reply(200, body: Fixture.page())
        server.reply(205)
        _ = try await client.unread(ifNoneMatch: nil)
        try await client.markAsRead("1")
        #expect(server.requests.count == 3)
    }

    @Test func anExhaustedRESTLimitDoesNotStopDescribing() async throws {
        let client = makeClient()
        server.reply(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(clock.current.timeIntervalSince1970) + 600)],
                     body: #"{"message":"API rate limit exceeded"}"#)
        _ = try? await client.unread(ifNoneMatch: nil)

        server.reply(200, body: Fixture.answer(Fixture.pullRequest()))
        let activities = try await client.describe([Fixture.notification(Fixture.pullRequest)])

        #expect(activities.count == 1)
    }

    // Secondary limits are shared between REST and GraphQL.
    @Test(arguments: [
        (403, #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#),
        (200, #"{"errors":[{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}]}"#),
    ])
    func aSecondaryLimitWhileDescribingStopsEveryCall(status: Int, body: String) async {
        let client = makeClient()
        server.reply(status, body: body)

        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 60)) {
            try await client.describe([Fixture.notification(Fixture.pullRequest)])
        }
        await #expect(throws: GitHub.Failure.rateLimited(until: clock.current + 60)) {
            try await client.unread(ifNoneMatch: nil)
        }
        #expect(server.requests.count == 1)
    }

    // MARK: - Threads

    @Test func marksAThreadAsRead() async throws {
        server.reply(205)

        try await makeClient().markAsRead("1001")

        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://api.github.com/notifications/threads/1001")
    }

    @Test func asksGitHubWhereAnAPIResourceLivesOnTheWeb() async throws {
        server.reply(200, body: #"{"id":7,"html_url":"https://github.com/octo/app/pull/42#issuecomment-7"}"#)

        let url = try await makeClient().htmlURL(of: URL(string: "https://api.github.com/repos/octo/app/issues/comments/7")!)

        #expect(url == URL(string: "https://github.com/octo/app/pull/42#issuecomment-7"))
        #expect(server.requests.first?.url?.absoluteString == "https://api.github.com/repos/octo/app/issues/comments/7")
    }

    @Test func reportsAResourceThatNoLongerExists() async {
        server.reply(404, body: #"{"message":"Not Found"}"#)

        await #expect(throws: GitHub.Failure.notFound) {
            try await makeClient().htmlURL(of: URL(string: "https://api.github.com/repos/octo/app/issues/comments/7")!)
        }
    }

    @Test func reportsAResourceThatHasBeenDeletedAsNoLongerExisting() async {
        server.reply(410, body: #"{"message":"This issue was deleted"}"#)

        await #expect(throws: GitHub.Failure.notFound) {
            try await makeClient().htmlURL(of: URL(string: "https://api.github.com/repos/octo/app/issues/42")!)
        }
    }

    // MARK: - Describing threads

    private let pullRequest = Fixture.notification(Fixture.pullRequest)
    private let issue = Fixture.notification(Fixture.thread(id: "1002", type: "Issue", url: "https://api.github.com/repos/octo/app/issues/9"))

    private func describe(_ threads: GitHub.Notification..., answer: String) async throws -> [GitHub.Notification.ID: GitHub.Activity] {
        server.reply(200, body: answer)
        return try await makeClient().describe(threads)
    }

    @Test func asksAboutEveryThreadInOneQueryByItsRepositoryAndNumber() async throws {
        _ = try await describe(pullRequest, issue, answer: Fixture.answer(Fixture.pullRequest(), Fixture.issue()))

        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        let body = try #require(try request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["variables"] as? NSDictionary == ["owner0": "octo", "name0": "app", "number0": 42, "owner1": "octo", "name1": "app", "number1": 9])
        let query = try #require(body["query"] as? String)
        #expect(query.contains("viewer { login }"))
        #expect(query.contains("t0: repository(owner: $owner0, name: $name0) { issueOrPullRequest(number: $number0)"))
        #expect(query.contains("t1: repository(owner: $owner1, name: $name1) { issueOrPullRequest(number: $number1)"))
        #expect(!query.contains("octo"))
    }

    @Test(arguments: [
        ("OPEN", false, GitHub.SubjectState.open),
        ("OPEN", true, .draft),
        ("MERGED", false, .merged),
        ("CLOSED", false, .closed),
    ])
    func tellsWhereAPullRequestStands(state: String, isDraft: Bool, expected: GitHub.SubjectState) async throws {
        let activities = try await describe(pullRequest, answer: Fixture.answer(Fixture.pullRequest(state: state, isDraft: isDraft)))

        #expect(activities[pullRequest.id] == GitHub.Activity(asOf: pullRequest.updatedAt, state: expected, event: nil))
    }

    // An issue closed before GitHub recorded reasons has none, and GitHub shows it as completed.
    @Test(arguments: [
        ("OPEN", nil, GitHub.SubjectState.open),
        ("OPEN", "REOPENED", .open),
        ("CLOSED", "COMPLETED", .completed),
        ("CLOSED", nil, .completed),
        ("CLOSED", "NOT_PLANNED", .notPlanned),
        ("CLOSED", "DUPLICATE", .duplicate),
    ])
    func tellsWhereAnIssueStands(state: String, stateReason: String?, expected: GitHub.SubjectState) async throws {
        let activities = try await describe(issue, answer: Fixture.answer(Fixture.issue(state: state, stateReason: stateReason)))

        #expect(activities[issue.id]?.state == expected)
    }

    @Test func tellsTheLatestThingSomeoneOtherThanTheViewerDid() async throws {
        let answer = Fixture.answer(viewer: "octocat", Fixture.pullRequest(items:
            Fixture.comment(by: "alice", at: "2026-11-11T02:00:00Z"),
            Fixture.review(by: "bob", state: "APPROVED", at: "2026-11-11T02:10:00Z", saying: "Ship it"),
            Fixture.comment(by: "octocat", at: "2026-11-11T02:20:00Z")
        ))

        let activities = try await describe(pullRequest, answer: answer)

        #expect(activities[pullRequest.id]?.event == GitHub.Event(
            action: .approved,
            actor: "bob",
            date: Fixture.date("2026-11-11T02:10:00Z"),
            url: URL(string: "https://github.com/octo/app/pull/42#event-bob"),
            text: "Ship it"
        ))
    }

    @Test func picksTheLatestByTimeWhateverOrderTheyComeIn() async throws {
        let answer = Fixture.answer(Fixture.pullRequest(items:
            Fixture.comment(by: "alice", at: "2026-11-11T02:30:00Z"),
            Fixture.comment(by: "bob", at: "2026-11-11T02:00:00Z")
        ))

        let activities = try await describe(pullRequest, answer: answer)

        #expect(activities[pullRequest.id]?.event?.actor == "alice")
    }

    @Test func tellsNothingThatHappenedWhenOnlyTheViewerActedOfLate() async throws {
        let answer = Fixture.answer(viewer: "octocat", Fixture.pullRequest(items:
            Fixture.comment(by: "octocat", at: "2026-11-11T02:00:00Z"),
            Fixture.event("ClosedEvent", by: "octocat", at: "2026-11-11T02:10:00Z")
        ))

        let activities = try await describe(pullRequest, answer: answer)

        #expect(activities[pullRequest.id] == GitHub.Activity(asOf: pullRequest.updatedAt, state: .open, event: nil))
    }

    // The two come at the same second, in whichever order.
    @Test(arguments: [
        ["MergedEvent", "ClosedEvent"],
        ["ClosedEvent", "MergedEvent"],
    ])
    func countsNoClosingOfAMergedPullRequestApartFromTheMerge(order: [String]) async throws {
        let answer = Fixture.answer(Fixture.pullRequest(state: "MERGED", items:
            Fixture.review(by: "alice", state: "APPROVED", at: "2026-11-11T02:00:00Z"),
            Fixture.event(order[0], by: "bob", at: "2026-11-11T02:10:00Z"),
            Fixture.event(order[1], by: "bob", at: "2026-11-11T02:10:00Z")
        ))

        let activities = try await describe(pullRequest, answer: answer)

        #expect(activities[pullRequest.id]?.event?.action == .merged)
    }

    @Test func namesABotAsGitHubShowsIt() async throws {
        let answer = Fixture.answer(Fixture.pullRequest(items: Fixture.review(by: "claude", as: "Bot", state: "COMMENTED", at: "2026-11-11T02:00:00Z")))

        let activities = try await describe(pullRequest, answer: answer)

        #expect(activities[pullRequest.id]?.event?.actor == "claude[bot]")
    }

    @Test func tellsWhatSomeoneWhoseAccountIsGoneDid() async throws {
        let answer = Fixture.answer(Fixture.issue(items: Fixture.comment(by: nil, at: "2026-11-11T02:00:00Z")))

        let activities = try await describe(issue, answer: answer)

        let event = try #require(activities[issue.id]?.event)
        #expect(event.action == .commented)
        #expect(event.actor == nil)
    }

    @Test(arguments: [
        (Fixture.comment(by: "alice", at: "2026-11-11T02:00:00Z"), GitHub.Event.Action.commented),
        (Fixture.review(by: "alice", state: "APPROVED", at: "2026-11-11T02:00:00Z"), .approved),
        (Fixture.review(by: "alice", state: "CHANGES_REQUESTED", at: "2026-11-11T02:00:00Z"), .requestedChanges),
        (Fixture.review(by: "alice", state: "COMMENTED", at: "2026-11-11T02:00:00Z"), .reviewed),
        (Fixture.review(by: "alice", state: "DISMISSED", at: "2026-11-11T02:00:00Z"), .reviewed),
        (Fixture.event("MergedEvent", by: "alice", at: "2026-11-11T02:00:00Z"), .merged),
        (Fixture.event("ClosedEvent", by: "alice", at: "2026-11-11T02:00:00Z"), .closed),
        (Fixture.event("ReopenedEvent", by: "alice", at: "2026-11-11T02:00:00Z"), .reopened),
        (Fixture.event("ReadyForReviewEvent", by: "alice", at: "2026-11-11T02:00:00Z"), .markedReadyForReview),
    ])
    func tellsEachKindOfThingSomeoneDid(item: String, action: GitHub.Event.Action) async throws {
        let activities = try await describe(pullRequest, answer: Fixture.answer(Fixture.pullRequest(items: item)))

        #expect(activities[pullRequest.id]?.event?.action == action)
    }

    @Test func keepsTheWordsOfACommentButHasNoneForAnEvent() async throws {
        let commented = try await describe(issue, answer: Fixture.answer(Fixture.issue(items: Fixture.comment(by: "alice", at: "2026-11-11T02:00:00Z", saying: "Looks good"))))
        let closed = try await describe(issue, answer: Fixture.answer(Fixture.issue(items: Fixture.event("ClosedEvent", by: "alice", at: "2026-11-11T02:00:00Z"))))

        #expect(commented[issue.id]?.event?.text == "Looks good")
        #expect(closed[issue.id]?.event?.text == nil)
    }

    // A missing repository comes back as null in its place, a missing subject as null inside it.
    @Test(arguments: [
        (nil, #"["t1"]"#),
        ("null", #"["t1","issueOrPullRequest"]"#),
    ])
    func remembersAThreadThatIsGoneAsHavingNothingToTell(subject: String?, path: String) async throws {
        let answer = Fixture.answer(Fixture.pullRequest(), subject, errors: Fixture.error("NOT_FOUND", at: path))

        let activities = try await describe(pullRequest, issue, answer: answer)

        #expect(activities[pullRequest.id]?.state == .open)
        #expect(activities[issue.id] == GitHub.Activity(asOf: issue.updatedAt, state: nil, event: nil))
    }

    @Test func leavesAThreadUndescribedWhenItFailsForAnyOtherReason() async throws {
        let answer = Fixture.answer(Fixture.pullRequest(), nil, errors: Fixture.error("FORBIDDEN", at: #"["t1"]"#))

        let activities = try await describe(pullRequest, issue, answer: answer)

        #expect(activities.keys.sorted() == [pullRequest.id])
    }

    @Test func leavesAThreadUndescribedWhenOnlyPartOfItFailed() async throws {
        let answer = Fixture.answer(
            #"{"__typename":"PullRequest","pullRequestState":"OPEN","isDraft":false,"timelineItems":null}"#,
            Fixture.issue(),
            errors: Fixture.error("SERVICE_UNAVAILABLE", at: #"["t0","issueOrPullRequest","timelineItems"]"#)
        )

        let activities = try await describe(pullRequest, issue, answer: answer)

        #expect(activities.keys.sorted() == [issue.id])
    }

    @Test(arguments: [
        (200, #"{"errors":[{"message":"Parse error on \"}\" (RCURLY) at [1, 2]"}]}"#),
        (502, ""),
    ])
    func failsWholeWhenGitHubAnswersNoneOfTheQuery(status: Int, body: String) async {
        server.reply(status, body: body)

        await #expect(throws: (any Error).self) {
            try await makeClient().describe([pullRequest])
        }
    }
}

extension Fixture {
    static func date(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }

    // What GraphQL answers about t0, t1, … in the order asked. A nil subject stands for a
    // repository that came back as null.
    static func answer(viewer: String = "octocat", _ subjects: String?..., errors: String...) -> String {
        answer(viewer: viewer, subjects: subjects, errors: errors)
    }

    static func answer(viewer: String = "octocat", subjects: [String?], errors: [String] = []) -> String {
        let fields = subjects.enumerated().map { index, subject in
            #","t\#(index)":"# + (subject.map { #"{"issueOrPullRequest":\#($0)}"# } ?? "null")
        }
        let errors = errors.isEmpty ? "" : #","errors":[\#(errors.joined(separator: ","))]"#
        return #"{"data":{"viewer":{"login":"\#(viewer)"}\#(fields.joined())}\#(errors)}"#
    }

    static func pullRequest(state: String = "OPEN", isDraft: Bool = false, items: String...) -> String {
        #"{"__typename":"PullRequest","pullRequestState":"\#(state)","isDraft":\#(isDraft),"timelineItems":{"nodes":[\#(items.joined(separator: ","))]}}"#
    }

    static func issue(state: String = "OPEN", stateReason: String? = nil, items: String...) -> String {
        let reason = stateReason.map { #""\#($0)""# } ?? "null"
        return #"{"__typename":"Issue","issueState":"\#(state)","stateReason":\#(reason),"timelineItems":{"nodes":[\#(items.joined(separator: ","))]}}"#
    }

    nonisolated static func comment(by login: String?, as type: String = "User", at time: String, saying text: String = "") -> String {
        #"{"__typename":"IssueComment","author":\#(actor(login, type)),"createdAt":"\#(time)","bodyText":"\#(text)","url":"https://github.com/octo/app/pull/42#event-\#(login ?? "ghost")"}"#
    }

    nonisolated static func review(by login: String, as type: String = "User", state: String, at time: String, saying text: String = "") -> String {
        #"{"__typename":"PullRequestReview","author":\#(actor(login, type)),"submittedAt":"\#(time)","state":"\#(state)","bodyText":"\#(text)","url":"https://github.com/octo/app/pull/42#event-\#(login)"}"#
    }

    nonisolated static func event(_ type: String, by login: String, at time: String) -> String {
        #"{"__typename":"\#(type)","actor":\#(actor(login, "User")),"createdAt":"\#(time)","url":"https://github.com/octo/app/pull/42#event-\#(login)"}"#
    }

    static func error(_ type: String, at path: String) -> String {
        #"{"type":"\#(type)","path":\#(path),"message":"Something went wrong"}"#
    }

    nonisolated private static func actor(_ login: String?, _ type: String) -> String {
        login.map { #"{"__typename":"\#(type)","login":"\#($0)"}"# } ?? "null"
    }
}

final class FakeServer {
    private struct Reply {
        let status: Int
        let headers: [String: String]
        let body: String
        let gate: Gate?
    }

    final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }
    }

    private var replies: [Reply] = []
    private(set) var requests: [URLRequest] = []

    func reply(_ status: Int, headers: [String: String] = [:], body: String = "") {
        replies.append(Reply(status: status, headers: headers, body: body, gate: nil))
    }

    func replyLater(_ status: Int, headers: [String: String] = [:], body: String = "") -> Gate {
        let gate = Gate()
        replies.append(Reply(status: status, headers: headers, body: body, gate: gate))
        return gate
    }

    func waitForRequests(_ count: Int) async {
        while requests.count < count {
            await Task.yield()
        }
    }

    struct UnexpectedRequest: Error {}

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("unexpected request: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
            throw UnexpectedRequest()
        }
        let reply = replies.removeFirst()
        await reply.gate?.wait()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

final class FakeWallClock {
    private(set) var current = Date(timeIntervalSince1970: 1_794_365_172)

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current += seconds
    }
}

final class TokenSource {
    private(set) var issued = 0

    func next() async throws -> String {
        issued += 1
        return "token-\(issued)"
    }
}
