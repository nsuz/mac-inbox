import Observation

@Observable
final class Account {
    private(set) var login: String?

    @ObservationIgnored private let locate: () -> GitHubCLI?
    @ObservationIgnored private var lookup: Task<String, any Error>?

    init(locate: @escaping () -> GitHubCLI? = { GitHubCLI.locate() }) {
        self.locate = locate
    }

    func resolve() async throws -> String {
        if let login { return login }
        let lookup = self.lookup ?? Task {
            guard let cli = locate() else { throw GitHubCLI.Problem.notInstalled }
            return try await cli.activeAccount()
        }
        self.lookup = lookup
        do {
            let login = try await lookup.value
            self.login = login
            return login
        } catch {
            self.lookup = nil
            throw error
        }
    }

    func token() async throws -> String {
        let login = try await resolve()
        guard let cli = locate() else { throw GitHubCLI.Problem.notInstalled }
        return try await cli.token(for: login)
    }
}
