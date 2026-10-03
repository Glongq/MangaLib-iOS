import Foundation

/// One locally saved title from an external site — hitomi/e-hentai/
/// 3hentai/imhentai have no accounts (see ExternalSiteCapabilities.
/// hasBookmarks — always honestly false), so "bookmarks" here are ENTIRELY
/// local (UserDefaults, JSON), with no syncing to the site at all — per a
/// direct request (08/31): "implement a LOCAL bookmarks section". Stores
/// enough metadata to render a card IMMEDIATELY, without a repeated network
/// round trip (title/coverURL/type) — the same principle as
/// BookmarkedTitle (see BookmarksStore.swift) for the regular Lib ecosystem.
struct ExternalBookmark: Codable, Identifiable, Hashable {
    let site: ExternalSite
    let galleryId: Int
    var title: String
    var coverURL: String?
    var type: String
    let addedAt: Date

    var id: String { "\(site.rawValue)#\(galleryId)" }
}

/// Local storage for external-site bookmarks — modeled on BookmarksStore
/// (the same singleton pattern: `.shared`, a @Published array, persisted to
/// UserDefaults), but DELIBERATELY a separate class/file: BookmarksStore is
/// entirely tied to a real Lib.social account/server (folders, syncing,
/// bulk operations) — none of that exists or can exist here, just a simple
/// local list with no folders (see the external-sites plan — the new code
/// barely overlaps with the old).
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
        // Newest on top (the same order as "By date added" in
        // regular bookmarks, see BookmarksSortOption.dateAdded).
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
