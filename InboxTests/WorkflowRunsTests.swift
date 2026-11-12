import Foundation
import Testing
@testable import Inbox

struct WorkflowRunsTests {
    private func query(ofRunsFor title: String, type: String = "CheckSuite") -> String? {
        let notification = Fixture.notification(Fixture.thread(id: "1", title: title, type: type, url: nil, latestCommentURL: nil))
        guard let page = notification.workflowRunsPage else { return nil }
        #expect(page.absoluteString.hasPrefix("https://github.com/octo/app/actions?"))
        return URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
    }

    @Test func searchesTheRunsOfTheWorkflowOnTheBranch() {
        #expect(query(ofRunsFor: "TeamSpace - API CI workflow run failed for fix/turn-settlement branch")
            == #"workflow:"TeamSpace - API CI" branch:fix/turn-settlement"#)
    }

    @Test(arguments: ["failed", "failed at startup", "succeeded", "cancelled", "timed out"])
    func doesNotNarrowByTheResultBecauseARerunCanChangeIt(result: String) {
        #expect(query(ofRunsFor: "CI workflow run \(result) for main branch") == #"workflow:"CI" branch:main"#)
    }

    @Test func searchesAcrossAttemptsOfTheSameRun() {
        #expect(query(ofRunsFor: "Agent Foundation - CI workflow run, Attempt #2 failed for develop branch")
            == #"workflow:"Agent Foundation - CI" branch:develop"#)
    }

    @Test func hasNoPageForATitleInAnotherShape() {
        #expect(query(ofRunsFor: "CI failed") == nil)
    }

    @Test func hasNoPageForThreadsOtherThanCheckSuites() {
        #expect(query(ofRunsFor: "CI workflow run failed for main branch", type: "PullRequest") == nil)
    }
}
