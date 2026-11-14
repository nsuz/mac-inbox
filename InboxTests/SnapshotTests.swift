import Foundation
import Testing
@testable import Inbox

struct SnapshotTests {
    private let file = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "octocat.json")

    @Test func readsBackWhatWasWritten() throws {
        let pullRequest = Fixture.notification(Fixture.pullRequest)
        let event = GitHub.Event(action: .approved, actor: "hubot", date: pullRequest.updatedAt, url: URL(string: "https://github.com/octo/app/pull/42#pullrequestreview-9"), text: nil)
        let snapshot = Snapshot(
            notifications: [pullRequest, Fixture.notification(Fixture.checkSuite)],
            activities: [pullRequest.id: GitHub.Activity(asOf: pullRequest.updatedAt, state: .merged, event: event)]
        )

        try snapshot.write(to: file)

        #expect(Snapshot(contentsOf: file) == snapshot)
    }

    @Test func keepsNoWordsOfCommentsOrReviewsOnDisk() throws {
        let pullRequest = Fixture.notification(Fixture.pullRequest)
        let event = GitHub.Event(action: .commented, actor: "hubot", date: pullRequest.updatedAt, url: nil, text: "Looks good")
        let activity = GitHub.Activity(asOf: pullRequest.updatedAt, state: nil, event: event)

        try Snapshot(notifications: [pullRequest], activities: [pullRequest.id: activity]).write(to: file)

        let restored = try #require(Snapshot(contentsOf: file)?.activities[pullRequest.id]?.event)
        #expect(restored.actor == "hubot")
        #expect(restored.text == nil)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("Looks good"))
    }

    @Test func readsNothingBeforeAnythingWasWritten() {
        #expect(Snapshot(contentsOf: file) == nil)
    }

    @Test func readsNothingFromAFileItCannotMakeSenseOf() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"threads":[]}"#.utf8).write(to: file)

        #expect(Snapshot(contentsOf: file) == nil)
    }

    // A version that described threads differently: read as they are, its threads would look
    // described, and would never be asked about again.
    @Test(arguments: [
        #"{"notifications":[],"activities":{}}"#,
        #"{"format":1,"notifications":[],"activities":{}}"#,
    ])
    func readsNothingFromAFileOfAnotherFormat(json: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)

        #expect(Snapshot(contentsOf: file) == nil)
    }

    @Test func keepsEachAccountInAFileOfItsOwn() {
        #expect(Snapshot.file(for: "octocat") != Snapshot.file(for: "hubot"))
    }
}
