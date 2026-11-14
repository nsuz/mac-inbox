import Foundation

enum GitHub {
    static let inbox = URL(string: "https://github.com/notifications")!

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension GitHub {
    struct Notification: Codable, Identifiable, Hashable {
        let id: String
        let reason: String
        let updatedAt: Date
        let lastReadAt: Date?
        let subject: Subject
        let repository: Repository

        struct Subject: Codable, Hashable {
            let title: String
            let type: String
            // Declared as required strings by the API reference, but null for CheckSuite threads in practice.
            let url: URL?
            let latestCommentURL: URL?

            private enum CodingKeys: String, CodingKey {
                case title, type, url
                case latestCommentURL = "latest_comment_url"
            }
        }

        struct Repository: Codable, Hashable {
            let fullName: String
            let htmlURL: URL

            private enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case htmlURL = "html_url"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id, reason, subject, repository
            case updatedAt = "updated_at"
            case lastReadAt = "last_read_at"
        }

        // Where GraphQL finds the subject: GitHub asks integrators not to read structure out of its
        // URLs, but GraphQL looks a pull request up by its number, which a notification gives
        // nowhere else. Nil for any other kind of subject, and for a URL that does not end in one.
        var issueOrPullRequest: (owner: String, name: String, number: Int)? {
            guard subject.type == "PullRequest" || subject.type == "Issue",
                  let number = subject.url.flatMap({ Int($0.lastPathComponent) })
            else { return nil }
            let parts = repository.fullName.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]), number)
        }
    }
}
