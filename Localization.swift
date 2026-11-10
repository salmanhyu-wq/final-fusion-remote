import Foundation

/// Follows the operating system language: Korean when the user's first supported
/// preferred language is Korean, otherwise English.
enum AppLanguage {
    static let environmentKey = "FINAL_FUSION_LANGUAGE"

    static let isKorean: Bool = {
        if let forced = ProcessInfo.processInfo.environment[environmentKey]?.lowercased(), !forced.isEmpty {
            return forced.hasPrefix("ko")
        }
        for language in Locale.preferredLanguages {
            let code = language.lowercased()
            if code.hasPrefix("ko") { return true }
            if code.hasPrefix("en") { return false }
        }
        return false
    }()

    static var code: String { isKorean ? "ko" : "en" }
}

/// Returns the Korean or English text for the current OS language.
func L(_ korean: String, _ english: String) -> String {
    AppLanguage.isKorean ? korean : english
}
