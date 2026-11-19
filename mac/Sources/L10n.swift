import Foundation

enum L10n {
    // Use the first preference so, for example, Japanese followed by Korean
    // still gets the English interface. Region and keyboard layout are separate.
    static func language(for preferences: [String]) -> String {
        guard let first = preferences.first,
              Locale(identifier: first).language.languageCode?.identifier.lowercased() == "ko"
        else { return "en" }
        return "ko"
    }

    static let language = language(for: Locale.preferredLanguages)

    private static let koreanBundle: Bundle? = {
        guard language == "ko",
              let url = Bundle.main.url(forResource: "ko", withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }()

    static func text(_ english: String) -> String {
        koreanBundle?.localizedString(forKey: english, value: english, table: nil) ?? english
    }

    static func format(_ english: String, _ value: String) -> String {
        String(format: text(english), value)
    }

    static func errorCode(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
