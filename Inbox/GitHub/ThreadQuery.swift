import Foundation

extension GitHub {
    // One GraphQL query about several threads: where each subject stands, and the latest few things
    // done on it, with the viewer's login so that what the viewer did can be left out.
    struct ThreadQuery: Encodable {
        // GitHub ends a query that runs past ten seconds and charges extra for it against the next
        // hour; fifty threads took up to six and a half.
        static let limit = 25

        // Why not more than three: each is a node GraphQL charges for, and a merge alone takes two.
        // The two states are named apart: they are of different types, and GraphQL does not allow
        // one name for both, even though GitHub has answered it.
        private static let fragments = """
            fragment Subject on IssueOrPullRequest {
              __typename
              ... on PullRequest {
                pullRequestState: state
                isDraft
                timelineItems(last: 3, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT]) {
                  nodes { __typename ...Comment ...Review ...Merged ...Closed ...Reopened ...ReadyForReview }
                }
              }
              ... on Issue {
                issueState: state
                stateReason
                timelineItems(last: 3, itemTypes: [ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT]) {
                  nodes { __typename ...Comment ...Closed ...Reopened }
                }
              }
            }
            fragment Actor on Actor { __typename login }
            fragment Comment on IssueComment { author { ...Actor } createdAt bodyText url }
            fragment Review on PullRequestReview { author { ...Actor } submittedAt state bodyText url }
            fragment Merged on MergedEvent { actor { ...Actor } createdAt url }
            fragment Closed on ClosedEvent { actor { ...Actor } createdAt url }
            fragment Reopened on ReopenedEvent { actor { ...Actor } createdAt }
            fragment ReadyForReview on ReadyForReviewEvent { actor { ...Actor } createdAt url }
            """

        private let threads: [Notification]
        private let query: String
        private let variables: [String: Variable]

        // Nil when none of the threads is a pull request or an issue: there is nothing to ask.
        init?(_ threads: [Notification]) {
            let subjects = threads.compactMap { thread in thread.issueOrPullRequest.map { (thread, $0) } }
            guard !subjects.isEmpty else { return nil }
            self.threads = subjects.map(\.0)

            // Names and numbers go in as variables, not into the text, so that no repository name
            // can change what the query says.
            var declarations: [String] = []
            var fields: [String] = []
            var variables: [String: Variable] = [:]
            for (index, (_, subject)) in subjects.enumerated() {
                declarations.append("$owner\(index): String!, $name\(index): String!, $number\(index): Int!")
                fields.append("  t\(index): repository(owner: $owner\(index), name: $name\(index)) { issueOrPullRequest(number: $number\(index)) { ...Subject } }")
                variables["owner\(index)"] = .string(subject.owner)
                variables["name\(index)"] = .string(subject.name)
                variables["number\(index)"] = .number(subject.number)
            }
            self.query = """
                query(\(declarations.joined(separator: ", "))) {
                  viewer { login }
                \(fields.joined(separator: "\n"))
                }
                \(Self.fragments)
                """
            self.variables = variables
        }

        // Each thread answered for itself. A thread that is gone has nothing to tell, and asking
        // again will not change that; one that failed in any other way, even in part, is left out
        // to be asked about again. GitHub also fails a part of a query for want of resources, and
        // the path of an error says only where it failed, not whether it will fail again.
        func activities(in data: Data) throws -> [Notification.ID: Activity] {
            let answer = try GitHub.decoder.decode(Answer.self, from: data)
            guard let fields = answer.data else { throw Unanswered(messages: answer.errors.map(\.message)) }

            var activities: [Notification.ID: Activity] = [:]
            for (index, thread) in threads.enumerated() {
                let alias = "t\(index)"
                let errors = answer.errors.filter { $0.alias == alias }
                if !errors.isEmpty {
                    if errors.allSatisfy({ $0.type == "NOT_FOUND" }) {
                        activities[thread.id] = .nothingToTell(asOf: thread.updatedAt)
                    }
                } else if let subject = fields.subjects[alias] {
                    activities[thread.id] = Activity(asOf: thread.updatedAt, state: subject.state, event: subject.latestEvent(notBy: fields.viewer))
                }
            }
            return activities
        }

        struct Unanswered: Error {
            let messages: [String]
        }

        private enum CodingKeys: String, CodingKey {
            case query, variables
        }

        private enum Variable: Encodable {
            case string(String)
            case number(Int)

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .string(value): try container.encode(value)
                case let .number(value): try container.encode(value)
                }
            }
        }
    }
}

private struct Answer: Decodable {
    let data: Fields?
    let errors: [AnswerError]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(Fields.self, forKey: .data)
        errors = try container.decodeIfPresent([AnswerError].self, forKey: .errors) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case data, errors
    }
}

