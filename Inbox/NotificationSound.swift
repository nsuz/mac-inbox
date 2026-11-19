import Foundation
import UserNotifications

// A notification plays the sounds macOS ships by name, so none is bundled. A name macOS no longer
// has plays the default sound rather than none.
enum NotificationSound {
    static let key = "sound"

    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files
            .map { ($0 as NSString).deletingPathExtension }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
}

extension UserDefaults {
    var notificationSound: UNNotificationSound {
        string(forKey: NotificationSound.key).map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
    }
}
