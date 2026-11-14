import Testing
@testable import Inbox

struct SelectionTests {
    private let rows = ["1", "2", "3"].map { Fixture.notification(Fixture.thread(id: $0)) }

    @Test func movesToTheRowBelowTheOneLeaving() {
        #expect(rows.successor(of: "2") == "3")
    }

    @Test func movesToTheRowAboveWhenTheBottomRowLeaves() {
        #expect(rows.successor(of: "3") == "2")
    }

    @Test func selectsNothingWhenTheOnlyRowLeaves() {
        #expect(Array(rows.prefix(1)).successor(of: "1") == nil)
    }

    @Test func selectsNothingForARowThatIsNotThere() {
        #expect(rows.successor(of: "4") == nil)
    }
}
