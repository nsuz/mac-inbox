import Foundation
import Subprocess
import System

struct GitHubCLI {
    enum Problem: Error, Equatable {
        case notInstalled
        case notLoggedIn
        case failed(String)
    }

    typealias Run = ([String]) async throws -> String

    let executable: String
    private let run: Run

    init(executable: String, run: @escaping Run) {
        self.executable = executable
        self.run = run
    }

    init(executable: String) {
        self.init(executable: executable) { arguments in
            try await Self.execute(executable, arguments)
        }
    }

    // Apps launched from Finder or as login items get only /usr/bin:/bin:/usr/sbin:/sbin,
    // so gh is looked up in Homebrew's prefixes rather than through PATH.
    static func locate(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> GitHubCLI? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first(where: isExecutable)
            .map { GitHubCLI(executable: $0) }
    }

    func activeAccount() async throws -> String {
        let output = try await run(["auth", "status", "--hostname", "github.com", "--active", "--json", "hosts"])
        let status = try JSONDecoder().decode(Status.self, from: Data(output.utf8))
        guard let login = status.hosts["github.com"]?.first(where: \.active)?.login else {
            throw Problem.notLoggedIn
        }
        return login
    }

    func token(for login: String) async throws -> String {
        let output: String
        do {
            output = try await run(["auth", "token", "--hostname", "github.com", "--user", login])
        } catch Problem.failed {
            throw Problem.notLoggedIn
        }
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Problem.notLoggedIn }
        return token
    }

    private struct Status: Decodable {
        struct Account: Decodable {
            let login: String
            let active: Bool
        }

        let hosts: [String: [Account]]
    }

    private static func execute(_ executable: String, _ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path(FilePath(executable)),
            arguments: Arguments(arguments),
            output: .string(limit: 64 * 1024),
            error: .string(limit: 8 * 1024)
        )
        guard result.terminationStatus.isSuccess else {
            throw Problem.failed(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.standardOutput
    }
}
