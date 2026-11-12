import Foundation
import Testing
@testable import Inbox

struct ProblemTests {
    private nonisolated static let until = Date(timeIntervalSince1970: 1_794_365_172)
    private nonisolated static let time = until.formatted(date: .omitted, time: .shortened)

    @Test func aMissingGitHubCLIReplacesTheListWithHowToInstallIt() {
        let problem = Problem(GitHubCLI.Problem.notInstalled)

        #expect(problem.title == "GitHub CLI Not Found")
        #expect(problem.refreshMessage == "Install GitHub CLI with Homebrew (brew install gh), then sign in with gh auth login.")
        #expect(problem.replacesList)
        #expect(!problem.offersTryAgain)
    }

    @Test(arguments: [GitHubCLI.Problem.notLoggedIn as any Error, GitHub.Failure.unauthorized])
    func aMissingOrRejectedSignInAsksToSignInAgain(error: any Error) {
        let problem = Problem(error)

        #expect(problem.title == "Sign In to GitHub CLI")
        #expect(problem.refreshMessage == "Run gh auth login in Terminal. Inbox picks up the account within a minute.")
        #expect(problem.replacesList)
    }

    @Test func aFailingGitHubCLIShowsWhatItSaid() {
        let problem = Problem(GitHubCLI.Problem.failed("error connecting to keyring"))

        #expect(problem.title == "GitHub CLI Failed")
        #expect(problem.refreshMessage == "error connecting to keyring")
        #expect(problem.replacesList)
    }

    // MARK: - While refreshing: the list stays and Inbox says how it recovers on its own

    @Test func aRateLimitSaysWhenInboxWillCheckAgain() {
        let problem = Problem(GitHub.Failure.rateLimited(until: Self.until))

        #expect(problem.title == "GitHub Is Limiting Requests")
        #expect(problem.refreshMessage == "GitHub asked Inbox to wait until \(Self.time). Inbox will check again then.")
        #expect(!problem.replacesList)
        #expect(!problem.offersTryAgain)
    }

    @Test func aSuspensionWaitsForThePersonToTryAgain() {
        let problem = Problem(GitHub.Failure.suspended)

        #expect(problem.title == "GitHub Is Limiting Requests")
        #expect(problem.refreshMessage == "GitHub keeps limiting requests, so Inbox stopped checking.")
        #expect(problem.offersTryAgain)
    }

    @Test func anUnreachableNetworkSaysInboxRetriesWhenTheConnectionIsBack() {
        let problem = Problem(URLError(.notConnectedToInternet))

        #expect(problem.title == "Can’t Reach GitHub")
        #expect(problem.refreshMessage == "Check your internet connection. Inbox will try again when the connection is back.")
        #expect(!problem.replacesList)
    }

    @Test func aServerErrorSaysInboxRetriesShortly() {
        let problem = Problem(GitHub.Failure.server(status: 502))

        #expect(problem.title == "GitHub Isn’t Responding")
        #expect(problem.refreshMessage == "GitHub returned an error. Inbox will try again shortly.")
    }

    @Test func aForbiddenRequestShowsWhatGitHubSaid() {
        let problem = Problem(GitHub.Failure.forbidden("Resource protected by organization SAML enforcement."))

        #expect(problem.title == "GitHub Refused the Request")
        #expect(problem.refreshMessage == "Resource protected by organization SAML enforcement.")
    }

    // MARK: - After an action: nothing retries it, so the thread stays unread

    @Test(arguments: [
        (GitHub.Failure.server(status: 502) as any Error, "GitHub returned an error."),
        (URLError(.notConnectedToInternet), "Check your internet connection."),
        (GitHub.Failure.rateLimited(until: until), "GitHub asked Inbox to wait until \(time)."),
    ])
    func aFailedActionLeavesTheThreadUnreadWithoutPromisingARetry(error: any Error, cause: String) {
        #expect(Problem(error).actionMessage == "\(cause) The notification is still unread.")
    }

    @Test func aBrowserThatDidNotOpenTheLinkPointsToTheDefaultBrowserSetting() {
        let problem = Problem(Inbox.BrowserDidNotOpen())

        #expect(problem.title == "Couldn’t Open the Browser")
        #expect(problem.actionMessage == "Check the default web browser in System Settings. The notification is still unread.")
    }
}
