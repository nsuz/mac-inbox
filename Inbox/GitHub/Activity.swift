import Foundation

extension GitHub {
    // Where a pull request or an issue stands, in the distinctions GitHub draws with colour.
    enum SubjectState: String, Codable, Hashable {
        case open, draft, merged, closed, completed, notPlanned, duplicate
    }

    // What has become of a thread's subject, as of the thread's activity at `asOf`.
    struct Activity: Codable, Hashable {
        let asOf: Date
        let state: SubjectState?
        // The latest thing someone other than the viewer did, among the few things looked at.
        let event: Event?
        // Whether the viewer is asked for a review of an open pull request, now rather than as of
        // `asOf`: a request can be withdrawn or fulfilled without the thread being updated.
        let awaitsYourReview: Bool

        // For a thread whose subject is gone, and for one that is not a pull request or an issue.
        static func nothingToTell(asOf: Date) -> Self {
            Self(asOf: asOf, state: nil, event: nil, awaitsYourReview: false)
        }

        func unreadEvent(lastReadAt: Date?) -> Event? {
            guard let event, lastReadAt.map({ event.date > $0 }) ?? true else { return nil }
            return event
        }
    }

    struct Event: Codable, Hashable {
        enum Action: String, Codable {
            case commented, approved, requestedChanges, reviewed, merged, closed, reopened, markedReadyForReview
            case requestedYourReview, requestedYourTeamsReview, assignedYou
        }

        let action: Action
        // As GitHub shows the name, with "[bot]" after a bot's; nil once the account has been deleted.
        let actor: String?
        let date: Date
        let url: URL?
        // The words of a comment or a review, read whole from GitHub but written without them: they
        // are wanted only for a banner about new activity, and a snapshot on disk need not keep what
        // people wrote.
        let text: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(actor, forKey: .actor)
            try container.encode(date, forKey: .date)
            try container.encodeIfPresent(url, forKey: .url)
        }

        private enum CodingKeys: String, CodingKey {
            case action, actor, date, url, text
        }
    }
}
