import Foundation

/// A title's declared original language, mapped from whatever free-form
/// string each `ExternalSiteProvider` scrapes into `ExternalGalleryDetail.
/// language` (e.g. "Japanese", "English, Japanese", "Chinese (Translated)")
/// — used to suggest matching the OCR source language (see
/// ExternalTranslationSettingsSheet.sourceLang) to the title actually being
/// read, instead of leaving it on a mismatched/"auto" value.
enum DetectedTitleLanguage: String, Equatable {
    case ja, ko, zh, en, ru

    /// Order matters: a raw string can list several languages at once
    /// (translated + original, e.g. "English, Japanese") — non-Latin
    /// source languages are checked first since they're the ones an OCR
    /// suggestion is actually useful for; `ru` is checked last purely so a
    /// title tagged "Russian, Japanese" still resolves to `.ja`.
    private static let keywordsByLanguage: [(DetectedTitleLanguage, [String])] = [
        (.ja, ["japan", "японск"]),
        (.ko, ["korea", "корейск"]),
        (.zh, ["chin", "mandarin", "китайск"]),
        (.en, ["english", "английск"]),
        (.ru, ["russian", "русск"]),
    ]

    static func detect(from rawLanguage: String?) -> DetectedTitleLanguage? {
        guard let rawLanguage, !rawLanguage.isEmpty else { return nil }
        let normalized = rawLanguage.lowercased()
        for (language, keywords) in keywordsByLanguage where keywords.contains(where: normalized.contains) {
            return language
        }
        return nil
    }

    var displayName: String {
        switch self {
        case .ja: return "Японский"
        case .ko: return "Корейский"
        case .zh: return "Китайский"
        case .en: return "Английский"
        case .ru: return "Русский"
        }
    }
}

/// Tracks which titles the user has already been asked about (see
/// TitleLanguageSuggestionCapsule) — one suggestion per title, ever,
/// regardless of the answer, so re-opening the same title doesn't nag
/// again. Deliberately just a flat set of "site_id" keys in UserDefaults,
/// not a full store class like ExternalBookmarksStore — there's no list to
/// display, just a "seen" check.
enum TitleLanguageSuggestionSeenStore {
    private static let defaultsKey = "external_reader_title_lang_suggestion_seen"

    private static func key(site: ExternalSite, id: Int) -> String { "\(site.rawValue)_\(id)" }

    static func hasBeenShown(site: ExternalSite, id: Int) -> Bool {
        let seen = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return seen.contains(key(site: site, id: id))
    }

    static func markShown(site: ExternalSite, id: Int) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        seen.insert(key(site: site, id: id))
        UserDefaults.standard.set(Array(seen), forKey: defaultsKey)
    }
}
