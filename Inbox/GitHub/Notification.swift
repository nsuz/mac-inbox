import Foundation

enum GitHub {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension GitHub {
    struct Notification: Decodable, Identifiable, Hashable {
        let id: String
        let reason: String
        let updatedAt: Date
        let subject: Subject
        let repository: Repository

        struct Subject: Decodable, Hashable {
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

        struct Repository: Decodable, Hashable {
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
        }
    }
}
