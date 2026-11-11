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
