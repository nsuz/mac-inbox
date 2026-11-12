import Combine
import Foundation
import Testing
@testable import Inbox

struct DockTests {
    @Test func doesNotTakeTheDockAlreadyRunningForARelaunch() {
        #expect(relaunches(among: [770, 770]) == 0)
    }

    @Test func noticesEachDockThatTakesOverFromTheOneBefore() {
        #expect(relaunches(among: [770, nil, 801, 902]) == 2)
    }

    @Test func countsADockOnceAlthoughItComesAndGoesWhileStarting() {
        #expect(relaunches(among: [770, nil, 801, nil, nil, 801]) == 1)
    }

    private func relaunches(among processIDs: [pid_t?]) -> Int {
        var count = 0
        _ = Dock.relaunches(among: processIDs.publisher).sink { count += 1 }
        return count
    }
}
