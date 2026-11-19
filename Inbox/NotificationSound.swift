import Foundation
import UniformTypeIdentifiers
import UserNotifications

// A notification plays the sounds macOS ships by name, so none is bundled. Apple documents only
// an app's own Library/Sounds and bundle as where the name is looked up; that the system's sounds
// are found too was confirmed by ear on macOS 26. A name that is not found still plays a sound.
enum NotificationSound {
    static let key = "sound"

    static let names = names(of: (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])

    static func names(of files: [String]) -> [String] {
        files
            .filter { UTType(filenameExtension: ($0 as NSString).pathExtension)?.conforms(to: .audio) == true }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension UserDefaults {
    var notificationSound: UNNotificationSound {
        string(forKey: NotificationSound.key).map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
    }
}
