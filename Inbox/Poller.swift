import Foundation
import Observation

@Observable
final class Poller {
    enum Wait: Equatable {
        case duration(Duration)
        case until(Date)
        case resumption
    }

    struct Schedule {
        private static let minimum: Duration = .seconds(60)
        private static let maximum: Duration = .seconds(15 * 60)

        private var backoff: Duration?

        mutating func wait(after outcome: Result<Duration, any Error>) -> Wait {
            switch outcome {
            case let .success(pollInterval):
                backoff = nil
                return .duration(pollInterval)
            case let .failure(error):
                switch error {
                case let GitHub.Failure.rateLimited(until):
                    return .until(until)
                case GitHub.Failure.suspended:
                    return .resumption
                case is GitHubCLI.Problem:
                    return .duration(Self.minimum)
                default:
                    let wait = backoff.map { min($0 * 2, Self.maximum) } ?? Self.minimum
                    backoff = wait
                    return .duration(wait)
                }
            }
        }
    }

    private(set) var failure: (any Error)?

    @ObservationIgnored private var schedule = Schedule()
    @ObservationIgnored private var resumption: CheckedContinuation<Void, Never>?

    func run(_ refresh: () async throws -> Duration) async {
        while !Task.isCancelled {
            let outcome: Result<Duration, any Error>
            do {
                outcome = .success(try await refresh())
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                outcome = .failure(error)
                failure = error
            }
            await wait(schedule.wait(after: outcome))
        }
    }

    func resume() {
        resumption?.resume()
        resumption = nil
    }

    private func wait(_ wait: Wait) async {
        switch wait {
        case let .duration(duration):
            try? await Task.sleep(for: duration, clock: .continuous)
        case let .until(date):
            try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow), clock: .continuous)
        case .resumption:
            await withTaskCancellationHandler {
                await withCheckedContinuation { resumption = $0 }
            } onCancel: {
                Task { @MainActor in self.resume() }
            }
        }
    }
}
