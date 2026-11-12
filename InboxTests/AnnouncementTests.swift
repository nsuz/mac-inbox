import Foundation
import Testing
import UserNotifications
@testable import Inbox

struct AnnouncementTests {
    private let notification = Fixture.notification(Fixture.pullRequest)

    @Test func replacesAnyEarlierNotificationForTheSameThread() {
        #expect(Announcement.request(for: notification, login: "octo").identifier == "1001")
    }

    @Test func headlinesTheThreadAndSaysWhereAndWhy() {
        let content = Announcement.request(for: notification, login: "octo").content

        #expect(content.title == "Fix popup position")
        #expect(content.subtitle == "octo/app")
        #expect(content.body == "Review requested")
    }

    @Test func groupsNotificationsByRepositoryAndHidesDetailsWhenPreviewsAreOff() {
        let content = Announcement.request(for: notification, login: "octo").content

        #expect(content.threadIdentifier == "octo/app")
        #expect(content.categoryIdentifier == Announcement.category.identifier)
        #expect(Announcement.category.hiddenPreviewsBodyPlaceholder == "New activity")
    }

    @Test func carriesTheThreadAndItsAccountSoItOpensAfterARelaunch() throws {
        let userInfo = Announcement.request(for: notification, login: "octo").content.userInfo

        let payload = try #require(Announcement(userInfo: userInfo))
        #expect(payload.login == "octo")
        #expect(payload.notification == notification)
    }

    @Test func ignoresAPayloadItDidNotWrite() {
        #expect(Announcement(userInfo: ["thread": "nonsense"]) == nil)
        #expect(Announcement(userInfo: [:]) == nil)
    }
}
