import Foundation

/// Конфигурация неофициального клиента для mangalib.org.
enum MangaLibConfig {
    static let siteHost = "mangalib.org"
    static let siteBaseURL = URL(string: "https://mangalib.org")!

    /// Базовый URL API (уточним по реальным запросам сайта на этапе Networking).
    static let apiBaseURL = URL(string: "https://api.mangalib.org")!

    static let defaultLocalePath = "ru"
}
