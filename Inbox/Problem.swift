import Foundation

struct Problem {
    let title: LocalizedStringResource
    let replacesList: Bool
    let offersTryAgain: Bool
    private let cause: LocalizedStringResource
    private let recovery: LocalizedStringResource?

    var refreshMessage: LocalizedStringResource {
        recovery.map { LocalizedStringResource("\(cause) \($0)", comment: "What went wrong, then how Inbox recovers") } ?? cause
    }

    // Only refreshes recover on their own; nothing repeats a failed open or mark-as-read.
    var actionMessage: LocalizedStringResource {
        "\(cause) The notification is still unread."
    }

    init(_ error: any Error) {
        switch error {
        case GitHubCLI.Problem.notInstalled:
            self.init(
                title: "GitHub CLI Not Found",
                cause: "Install GitHub CLI with Homebrew (brew install gh), then sign in with gh auth login.",
                replacesList: true
            )
        case GitHubCLI.Problem.notLoggedIn, GitHub.Failure.unauthorized:
            self.init(
                title: "Sign In to GitHub CLI",
                cause: "Run gh auth login in Terminal.",
                recovery: "Inbox picks up the account within a minute.",
                replacesList: true
            )
        case let GitHubCLI.Problem.failed(output):
            self.init(title: "GitHub CLI Failed", cause: .verbatim(output), replacesList: true)
        case let GitHub.Failure.rateLimited(until):
            self.init(
                title: "GitHub Is Limiting Requests",
                cause: "GitHub asked Inbox to wait until \(until, format: Date.FormatStyle(date: .omitted, time: .shortened)).",
                recovery: "Inbox will check again then."
            )
        case GitHub.Failure.suspended:
            self.init(
                title: "GitHub Is Limiting Requests",
                cause: "GitHub keeps limiting requests, so Inbox stopped checking.",
                offersTryAgain: true
            )
        case is Inbox.BrowserDidNotOpen:
            self.init(title: "Couldn’t Open the Browser", cause: "Check the default web browser in System Settings.")
        case let GitHub.Failure.forbidden(message):
            self.init(title: "GitHub Refused the Request", cause: .verbatim(message))
        case is GitHub.Failure:
            self.init(title: "GitHub Isn’t Responding", cause: "GitHub returned an error.", recovery: "Inbox will try again shortly.")
        default:
            self.init(
                title: "Can’t Reach GitHub",
                cause: "Check your internet connection.",
                recovery: "Inbox will try again when the connection is back."
            )
        }
    }

    private init(title: LocalizedStringResource, cause: LocalizedStringResource, recovery: LocalizedStringResource? = nil, replacesList: Bool = false, offersTryAgain: Bool = false) {
        self.title = title
        self.cause = cause
        self.recovery = recovery
        self.replacesList = replacesList
        self.offersTryAgain = offersTryAgain
    }
}
