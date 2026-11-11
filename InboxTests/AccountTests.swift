import Testing
@testable import Inbox

struct AccountTests {
    private static let status = #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo"}]}}"#

    @Test func looksUpTheAccountOnceForEveryoneWhoAsks() async throws {
        let cli = ScriptedCLI(outputs: [Self.status, "gho_1\n", "gho_2\n"])
        let account = Account { cli.make() }

        async let first = account.resolve()
        async let second = account.resolve()
        let logins = [try await first, try await second]
        _ = try await account.token()

        #expect(logins == ["octo", "octo"])
        #expect(account.login == "octo")
        #expect(cli.invocations.filter { $0.starts(with: ["auth", "status"]) }.count == 1)
    }

    @Test func tokensBelongToTheAccountChosenAtLaunch() async throws {
        let cli = ScriptedCLI(outputs: [Self.status, "gho_1\n", "gho_2\n"])
        let account = Account { cli.make() }

        _ = try await account.token()
        _ = try await account.token()

        #expect(cli.invocations.dropFirst().allSatisfy { $0 == ["auth", "token", "--hostname", "github.com", "--user", "octo"] })
    }

    @Test func reportsAMissingGitHubCLI() async {
        let account = Account { nil }

        await #expect(throws: GitHubCLI.Problem.notInstalled) {
            try await account.resolve()
        }
    }

    @Test func triesAgainAfterAFailedLookup() async throws {
        let cli = ScriptedCLI(outputs: [#"{"hosts":{}}"#, Self.status])
        let account = Account { cli.make() }

        await #expect(throws: GitHubCLI.Problem.notLoggedIn) {
            try await account.resolve()
        }
        #expect(try await account.resolve() == "octo")
    }
}

final class ScriptedCLI {
    private var outputs: [String]
    private(set) var invocations: [[String]] = []

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func make() -> GitHubCLI {
        GitHubCLI(executable: "gh") { arguments in
            self.invocations.append(arguments)
            await Task.yield()
            return self.outputs.removeFirst()
        }
    }
}
