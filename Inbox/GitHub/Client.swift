import Foundation
import OSLog

extension GitHub {
    enum Failure: Error, Equatable {
        case unauthorized
        case notFound
        case forbidden(String)
        case rateLimited(until: Date)
        case suspended
        case server(status: Int)
    }

    enum Unread: Equatable {
        case notModified(pollInterval: Duration)
        case modified([Notification], etag: String?, pollInterval: Duration)

        var pollInterval: Duration {
            switch self {
            case let .notModified(pollInterval), let .modified(_, _, pollInterval): pollInterval
            }
        }
    }

    final class Client {
        typealias Send = (URLRequest) async throws -> (Data, HTTPURLResponse)

        private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "github")
        private static let notifications = URL(string: "https://api.github.com/notifications?per_page=50")!
        private static let minimumPollInterval = 60
        private static let secondaryLimitsBeforeSuspending = 5

        private let token: () async throws -> String
        private let send: Send
        private let now: () -> Date
        private var cachedToken: String?
        private var stoppedUntil: Date?
        private var consecutiveSecondaryLimits = 0

        init(token: @escaping () async throws -> String, send: @escaping Send, now: @escaping () -> Date = Date.init) {
            self.token = token
            self.send = send
            self.now = now
        }

        convenience init(token: @escaping () async throws -> String) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            self.init(token: token) { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, response)
            }
        }

        func resume() {
            consecutiveSecondaryLimits = 0
        }

        func unread(ifNoneMatch etag: String?) async throws -> Unread {
            var request = URLRequest(url: Self.notifications)
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            let (data, response) = try await perform(request)
            let pollInterval = Self.pollInterval(of: response)
            if response.statusCode == 304 {
                return .notModified(pollInterval: pollInterval)
            }

            var notifications = try GitHub.decoder.decode([Notification].self, from: data)
            var next = Self.nextPage(of: response)
            while let url = next {
                let (data, response) = try await perform(URLRequest(url: url))
                notifications += try GitHub.decoder.decode([Notification].self, from: data)
                next = Self.nextPage(of: response)
            }

            var seen = Set<Notification.ID>()
            let unique = notifications.filter { seen.insert($0.id).inserted }
            return .modified(unique, etag: response.value(forHTTPHeaderField: "ETag"), pollInterval: pollInterval)
        }

        func markAsRead(_ id: Notification.ID) async throws {
            var request = URLRequest(url: URL(string: "https://api.github.com/notifications/threads/\(id)")!)
            request.httpMethod = "PATCH"
            _ = try await perform(request)
        }

        func htmlURL(of resource: URL) async throws -> URL {
            let (data, _) = try await perform(URLRequest(url: resource))
            return try JSONDecoder().decode(WebLocation.self, from: data).htmlURL
        }

        private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            var (data, response) = try await authorizedSend(request, token: cachedOrFreshToken())
            if response.statusCode == 401 {
                cachedToken = nil
                (data, response) = try await authorizedSend(request, token: cachedOrFreshToken())
            }

            switch response.statusCode {
            case 200..<300, 304:
                consecutiveSecondaryLimits = 0
                return (data, response)
            case 401:
                throw Failure.unauthorized
            case 403, 429:
                try stop(after: response, message: Self.message(in: data))
            case 404:
                throw Failure.notFound
            default:
                throw Failure.server(status: response.statusCode)
            }
        }

        private func cachedOrFreshToken() async throws -> String {
            if let cachedToken { return cachedToken }
            let fresh = try await token()
            cachedToken = fresh
            return fresh
        }

        private func authorizedSend(_ request: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            // Checked here rather than once per call: another request may have been stopped
            // while this one awaited its token or a 401 that it is about to retry.
            try ensureAllowed()
            let (data, response) = try await send(request)
            Self.log.info("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path() ?? "", privacy: .private) → \(response.statusCode, privacy: .public)")
            return (data, response)
        }

        private func ensureAllowed() throws {
            if consecutiveSecondaryLimits >= Self.secondaryLimitsBeforeSuspending {
                throw Failure.suspended
            }
            if let stoppedUntil, now() < stoppedUntil {
                throw Failure.rateLimited(until: stoppedUntil)
            }
        }

        // A 403 is also how GitHub reports missing permissions such as SAML authorization,
        // so only the headers and the message decide whether a response is a rate limit.
        private func stop(after response: HTTPURLResponse, message: String) throws -> Never {
            let isPrimary = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            let isSecondary = response.statusCode == 429 || message.localizedCaseInsensitiveContains("secondary rate limit")
            guard isPrimary || isSecondary else { throw Failure.forbidden(message) }

            if isSecondary {
                consecutiveSecondaryLimits += 1
            }

            let until: Date
            if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
                until = now() + seconds
            } else if isPrimary, let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
                until = Date(timeIntervalSince1970: reset)
            } else {
                until = now() + 60 * Double(1 << max(consecutiveSecondaryLimits - 1, 0))
            }
            stoppedUntil = until
            if consecutiveSecondaryLimits >= Self.secondaryLimitsBeforeSuspending {
                throw Failure.suspended
            }
            throw Failure.rateLimited(until: until)
        }

        private static func pollInterval(of response: HTTPURLResponse) -> Duration {
            let requested = response.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(Int.init) ?? minimumPollInterval
            return .seconds(max(requested, minimumPollInterval))
        }

        private static func nextPage(of response: HTTPURLResponse) -> URL? {
            guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
            for entry in link.split(separator: ",") {
                let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.dropFirst().contains(#"rel="next""#),
                      let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">")
                else { continue }
                return URL(string: String(target.dropFirst().dropLast()))
            }
            return nil
        }

        private static func message(in data: Data) -> String {
            (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message ?? ""
        }

        private struct ErrorBody: Decodable {
            let message: String
        }

        private struct WebLocation: Decodable {
            let htmlURL: URL

            private enum CodingKeys: String, CodingKey {
                case htmlURL = "html_url"
            }
        }
    }
}
