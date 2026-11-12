import Testing
@testable import Inbox

struct NotificationDisplayTests {
    @Test(arguments: [
        ("review_requested", "Review requested"),
        ("mention", "Mentioned"),
        ("team_mention", "Team mentioned"),
        ("assign", "Assigned"),
        ("author", "You created this"),
        ("comment", "You commented"),
        ("state_change", "You changed the state"),
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
        #expect(GitHub.Notification.describe(reason: reason) == description)
    }

    @Test func spellsOutAReasonGitHubAddsLater() {
        #expect(GitHub.Notification.describe(reason: "some_new_reason") == "Some new reason")
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
}