private struct AnswerError: Decodable {
    let type: String?
    let message: String
    // The thread the error is about; nil for one about the whole query.
    let alias: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        message = try container.decode(String.self, forKey: .message)
        // A path goes on with field names and list indices; only where it starts is wanted.
        var path = try? container.nestedUnkeyedContainer(forKey: .path)
        alias = try? path?.decode(String.self)
    }

    private enum CodingKeys: String, CodingKey {
        case type, message, path
    }
}

private struct Fields: Decodable {
    let viewer: String
    // By alias. A thread whose answer does not read as expected is left out, to be asked about again.
    let subjects: [String: Subject]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Alias.self)
        viewer = try container.decode(Viewer.self, forKey: Alias("viewer")).login
        subjects = container.allKeys.reduce(into: [:]) { subjects, alias in
            subjects[alias.stringValue] = try? container.decode(Repository.self, forKey: alias).issueOrPullRequest
        }
    }

    private struct Viewer: Decodable {
        let login: String
    }

    private struct Repository: Decodable {
        let issueOrPullRequest: Subject
    }

    private struct Alias: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

private struct Subject: Decodable {
    let state: GitHub.SubjectState
    let events: [GitHub.Event]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .typename) {
        case "PullRequest":
            let state = try container.decode(String.self, forKey: .pullRequestState)
            let isDraft = try container.decode(Bool.self, forKey: .isDraft)
            self.state = switch (state, isDraft) {
            case ("MERGED", _): .merged
            case ("CLOSED", _): .closed
            case (_, true): .draft
            default: .open
            }
        case "Issue":
            // An issue closed before GitHub recorded reasons has none, and GitHub shows it as completed.
            let state = try container.decode(String.self, forKey: .issueState)
            let reason = try container.decodeIfPresent(String.self, forKey: .stateReason)
            self.state = switch (state, reason) {
            case ("OPEN", _): .open
            case (_, "NOT_PLANNED"): .notPlanned
            case (_, "DUPLICATE"): .duplicate
            default: .completed
            }
        case let typename:
            throw DecodingError.dataCorruptedError(forKey: .typename, in: container, debugDescription: "\(typename) is neither a pull request nor an issue")
        }
        events = try container.decode(Timeline.self, forKey: .timelineItems).nodes.compactMap(\.event)
    }

    // The latest by time, since GitHub does not document the order it lists them in. A bot's name
    // carries "[bot]", so only the viewer's own doings match the viewer's login.
    func latestEvent(notBy viewer: String) -> GitHub.Event? {
        events
            .filter { $0.actor != viewer }
            // Merging closes a pull request in the same moment, and the merge is what happened.
            .filter { state != .merged || $0.action != .closed }
            .max { $0.date < $1.date }
    }

    private struct Timeline: Decodable {
        let nodes: [Item]
    }

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case pullRequestState, issueState, isDraft, stateReason, timelineItems
    }
}

private struct Item: Decodable {
    // Nil for a review not yet submitted.
    let event: GitHub.Event?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typename = try container.decode(String.self, forKey: .typename)
        let action: GitHub.Event.Action?
        switch typename {
        case "IssueComment": action = .commented
        case "PullRequestReview":
            action = switch try container.decode(String.self, forKey: .state) {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .requestedChanges
            case "COMMENTED", "DISMISSED": .reviewed
            default: nil
            }
        case "MergedEvent": action = .merged
        case "ClosedEvent": action = .closed
        case "ReopenedEvent": action = .reopened
        case "ReadyForReviewEvent": action = .markedReadyForReview
        default:
            throw DecodingError.dataCorruptedError(forKey: .typename, in: container, debugDescription: "\(typename) was not asked for")
        }

        let isWritten = typename == "IssueComment" || typename == "PullRequestReview"
        let actor = try container.decodeIfPresent(Actor.self, forKey: isWritten ? .author : .actor)
        let date = try container.decodeIfPresent(Date.self, forKey: typename == "PullRequestReview" ? .submittedAt : .createdAt)
        guard let action, let date else {
            event = nil
            return
        }
        event = GitHub.Event(
            action: action,
            actor: actor?.name,
            date: date,
            url: try container.decodeIfPresent(URL.self, forKey: .url),
            text: isWritten ? try container.decode(String.self, forKey: .bodyText) : nil
        )
    }

    private struct Actor: Decodable {
        let typename: String
        let login: String

        // GraphQL gives a bot's login without the "[bot]" that GitHub shows and REST returns.
        var name: String {
            typename == "Bot" ? "\(login)[bot]" : login
        }

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login
        }
    }

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case author, actor, createdAt, submittedAt, state, bodyText, url
    }
}
