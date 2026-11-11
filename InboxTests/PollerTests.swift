import Foundation
import Testing
@testable import Inbox

struct PollerTests {
    private let now = Date(timeIntervalSince1970: 1_794_365_172)

    @Test func waitsAsLongAsGitHubAsksAfterASuccess() {
        var schedule = Poller.Schedule()

        #expect(schedule.wait(after: .success(.seconds(90))) == .duration(.seconds(90)))
    }

    @Test func backsOffFromAMinuteToAQuarterHourWhileFailuresContinue() {
        var schedule = Poller.Schedule()
        let waits = (1...6).map { _ in schedule.wait(after: .failure(URLError(.notConnectedToInternet))) }

        #expect(waits == [60, 120, 240, 480, 900, 900].map { .duration(.seconds($0)) })
    }

    @Test func keepsWaitingAQuarterHourHoweverLongFailuresContinue() {
        var schedule = Poller.Schedule()
        let waits = (1...200).map { _ in schedule.wait(after: .failure(URLError(.notConnectedToInternet))) }

        #expect(waits.dropFirst(4).allSatisfy { $0 == .duration(.seconds(900)) })
    }

    @Test func aSuccessEndsTheBackoff() {
        var schedule = Poller.Schedule()
        _ = schedule.wait(after: .failure(GitHub.Failure.server(status: 502)))
        _ = schedule.wait(after: .failure(GitHub.Failure.server(status: 502)))
        _ = schedule.wait(after: .success(.seconds(60)))

        #expect(schedule.wait(after: .failure(GitHub.Failure.server(status: 502))) == .duration(.seconds(60)))
    }

    @Test func waitsOutARateLimit() {
        var schedule = Poller.Schedule()

        #expect(schedule.wait(after: .failure(GitHub.Failure.rateLimited(until: now + 300))) == .until(now + 300))
    }

    @Test func waitsForThePersonAfterGitHubKeepsLimitingTheRate() {
        var schedule = Poller.Schedule()

        #expect(schedule.wait(after: .failure(GitHub.Failure.suspended)) == .resumption)
    }

    @Test(arguments: [GitHubCLI.Problem.notInstalled, .notLoggedIn])
    func checksGitHubCLIAgainEveryMinuteUntilAnAccountIsReady(problem: GitHubCLI.Problem) {
        var schedule = Poller.Schedule()
        let waits = (1...3).map { _ in schedule.wait(after: .failure(problem)) }

        #expect(waits == Array(repeating: .duration(.seconds(60)), count: 3))
    }
}
