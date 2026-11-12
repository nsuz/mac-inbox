import AppKit
import Combine

enum Dock {
    // Key-value observation, not `didLaunchApplicationNotification`: the workspace does not post
    // that notification for the Dock.
    static var relaunches: some Publisher<Void, Never> {
        relaunches(among: NSWorkspace.shared.publisher(for: \.runningApplications).map { applications in
            applications.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
        })
    }

    static func relaunches(among processIDs: some Publisher<pid_t?, Never>) -> some Publisher<Void, Never> {
        processIDs
            .compactMap { $0 }
            .removeDuplicates()
            .dropFirst()
            .map { _ in }
    }
}
