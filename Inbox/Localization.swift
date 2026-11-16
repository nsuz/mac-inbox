import Foundation

extension LocalizedStringResource {
    // Words that come from elsewhere, such as what gh or GitHub said, shown as they are. Passed as
    // an argument rather than used as the key: a key is looked up, so words that happen to match a
    // phrase Inbox translates, such as "Open", would be translated.
    static func verbatim(_ text: String) -> Self {
        Self("\(text)", comment: "Words from elsewhere, such as what GitHub said, shown as they are")
    }

    func resolved(in locale: Locale) -> String {
        var resource = self
        resource.locale = locale
        return String(localized: resource)
    }
}
