import Foundation
import Testing
import UserNotifications
@testable import Inbox

struct AnnouncementTests {
    private let notification = Fixture.notification(Fixture.pullRequest)

    @Test func replacesAnyEarlierNotificationForTheSameThread() {
        #expect(Announcement.request(for: notification, activity: nil, login: "octo", locale: .english).identifier == "1001")
    }

    @Test func headlinesTheThreadAndSaysWhereAndWhy() {
        let content = Announcement.request(for: notification, activity: nil, login: "octo", locale: .english).content

        #expect(content.title == "Fix popup position")
        #expect(content.subtitle == "octo/app #42 · Review requested")
        #expect(content.body == "")
    }

    @Test func saysOnlyTheRepositoryOfAThreadWithoutANumber() {
        let checkSuite = Fixture.notification(Fixture.checkSuite)

        #expect(Announcement.request(for: checkSuite, activity: nil, login: "octo", locale: .english).content.subtitle == "octo/app · Workflow run")
    }

    private func event(_ action: GitHub.Event.Action, saying text: String? = nil) -> GitHub.Event {
        GitHub.Event(action: action, actor: "hubot", date: notification.updatedAt, url: URL(string: "https://github.com/octo/app/pull/42#pullrequestreview-9"), text: text)
    }

    private func content(of notification: GitHub.Notification, state: GitHub.SubjectState? = .open, event: GitHub.Event?) -> UNNotificationContent {
        let activity = GitHub.Activity(asOf: notification.updatedAt, state: state, event: event, awaitsYourReview: false)
        return Announcement.request(for: notification, activity: activity, login: "octo", locale: .english).content
    }

    @Test(arguments: [
        (GitHub.Event.Action.commented, "Looks good,\n  merging.", "hubot: Looks good, merging."),
        (.approved, "Ship it", "hubot: Ship it"),
        (.requestedChanges, "Please add a test", "hubot: Please add a test"),
    ])
    func tellsWhatSomeoneWroteInTheirWords(action: GitHub.Event.Action, text: String, body: String) {
        #expect(content(of: notification, event: event(action, saying: text)).body == body)
    }

    @Test(arguments: [
        (GitHub.Event.Action.approved, String?(""), "hubot approved"),
        (.commented, "<!-- run 42 -->", "hubot commented"),
        (.merged, nil, "hubot merged"),
    ])
    func tellsWhatSomeoneDidWhenTheyWroteNothing(action: GitHub.Event.Action, text: String?, body: String) {
        #expect(content(of: notification, event: event(action, saying: text)).body == body)
    }

    @Test func saysNothingOfAnEventAlreadyRead() {
        let read = Fixture.notification(Fixture.thread(id: "1001", lastReadAt: "2026-11-11T02:46:12Z"))

        #expect(content(of: read, state: .merged, event: event(.merged)).body == "")
    }

    @Test func saysNothingOfWhereTheSubjectStandsWithoutAnEvent() {
        #expect(content(of: notification, state: .merged, event: nil).body == "")
    }

    @Test func carriesTheEventItToldOfSoThatItOpensThere() throws {
        let userInfo = content(of: notification, event: event(.approved)).userInfo

        #expect(try #require(Announcement(userInfo: userInfo)).event == URL(string: "https://github.com/octo/app/pull/42#pullrequestreview-9"))
    }

    @Test func carriesNoEventItDidNotTellOf() throws {
        let read = Fixture.notification(Fixture.thread(id: "1001", lastReadAt: "2026-11-11T02:46:12Z"))
        let userInfo = content(of: read, event: event(.approved)).userInfo

        #expect(try #require(Announcement(userInfo: userInfo)).event == nil)
    }

    @Test func groupsNotificationsByRepositoryAndHidesDetailsWhenPreviewsAreOff() {
        let content = Announcement.request(for: notification, activity: nil, login: "octo", locale: .english).content

        #expect(content.threadIdentifier == "octo/app")
        #expect(content.categoryIdentifier == Announcement.category(locale: .english).identifier)
        #expect(Announcement.category(locale: .english).hiddenPreviewsBodyPlaceholder == "New activity")
    }

    @Test func carriesTheThreadAndItsAccountSoItOpensAfterARelaunch() throws {
        let userInfo = Announcement.request(for: notification, activity: nil, login: "octo", locale: .english).content.userInfo

        let payload = try #require(Announcement(userInfo: userInfo))
        #expect(payload.login == "octo")
        #expect(payload.notification == notification)
    }

    @Test func ignoresAPayloadItDidNotWrite() {
        #expect(Announcement(userInfo: ["thread": "nonsense"]) == nil)
        #expect(Announcement(userInfo: [:]) == nil)
    }

    // MARK: - Excerpt

    @Test(arguments: [
        ("Looks good.\n\nOne nit:\n  rename it", "Looks good. One nit: rename it"),
        ("> Should we rename it?\n\nYes, let's.", "Yes, let's."),
        ("<!-- bot: run 42 -->\nAll checks passed", "All checks passed"),
        ("", ""),
    ])
    func previewsWhatSomeoneWroteAsOneLine(text: String, excerpt: String) {
        let event = GitHub.Event(action: .commented, actor: "hubot", date: .now, url: nil, text: text)

        #expect(event.excerpt == excerpt)
    }
}
