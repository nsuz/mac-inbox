import Foundation
@testable import Inbox

extension Locale {
    nonisolated static let english = Locale(identifier: "en_US")
    nonisolated static let japanese = Locale(identifier: "ja_JP")
}

extension LocalizedStringResource {
    var english: String { resolved(in: .english) }
    var japanese: String { resolved(in: .japanese) }
}
