import Foundation
import Testing
@testable import Inbox

struct NotificationTests {
    @Test func decodesAPullRequestThread() throws {
        let notification = try GitHub.decoder.decode(GitHub.Notification.self, from: Data(Fixture.pullRequest.utf8))

        #expect(notification.id == "1001")
        #expect(notification.reason == "review_requested")
        #expect(notification.updatedAt == Date(timeIntervalSince1970: 1_794_365_172))
        #expect(notification.subject.title == "Fix popup position")
        #expect(notification.subject.type == "PullRequest")
        #expect(notification.subject.url == URL(string: "https://api.github.com/repos/octo/app/pulls/42"))
        #expect(notification.subject.latestCommentURL == URL(string: "https://api.github.com/repos/octo/app/issues/comments/7"))
        #expect(notification.repository.fullName == "octo/app")
        #expect(notification.repository.htmlURL == URL(string: "https://github.com/octo/app"))
    }

    @Test func decodesACheckSuiteThreadWhoseSubjectHasNoURLs() throws {
        let notification = try GitHub.decoder.decode(GitHub.Notification.self, from: Data(Fixture.checkSuite.utf8))

        #expect(notification.subject.type == "CheckSuite")
        #expect(notification.subject.url == nil)
        #expect(notification.subject.latestCommentURL == nil)
    }
}

enum Fixture {
    static func thread(
        id: String,
        reason: String = "review_requested",
        updatedAt: String = "2026-11-11T02:46:12Z",
        title: String = "Fix popup position",
        type: String = "PullRequest",
        url: String? = "https://api.github.com/repos/octo/app/pulls/42",
        latestCommentURL: String? = "https://api.github.com/repos/octo/app/issues/comments/7"
    ) -> String {
        func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return """
            {
              "id": "\(id)",
              "unread": true,
              "reason": "\(reason)",
              "updated_at": "\(updatedAt)",
              "last_read_at": null,
              "subject": {
                "title": "\(title)",
                "url": \(json(url)),
                "latest_comment_url": \(json(latestCommentURL)),
                "type": "\(type)"
              },
              "repository": {
                "id": 1,
                "name": "app",
                "full_name": "octo/app",
                "private": true,
                "html_url": "https://github.com/octo/app",
                "owner": { "login": "octo" }
              },
              "url": "https://api.github.com/notifications/threads/\(id)",
              "subscription_url": "https://api.github.com/notifications/threads/\(id)/subscription"
            }
            """
    }

    static let pullRequest = thread(id: "1001")
    static let checkSuite = thread(id: "1002", reason: "ci_activity", title: "CI failed", type: "CheckSuite", url: nil, latestCommentURL: nil)

    static func notification(_ thread: String) -> GitHub.Notification {
        try! GitHub.decoder.decode(GitHub.Notification.self, from: Data(thread.utf8))
    }

    static func page(_ threads: String...) -> String {
        "[" + threads.joined(separator: ",") + "]"
    }
}
