import Foundation
import Testing
@testable import Inbox

struct LocalizationTests {
    @Test func showsWordsFromElsewhereAsTheyAreEvenWhenTheyMatchATranslatedPhrase() {
        #expect(LocalizedStringResource.verbatim("Open").japanese == "Open")
    }

    @Test func keepsPercentSignsInWordsFromElsewhere() {
        #expect(LocalizedStringResource.verbatim("100% of %@ done").english == "100% of %@ done")
    }
}
