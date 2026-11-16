import Foundation

// The settings name what a thread is about in a person's words rather than listing the API's
// reasons one by one.
enum ReasonGroup: String, CaseIterable, Identifiable {
    case reviewRequests
    case mentions
    case assignments
    case participating
    case subscriptions
    case workflowRuns
    case security
    case requests
    case copilot

    init?(reason: String) {
        guard let group = Self.allCases.first(where: { $0.reasons.contains(reason) }) else { return nil }
        self = group
    }

    var id: Self { self }

    var reasons: Set<String> {
        switch self {
        case .reviewRequests: ["review_requested"]
        case .mentions: ["mention", "team_mention"]
        case .assignments: ["assign"]
        case .participating: ["author", "comment", "state_change"]
        case .subscriptions: ["subscribed", "manual"]
        case .workflowRuns: ["ci_activity"]
        case .security: ["security_alert", "security_advisory_credit"]
        case .requests: ["approval_requested", "invitation", "member_feature_requested"]
        case .copilot: ["agent_session_finished"]
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .reviewRequests: "Review requests"
        case .mentions: "Mentions"
        case .assignments: "Assignments"
        case .participating: "Threads you took part in"
        case .subscriptions: "Watched repositories and threads"
        case .workflowRuns: "Workflow runs"
        case .security: "Security alerts"
        case .requests: "Approvals and invitations"
        case .copilot: "Copilot sessions"
        }
    }

    // The muted groups are stored rather than the enabled ones, so a group added later is announced.
    var mutedKey: String { "mutes.\(rawValue)" }
}

extension UserDefaults {
    // A reason outside every group is one GitHub added later, and is announced until a group takes it in.
    func mutes(reason: String) -> Bool {
        ReasonGroup(reason: reason).map { bool(forKey: $0.mutedKey) } ?? false
    }
}
