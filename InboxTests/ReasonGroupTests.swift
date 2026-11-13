import Foundation
import Testing
@testable import Inbox

struct ReasonGroupTests {
    // Every reason the REST API reference lists.
    nonisolated private static let documentedReasons = [
        "approval_requested", "assign", "author", "ci_activity", "comment", "invitation", "manual",
        "member_feature_requested", "mention", "review_requested", "security_advisory_credit",
        "security_alert", "state_change", "subscribed", "team_mention", "agent_session_finished",
    ]

    private let defaults = UserDefaults(suiteName: UUID().uuidString)!

    @Test(arguments: documentedReasons)
    func putsEveryDocumentedReasonInExactlyOneGroup(reason: String) {
        #expect(ReasonGroup.allCases.filter { $0.reasons.contains(reason) }.count == 1)
    }

    @Test func leavesAReasonGitHubAddsLaterOutOfEveryGroup() {
        #expect(ReasonGroup(reason: "something_new") == nil)
    }

    @Test func mutesNothingUntilAGroupIsMuted() {
        #expect(!defaults.mutes(reason: "mention"))
    }

    @Test func mutesEveryReasonInAMutedGroup() {
        defaults.set(true, forKey: ReasonGroup.mentions.mutedKey)

        #expect(defaults.mutes(reason: "mention"))
        #expect(defaults.mutes(reason: "team_mention"))
        #expect(!defaults.mutes(reason: "review_requested"))
    }

    @Test func neverMutesAReasonGitHubAddsLater() {
        for group in ReasonGroup.allCases {
            defaults.set(true, forKey: group.mutedKey)
        }

        #expect(!defaults.mutes(reason: "something_new"))
    }
}
