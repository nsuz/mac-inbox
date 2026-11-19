import Foundation
import Testing
import UserNotifications
@testable import Inbox

struct NotificationSoundTests {
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!

    @Test func listsTheSoundsMacOSShips() {
        #expect(NotificationSound.names.contains("Glass"))
    }

    @Test func playsTheDefaultSoundUntilOneIsChosen() {
        #expect(defaults.notificationSound == .default)
    }

    @Test func playsTheChosenSound() {
        defaults.set("Glass", forKey: NotificationSound.key)

        #expect(defaults.notificationSound == UNNotificationSound(named: UNNotificationSoundName("Glass")))
        #expect(defaults.notificationSound != .default)
    }
}
