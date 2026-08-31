import Foundation

/// Один локально сохранённый тайтл внешнего сайта — у hitomi/e-hentai/
/// 3hentai/imhentai нет аккаунтов (см. ExternalSiteCapabilities.
/// hasBookmarks — всегда честно false), поэтому «закладки» здесь ЦЕЛИКОМ
/// локальные (UserDefaults, JSON), без всякой синхронизации с сайтом — по
/// прямой просьбе (31.08): "реализуй ЛОКАЛЬНЫЙ раздел закладок". Хранит
/// достаточно метаданных, чтобы отрисовать карточку СРАЗУ, без повторного
/// похода в сеть (title/coverURL/type) — тот же принцип, что и у
/// BookmarkedTitle (см. BookmarksStore.swift) для обычной экосистемы Lib.
struct ExternalBookmark: Codable, Identifiable, Hashable {
    let site: ExternalSite
    let galleryId: Int
    var title: String
    var coverURL: String?
    var type: String
    let addedAt: Date

    var id: String { "\(site.rawValue)#\(galleryId)" }
}

/// Локальное хранилище закладок внешних сайтов — по образцу BookmarksStore
/// (тот же singleton-паттерн: `.shared`, @Published-массив, персист в
/// UserDefaults), но НАМЕРЕННО отдельный класс/файл: BookmarksStore целиком
/// завязан на реальный аккаунт/сервер Lib.social (папки, синхронизация,
/// bulk-операции) — здесь этого нет и быть не может, только простой
/// локальный список без папок (см. план внешних сайтов — новый код почти
/// не пересекается со старым).
@MainActor
final class ExternalBookmarksStore: ObservableObject {
    static let shared = ExternalBookmarksStore()

    @Published private(set) var bookmarks: [ExternalBookmark] = []

    private static let storageKey = "external_bookmarks_v1"
    private let defaults = UserDefaults.standard

    private init() {
        load()
    }

    func isBookmarked(site: ExternalSite, id: Int) -> Bool {
        bookmarks.contains { $0.site == site && $0.galleryId == id }
    }

    func toggle(_ detail: ExternalGalleryDetail) {
        if isBookmarked(site: detail.site, id: detail.id) {
            remove(site: detail.site, id: detail.id)
        } else {
            add(detail)
        }
    }

    func add(_ detail: ExternalGalleryDetail) {
        guard !isBookmarked(site: detail.site, id: detail.id) else { return }
        let bookmark = ExternalBookmark(
            site: detail.site,
            galleryId: detail.id,
            title: detail.title,
            coverURL: detail.coverURL?.absoluteString,
            type: detail.type,
            addedAt: Date()
        )
        // Новые — сверху (тот же порядок, что "По дате добавления" в
        // обычных закладках, см. BookmarksSortOption.dateAdded).
        bookmarks.insert(bookmark, at: 0)
        save()
    }

    func remove(site: ExternalSite, id: Int) {
        bookmarks.removeAll { $0.site == site && $0.galleryId == id }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ExternalBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
