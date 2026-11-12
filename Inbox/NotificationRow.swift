import SwiftUI

struct NotificationRow: View {
    let notification: GitHub.Notification

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.subject.title)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(notification.repository.fullName)
                    Text("·")
                    Text(GitHub.Notification.describe(reason: notification.reason))
                    Spacer()
                    Text(notification.updatedAt, format: .relative(presentation: .named))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            Image(systemName: GitHub.Notification.symbol(for: notification.subject.type))
                .accessibilityLabel(GitHub.Notification.describe(type: notification.subject.type))
        }
        .padding(.vertical, 4)
    }
}

extension GitHub.Notification {
    static func describe(reason: String) -> String {
        switch reason {
        case "review_requested": "Review requested"
        case "mention": "Mentioned"
        case "team_mention": "Team mentioned"
        case "assign": "Assigned"
        case "author": "You created this"
        case "comment": "You commented"
        case "state_change": "You changed the state"
        case "manual": "Subscribed"
        case "subscribed": "Watching"
        case "ci_activity": "Workflow run"
        case "approval_requested": "Deployment approval requested"
        case "security_alert": "Security alert"
        case "security_advisory_credit": "Advisory credit"
        case "invitation": "Invitation"
        case "member_feature_requested": "Feature requested"
        case "agent_session_finished": "Copilot session finished"
        default: sentence(from: reason)
        }
    }

    static func describe(type: String) -> String {
        // Splits camel case at each lowercase-to-uppercase boundary: "PullRequest" → "Pull Request".
        let words = type.replacing(/(?<lower>[a-z])(?<upper>[A-Z])/) { "\($0.lower) \($0.upper)" }.lowercased()
        return sentence(from: words)
    }

    private static func sentence(from identifier: String) -> String {
        let words = identifier.replacing("_", with: " ")
        return words.prefix(1).localizedUppercase + words.dropFirst()
    }

    static func symbol(for type: String) -> String {
        switch type {
        case "PullRequest": "arrow.triangle.pull"
        case "Issue": "smallcircle.filled.circle"
        case "Discussion": "bubble.left.and.bubble.right"
        case "Release": "tag"
        case "CheckSuite", "WorkflowRun": "gearshape"
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": "shield.lefthalf.filled"
        case "RepositoryInvitation": "person.badge.plus"
        default: "bell"
        }
    }
}
