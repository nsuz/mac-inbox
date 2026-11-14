import Foundation

// What the inbox knew when it was last loaded, kept so that the next launch can show it while
// GitHub is asked again. Only a cache: a file it cannot read back counts as no snapshot.
struct Snapshot: Codable, Equatable {
    // Raised whenever what is written changes shape. A file from an earlier version may still
    // decode, with whatever it lacks read as nothing; its threads would then look described and
    // never be asked about again.
    private static let currentFormat = 3

    private var format = Self.currentFormat
    let notifications: [GitHub.Notification]
    let activities: [GitHub.Notification.ID: GitHub.Activity]

    static func file(for login: String) -> URL {
        URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier!, directoryHint: .isDirectory)
            .appending(path: "\(login).json")
    }

    init(notifications: [GitHub.Notification], activities: [GitHub.Notification.ID: GitHub.Activity]) {
        self.notifications = notifications
        self.activities = activities
    }

    init?(contentsOf file: URL) {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? GitHub.decoder.decode(Self.self, from: data),
              snapshot.format == Self.currentFormat
        else { return nil }
        self = snapshot
    }

    func write(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GitHub.encoder.encode(self).write(to: file, options: .atomic)
    }
}
