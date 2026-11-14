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
        private static let graphQL = URL(string: "https://api.github.com/graphql")!
        private static let minimumPollInterval = 60
        private static let secondaryLimitsBeforeSuspending = 5

        private let token: () async throws -> String
        private let send: Send
        private let now: () -> Date
        private var cachedToken: String?
        // Secondary limits, and any wait GitHub names with `retry-after`, hold back every call made
        // with the token; a primary limit holds back only the API whose allowance has run out.
        private var stoppedUntil: Date?
        private var primaryStops: [API: Date] = [:]
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

        func unread(ifNoneMatch etag: String?, progress: ([Notification]) -> Void = { _ in }) async throws -> Unread {
            var request = URLRequest(url: Self.notifications)
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            let (data, response) = try await perform(request)
            let pollInterval = Self.pollInterval(of: response)
            if response.statusCode == 304 {
                return .notModified(pollInterval: pollInterval)
            }

            var notifications: [Notification] = []
            var seen = Set<Notification.ID>()
            func collect(_ page: Data) throws {
                notifications += try GitHub.decoder.decode([Notification].self, from: page).filter { seen.insert($0.id).inserted }
                progress(notifications)
            }

            try collect(data)
            var next = Self.nextPage(of: response)
            while let url = next {
                let (data, response) = try await perform(URLRequest(url: url))
                try collect(data)
                next = Self.nextPage(of: response)
            }
            return .modified(notifications, etag: response.value(forHTTPHeaderField: "ETag"), pollInterval: pollInterval)
        }

        func markAsRead(_ id: Notification.ID) async throws {
            var request = URLRequest(url: URL(string: "https://api.github.com/notifications/threads/\(id)")!)
            request.httpMethod = "PATCH"
            _ = try await perform(request)
        }

        func htmlURL(of resource: URL) async throws -> URL {
            try await fetch(WebLocation.self, at: resource).htmlURL
        }

        // Asks about at most `ThreadQuery.limit` threads at once. A thread that is neither a pull
        // request nor an issue is not asked about, and has no answer.
        func describe(_ threads: [Notification]) async throws -> [Notification.ID: Activity] {
            guard let query = ThreadQuery(threads) else { return [:] }
            var request = URLRequest(url: Self.graphQL)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(query)
            let (data, _) = try await perform(request)
            return try query.activities(in: data)
        }

        private func fetch<Resource: Decodable>(_: Resource.Type, at url: URL) async throws -> Resource {
            let (data, _) = try await perform(URLRequest(url: url))
            return try GitHub.decoder.decode(Resource.self, from: data)
        }

        private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let api = API(of: request)
            var (data, response) = try await authorizedSend(request, to: api, token: cachedOrFreshToken())
            if response.statusCode == 401 {
                cachedToken = nil
                (data, response) = try await authorizedSend(request, to: api, token: cachedOrFreshToken())
            }

            switch response.statusCode {
            // GraphQL reports a rate limit in the errors of a 200.
            case 200 where api == .graphQL:
                try stopIfLimited(by: response, of: api, saying: ErrorBody(data))
                fallthrough
            case 200..<300, 304:
                consecutiveSecondaryLimits = 0
                return (data, response)
            case 401:
                throw Failure.unauthorized
            case 403, 429:
                let body = ErrorBody(data)
                try stopIfLimited(by: response, of: api, saying: body)
                throw Failure.forbidden(body.messages.first ?? "")
            case 404, 410:
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

        private func authorizedSend(_ request: URLRequest, to api: API, token: String) async throws -> (Data, HTTPURLResponse) {
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            // Checked here rather than once per call: another request may have been stopped
            // while this one awaited its token or a 401 that it is about to retry.
            try ensureAllowed(api)
            let (data, response) = try await send(request)
            Self.log.info("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path() ?? "", privacy: .private) → \(response.statusCode, privacy: .public)")
            return (data, response)
        }

        private func ensureAllowed(_ api: API) throws {
            if consecutiveSecondaryLimits >= Self.secondaryLimitsBeforeSuspending {
                throw Failure.suspended
            }
            if let until = [stoppedUntil, primaryStops[api]].compactMap(\.self).filter({ now() < $0 }).max() {
                throw Failure.rateLimited(until: until)
            }
        }

        // A 403 is also how GitHub reports missing permissions such as SAML authorization, so only
        // the headers and the errors decide whether a response is a rate limit. A GraphQL query that
        // spends the last of the allowance is still answered, with nothing remaining, so a 200 is a
        // primary limit only when its errors say so.
        private func stopIfLimited(by response: HTTPURLResponse, of api: API, saying body: ErrorBody) throws {
            let isPrimary = body.types.contains("RATE_LIMITED")
                || (response.statusCode != 200 && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0")
            let isSecondary = response.statusCode == 429
                || body.messages.contains { $0.localizedCaseInsensitiveContains("secondary rate limit") }
            guard isPrimary || isSecondary else { return }

            if isSecondary {
                consecutiveSecondaryLimits += 1
            }

            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            let until = retryAfter.map { now() + $0 }
                ?? (isPrimary ? reset : nil)
                ?? now() + 60 * Double(1 << max(consecutiveSecondaryLimits - 1, 0))
            if isSecondary || retryAfter != nil {
                stoppedUntil = until
            } else {
                primaryStops[api] = until
            }
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

        // Counted apart for their primary rate limits, and told apart by where a request goes
        // rather than by what comes back.
        private enum API {
            case rest, graphQL

            init(of request: URLRequest) {
                self = request.url == GitHub.Client.graphQL ? .graphQL : .rest
            }
        }

        // REST says what went wrong in a message, GraphQL in a list of errors with types.
        private struct ErrorBody: Decodable {
            private var message: String?
            private var errors: [Entry]?

            var messages: [String] { [message].compactMap(\.self) + (errors ?? []).map(\.message) }
            var types: [String] { (errors ?? []).compactMap(\.type) }

            init(_ data: Data) {
                self = (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
            }

            private init() {}

            private struct Entry: Decodable {
                let type: String?
                let message: String
            }
        }

        private struct WebLocation: Decodable {
            let htmlURL: URL

            private enum CodingKeys: String, CodingKey {
                case htmlURL = "html_url"
            }
        }
    }
}
