import Testing
@testable import Inbox

struct GitHubCLITests {
    private static let activeStatus = """
        {"hosts":{"github.com":[
          {"state":"success","active":false,"host":"github.com","login":"someone-else","tokenSource":"keyring"},
          {"state":"success","active":true,"host":"github.com","login":"octo","tokenSource":"keyring"}
        ]}}
        """

    @Test func prefersHomebrewOnAppleSilicon() {
        let cli = GitHubCLI.locate { _ in true }
        #expect(cli?.executable == "/opt/homebrew/bin/gh")
    }

    @Test func fallsBackToTheIntelHomebrewPrefix() {
        let cli = GitHubCLI.locate { $0 == "/usr/local/bin/gh" }
        #expect(cli?.executable == "/usr/local/bin/gh")
    }

    @Test func findsNothingWhenGitHubCLIIsNotInstalled() {
        #expect(GitHubCLI.locate { _ in false } == nil)
    }

    @Test func readsTheActiveGitHubDotComAccount() async throws {
        let recorder = Recorder(output: Self.activeStatus)
        let cli = GitHubCLI(executable: "/opt/homebrew/bin/gh", run: recorder.run)

        let account = try await cli.activeAccount()

        #expect(account == "octo")
        #expect(recorder.invocations == [["auth", "status", "--hostname", "github.com", "--active", "--json", "hosts"]])
    }

    @Test(arguments: [
        #"{"hosts":{}}"#,
        #"{"hosts":{"github.com":[]}}"#,
        #"{"hosts":{"github.com":[{"state":"success","active":false,"host":"github.com","login":"octo"}]}}"#,
    ])
    func reportsNotLoggedInWithoutAnActiveAccount(status: String) async {
        let cli = GitHubCLI(executable: "gh", run: Recorder(output: status).run)

        await #expect(throws: GitHubCLI.Problem.notLoggedIn) {
            try await cli.activeAccount()
        }
    }

    @Test func asksForTheTokenOfThePinnedAccountOnGitHubDotCom() async throws {
        let recorder = Recorder(output: "gho_example\n")
        let cli = GitHubCLI(executable: "gh", run: recorder.run)

        let token = try await cli.token(for: "octo")

        #expect(token == "gho_example")
        #expect(recorder.invocations == [["auth", "token", "--hostname", "github.com", "--user", "octo"]])
    }

    @Test func reportsNotLoggedInWhenTheAccountHasNoToken() async {
        let cli = GitHubCLI(executable: "gh", run: Recorder(output: "\n").run)

        await #expect(throws: GitHubCLI.Problem.notLoggedIn) {
            try await cli.token(for: "octo")
        }
    }
}

private final class Recorder {
    let output: String
    private(set) var invocations: [[String]] = []

    init(output: String) {
        self.output = output
    }

    func run(_ arguments: [String]) async throws -> String {
        invocations.append(arguments)
        return output
    }
}
