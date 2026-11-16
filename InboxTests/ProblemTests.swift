import Foundation
import Testing
@testable import Inbox

struct ProblemTests {
    private nonisolated static let until = Date(timeIntervalSince1970: 1_794_365_172)
    private nonisolated static let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .english))

    @Test func aMissingGitHubCLIReplacesTheListWithHowToInstallIt() {
        let problem = Problem(GitHubCLI.Problem.notInstalled)

        #expect(problem.title.english == "GitHub CLI Not Found")
        #expect(problem.refreshMessage.english == "Install GitHub CLI with Homebrew (brew install gh), then sign in with gh auth login.")
        #expect(problem.replacesList)
        #expect(!problem.offersTryAgain)
    }

    @Test(arguments: [GitHubCLI.Problem.notLoggedIn as any Error, GitHub.Failure.unauthorized])
    func aMissingOrRejectedSignInAsksToSignInAgain(error: any Error) {
        let problem = Problem(error)

        #expect(problem.title.english == "Sign In to GitHub CLI")
        #expect(problem.refreshMessage.english == "Run gh auth login in Terminal. Inbox picks up the account within a minute.")
        #expect(problem.replacesList)
    }

    @Test func aFailingGitHubCLIShowsWhatItSaid() {
        let problem = Problem(GitHubCLI.Problem.failed("error connecting to keyring"))

        #expect(problem.title.english == "GitHub CLI Failed")
        #expect(problem.refreshMessage.english == "error connecting to keyring")
        #expect(problem.replacesList)
    }

    // MARK: - While refreshing: the list stays and Inbox says how it recovers on its own

    @Test func aRateLimitSaysWhenInboxWillCheckAgain() {
        let problem = Problem(GitHub.Failure.rateLimited(until: Self.until))

        #expect(problem.title.english == "GitHub Is Limiting Requests")
        #expect(problem.refreshMessage.english == "GitHub asked Inbox to wait until \(Self.time). Inbox will check again then.")
        #expect(!problem.replacesList)
        #expect(!problem.offersTryAgain)
    }

    @Test func aSuspensionWaitsForThePersonToTryAgain() {
        let problem = Problem(GitHub.Failure.suspended)

        #expect(problem.title.english == "GitHub Is Limiting Requests")
        #expect(problem.refreshMessage.english == "GitHub keeps limiting requests, so Inbox stopped checking.")
        #expect(problem.offersTryAgain)
    }

    @Test func anUnreachableNetworkSaysInboxRetriesWhenTheConnectionIsBack() {
        let problem = Problem(URLError(.notConnectedToInternet))

        #expect(problem.title.english == "Can’t Reach GitHub")
        #expect(problem.refreshMessage.english == "Check your internet connection. Inbox will try again when the connection is back.")
        #expect(!problem.replacesList)
    }

    @Test func aServerErrorSaysInboxRetriesShortly() {
        let problem = Problem(GitHub.Failure.server(status: 502))

        #expect(problem.title.english == "GitHub Isn’t Responding")
        #expect(problem.refreshMessage.english == "GitHub returned an error. Inbox will try again shortly.")
    }

    @Test func aForbiddenRequestShowsWhatGitHubSaid() {
        let problem = Problem(GitHub.Failure.forbidden("Resource protected by organization SAML enforcement."))

        #expect(problem.title.english == "GitHub Refused the Request")
        #expect(problem.refreshMessage.english == "Resource protected by organization SAML enforcement.")
    }

    // MARK: - After an action: nothing retries it, so the thread stays unread

    @Test(arguments: [
        (GitHub.Failure.server(status: 502) as any Error, "GitHub returned an error."),
        (URLError(.notConnectedToInternet), "Check your internet connection."),
        (GitHub.Failure.rateLimited(until: until), "GitHub asked Inbox to wait until \(time)."),
    ])
    func aFailedActionLeavesTheThreadUnreadWithoutPromisingARetry(error: any Error, cause: String) {
        #expect(Problem(error).actionMessage.english == "\(cause) The notification is still unread.")
    }

    @Test func aBrowserThatDidNotOpenTheLinkPointsToTheDefaultBrowserSetting() {
        let problem = Problem(Inbox.BrowserDidNotOpen())

        #expect(problem.title.english == "Couldn’t Open the Browser")
        #expect(problem.actionMessage.english == "Check the default web browser in System Settings. The notification is still unread.")
    }

    // MARK: - In Japanese

    @Test func joinsTheCauseAndTheRecoveryAsJapaneseSentencesAreJoined() {
        #expect(Problem(GitHub.Failure.server(status: 502)).refreshMessage.japanese == "GitHub がエラーを返しました。Inbox はまもなくもう一度試します。")
    }

    @Test func saysInJapaneseThatAThreadIsStillUnread() {
        #expect(Problem(GitHub.Failure.server(status: 502)).actionMessage.japanese == "GitHub がエラーを返しました。この通知は未読のままです。")
    }

    @Test func showsWhatGitHubSaidAsItSaidIt() {
        #expect(Problem(GitHub.Failure.forbidden("Resource protected by organization SAML enforcement.")).refreshMessage.japanese
            == "Resource protected by organization SAML enforcement.")
    }
}
