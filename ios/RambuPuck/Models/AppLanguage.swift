import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case indonesian = "id"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "id_ID") }
    var speechCode: String { self == .english ? "en-US" : "id-ID" }
    var displayName: String { self == .english ? "English" : "Bahasa Indonesia" }
    var backendCode: String { rawValue }

    static func preferred(from identifiers: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let first = identifiers.first?.lowercased() else { return .indonesian }
        return first == "en" || first.hasPrefix("en-") || first.hasPrefix("en_")
            ? .english : .indonesian
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        text(key, fallback: key, language: language)
    }

    static func text(
        _ key: String,
        fallback: String,
        language: AppLanguage
    ) -> String {
        guard language != .indonesian,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return fallback }
        return bundle.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        format(key, fallback: key, language: language, arguments: arguments)
    }

    static func format(
        _ key: String,
        fallback: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        format(key, fallback: fallback, language: language, arguments: arguments)
    }

    private static func format(
        _ key: String,
        fallback: String,
        language: AppLanguage,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: text(key, fallback: fallback, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }
}
