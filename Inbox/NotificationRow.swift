import SwiftUI

struct NotificationRow: View {
    let notification: GitHub.Notification
    let activity: GitHub.Activity?

    private var state: GitHub.SubjectState? { activity?.state }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.subject.title)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(notification.repository.fullName)
                    Text(verbatim: "·")
                    Text(GitHub.Notification.describe(reason: notification.reason, type: notification.subject.type))
                    if let event = activity?.unreadEvent(lastReadAt: notification.lastReadAt) {
                        Text(verbatim: "·")
                        // The first to give way when the row is narrow.
                        Text(event.phrase)
                            .layoutPriority(-1)
                    }
                    // Marked beside the reason rather than worded in its place, which would hide why
                    // the thread came in. In the line's own colour: the accent made it louder than the
                    // title.
                    if activity?.awaitsYourReview == true {
                        Image(systemName: "person.badge.clock")
                            .help("Waiting for your review")
                            .accessibilityLabel("Waiting for your review")
                    }
                    Spacer()
                    Text(notification.updatedAt, format: .relative(presentation: .named))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            Image(systemName: GitHub.Notification.symbol(for: notification.subject.type, state: state))
                .foregroundStyle(state?.tint ?? .primary)
                .help(GitHub.Notification.describe(type: notification.subject.type, state: state))
                .accessibilityLabel(GitHub.Notification.describe(type: notification.subject.type, state: state))
        }
        .padding(.vertical, 4)
    }
}

extension GitHub.Notification {
    // How the thread stands to the viewer. Not what the viewer did: shown with every new activity,
    // "You commented" would read as the news. Whole phrases, so that each can be translated whole.
    static func describe(reason: String, type: String) -> LocalizedStringResource {
        switch (reason, type) {
        case ("review_requested", _): "Review requested"
        case ("mention", _): "Mentioned"
        case ("team_mention", _): "Team mentioned"
        case ("assign", _): "Assigned"
        case ("author", "PullRequest"): "Your pull request"
        case ("author", "Issue"): "Your issue"
        case ("author", "Discussion"): "Your discussion"
        case ("author", _): "Yours"
        case ("comment", _), ("state_change", _): "You took part"
        case ("manual", _): "Subscribed"
        case ("subscribed", _): "Watching"
        case ("ci_activity", _): "Workflow run"
        case ("approval_requested", _): "Deployment approval requested"
        case ("security_alert", _): "Security alert"
        case ("security_advisory_credit", _): "Advisory credit"
        case ("invitation", _): "Invitation"
        case ("member_feature_requested", _): "Feature requested"
        case ("agent_session_finished", _): "Copilot session finished"
        default: .verbatim(sentence(from: reason))
        }
    }

    static func describe(type: String) -> LocalizedStringResource {
        switch type {
        case "PullRequest": "Pull request"
        case "Issue": "Issue"
        case "Discussion": "Discussion"
        case "Release": "Release"
        case "CheckSuite": "Check suite"
        case "WorkflowRun": "Workflow run"
        case "RepositoryVulnerabilityAlert", "RepositoryDependabotAlertsThread": "Dependabot alert"
        case "RepositoryInvitation": "Repository invitation"
        // Splits camel case at each lowercase-to-uppercase boundary: "SomethingNew" → "Something new".
        default: .verbatim(sentence(from: type.replacing(/(?<lower>[a-z])(?<upper>[A-Z])/) { "\($0.lower) \($0.upper)" }.lowercased()))
        }
    }

    private static func sentence(from identifier: String) -> String {
        let words = identifier.replacing("_", with: " ")
        return words.prefix(1).localizedUppercase + words.dropFirst()
    }

    // Whole phrases rather than a state joined to a kind, so that each can be translated whole.
    static func describe(type: String, state: GitHub.SubjectState?) -> LocalizedStringResource {
        switch state {
        case nil: describe(type: type)
        case .open: type == "Issue" ? "Open issue" : "Open pull request"
        case .draft: "Draft pull request"
        case .merged: "Merged pull request"
        case .closed: "Closed pull request"
        case .completed: "Issue closed as completed"
        case .notPlanned: "Issue closed as not planned"
        case .duplicate: "Issue closed as duplicate"
        }
    }

    static func symbol(for type: String, state: GitHub.SubjectState? = nil) -> String {
        switch state {
        case .merged: return "arrow.triangle.merge"
        case .completed: return "checkmark.circle"
        case .notPlanned, .duplicate: return "slash.circle"
        case .open, .draft, .closed, nil: break
        }
        return switch type {
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

private extension GitHub.SubjectState {
    // The colours GitHub gives each state.
    var tint: Color {
        switch self {
        case .open: .green
        case .merged, .completed: .purple
        case .closed: .red
        case .draft, .notPlanned, .duplicate: .secondary
        }
    }
}

extension GitHub.Event {
    // GitHub shows a deleted account as "ghost".
    var actorName: String {
        actor ?? "ghost"
    }

    var phrase: LocalizedStringResource {
        switch action {
        case .commented: "\(actorName) commented"
        case .approved: "\(actorName) approved"
        case .requestedChanges: "\(actorName) requested changes"
        case .reviewed: "\(actorName) reviewed"
        case .merged: "\(actorName) merged"
        case .closed: "\(actorName) closed"
        case .reopened: "\(actorName) reopened"
        case .markedReadyForReview: "\(actorName) marked this ready for review"
        case .requestedYourReview: "\(actorName) requested your review"
        case .requestedYourTeamsReview: "\(actorName) requested your team’s review"
        case .assignedYou: "\(actorName) assigned you"
        }
    }
}
