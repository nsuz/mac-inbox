import Foundation
import Testing
@testable import Inbox

struct NotificationDisplayTests {
    @Test(arguments: [
        ("review_requested", "Review requested"),
        ("mention", "Mentioned"),
        ("team_mention", "Team mentioned"),
        ("assign", "Assigned"),
        ("comment", "You took part"),
        ("state_change", "You took part"),
        ("manual", "Subscribed"),
        ("subscribed", "Watching"),
        ("ci_activity", "Workflow run"),
        ("approval_requested", "Deployment approval requested"),
        ("security_alert", "Security alert"),
        ("security_advisory_credit", "Advisory credit"),
        ("invitation", "Invitation"),
        ("member_feature_requested", "Feature requested"),
        ("agent_session_finished", "Copilot session finished"),
    ])
    func explainsWhyAThreadIsInTheInbox(reason: String, description: String) {
        #expect(GitHub.Notification.describe(reason: reason, type: "PullRequest") == description)
    }

    // Read as how the thread stands to the viewer, not as something that just happened.
    @Test(arguments: [
        ("PullRequest", "Your pull request"),
        ("Issue", "Your issue"),
        ("Discussion", "Your discussion"),
        ("Release", "Yours"),
    ])
    func callsAThreadTheViewerStartedTheirs(type: String, description: String) {
        #expect(GitHub.Notification.describe(reason: "author", type: type) == description)
    }

    @Test func spellsOutAReasonGitHubAddsLater() {
        #expect(GitHub.Notification.describe(reason: "some_new_reason", type: "PullRequest") == "Some new reason")
    }

    @Test(arguments: [
        ("PullRequest", "arrow.triangle.pull"),
        ("Issue", "smallcircle.filled.circle"),
        ("Discussion", "bubble.left.and.bubble.right"),
        ("Release", "tag"),
        ("CheckSuite", "gearshape"),
        ("WorkflowRun", "gearshape"),
        ("RepositoryVulnerabilityAlert", "shield.lefthalf.filled"),
        ("RepositoryDependabotAlertsThread", "shield.lefthalf.filled"),
        ("RepositoryInvitation", "person.badge.plus"),
        ("SomethingNew", "bell"),
    ])
    func picksASymbolForEachKindOfThread(type: String, symbol: String) {
        #expect(GitHub.Notification.symbol(for: type) == symbol)
    }

    @Test(arguments: [
        ("PullRequest", "Pull request"),
        ("RepositoryDependabotAlertsThread", "Repository dependabot alerts thread"),
        ("Issue", "Issue"),
    ])
    func namesTheKindOfThreadInWords(type: String, name: String) {
        #expect(GitHub.Notification.describe(type: type) == name)
    }

    @Test(arguments: [
        ("PullRequest", GitHub.SubjectState.open, "arrow.triangle.pull"),
        ("PullRequest", .draft, "arrow.triangle.pull"),
        ("PullRequest", .merged, "arrow.triangle.merge"),
        ("PullRequest", .closed, "arrow.triangle.pull"),
        ("Issue", .open, "smallcircle.filled.circle"),
        ("Issue", .completed, "checkmark.circle"),
        ("Issue", .notPlanned, "slash.circle"),
        ("Issue", .duplicate, "slash.circle"),
    ])
    func picksASymbolForWhereTheSubjectStands(type: String, state: GitHub.SubjectState, symbol: String) {
        #expect(GitHub.Notification.symbol(for: type, state: state) == symbol)
    }

    @Test(arguments: [
        ("PullRequest", GitHub.SubjectState?.none, "Pull request"),
        ("PullRequest", .open, "Open pull request"),
        ("PullRequest", .draft, "Draft pull request"),
        ("PullRequest", .merged, "Merged pull request"),
        ("PullRequest", .closed, "Closed pull request"),
        ("Issue", .open, "Open issue"),
        ("Issue", .completed, "Issue closed as completed"),
        ("Issue", .notPlanned, "Issue closed as not planned"),
        ("Issue", .duplicate, "Issue closed as duplicate"),
        ("CheckSuite", nil, "Check suite"),
    ])
    func namesWhatTheSymbolStandsFor(type: String, state: GitHub.SubjectState?, name: String) {
        #expect(GitHub.Notification.describe(type: type, state: state) == name)
    }

    // MARK: - Events

    @Test(arguments: [
        (GitHub.Event.Action.commented, "alice commented"),
        (.approved, "alice approved"),
        (.requestedChanges, "alice requested changes"),
        (.reviewed, "alice reviewed"),
        (.merged, "alice merged"),
        (.closed, "alice closed"),
        (.reopened, "alice reopened"),
        (.markedReadyForReview, "alice marked this ready for review"),
    ])
    func saysWhoDidWhat(action: GitHub.Event.Action, phrase: String) {
        #expect(GitHub.Event(action: action, actor: "alice", date: .now, url: nil, text: nil).phrase == phrase)
    }

    @Test func namesSomeoneWhoseAccountIsGoneAsGitHubDoes() {
        #expect(GitHub.Event(action: .commented, actor: nil, date: .now, url: nil, text: nil).phrase == "ghost commented")
    }

    private static let lastRead = Date(timeIntervalSince1970: 1_794_362_400)

    private static func activity(eventAt date: Date) -> GitHub.Activity {
        GitHub.Activity(asOf: date, state: nil, event: GitHub.Event(action: .approved, actor: "hubot", date: date, url: nil, text: nil))
    }

    @Test func tellsOfAnEventSinceTheThreadWasLastRead() {
        #expect(Self.activity(eventAt: Self.lastRead + 60).unreadEvent(lastReadAt: Self.lastRead)?.actor == "hubot")
    }

    @Test func keepsQuietAboutAnEventAlreadyRead() {
        #expect(Self.activity(eventAt: Self.lastRead - 60).unreadEvent(lastReadAt: Self.lastRead) == nil)
    }

    @Test func tellsOfTheEventOnAThreadNeverRead() {
        #expect(Self.activity(eventAt: Self.lastRead).unreadEvent(lastReadAt: nil)?.actor == "hubot")
    }
}
