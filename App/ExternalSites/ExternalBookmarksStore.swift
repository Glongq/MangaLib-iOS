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
    /// nil = the "All" folder (root) — the same nil-value scheme as
    /// selectedFolderId in BookmarksView. An Optional field in Codable
    /// automatically decodes as nil for already-saved old entries that
    /// don't have this key — no migration needed.
    var folderId: String? = nil
    /// Opaque site-specific key some providers need to resolve THIS id
    /// without having browsed a listing containing it first this session
    /// (e-hentai's URL token, simplyHentai's slug — see
    /// ExternalSiteProvider.resolveKey(for:)/primeResolveKey(_:for:)). nil
    /// for sites that resolve purely from id (hitomi/imhentai/3hentai/
    /// hentaiPill) and for any bookmark saved before this field existed —
    /// Optional decodes as nil for old entries, no migration needed.
    var resolveKey: String? = nil

    var id: String { "\(site.rawValue)#\(galleryId)" }
}

/// A local bookmark folder for external sites — MUCH simpler than
/// BookmarkFolder (that one has 5 standard server-side folders + syncing):
/// here everything lives entirely in UserDefaults, just a name, no color/
/// visibility/server id (see the ExternalBookmarksStore doc-comment — these
/// sites have nowhere to get a server-side folder from at all).
struct ExternalBookmarkFolder: Codable, Identifiable, Hashable {
    let id: String
    var name: String
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
    @Published private(set) var folders: [ExternalBookmarkFolder] = []

    private static let storageKey = "external_bookmarks_v1"
    private static let foldersStorageKey = "external_bookmark_folders_v1"
    private let defaults = UserDefaults.standard

    private init() {
        load()
        loadFolders()
    }

    func isBookmarked(site: ExternalSite, id: Int) -> Bool {
        bookmarks.contains { $0.site == site && $0.galleryId == id }
    }

    /// The title's current folder (nil — not bookmarked OR sitting in
    /// "All") — used the same way as BookmarksStore.folderId(forSlug:) is,
    /// from ExternalAddToFolderSheet.
    func folderId(site: ExternalSite, id: Int) -> String? {
        bookmarks.first { $0.site == site && $0.galleryId == id }?.folderId
    }

    /// Display name of the title's folder, if it's in a NAMED one — nil
    /// both when not bookmarked and when it's sitting in the implicit
    /// "All" root (folderId == nil).
    func folderName(site: ExternalSite, id: Int) -> String? {
        guard let folderId = folderId(site: site, id: id) else { return nil }
        return folders.first { $0.id == folderId }?.name
    }

    /// Badge label for the catalog card / gallery cover — UNLIKE
    /// MangaCardView.statusBadge/MangaDetailView.bookmarkStatusBadge (nil
    /// unless in a NAMED folder, since the main app always assigns one of
    /// 5 standard folders), here most bookmarks just sit in the implicit
    /// "All" root (no folders exist unless the user makes one) — showing
    /// nothing there would make the badge look entirely absent for the
    /// common case. Falls back to a generic "В закладках" whenever the
    /// title is bookmarked at all, regardless of folder.
    func bookmarkBadgeLabel(site: ExternalSite, id: Int) -> String? {
        guard isBookmarked(site: site, id: id) else { return nil }
        return folderName(site: site, id: id) ?? "В закладках"
    }

    func toggle(_ detail: ExternalGalleryDetail) async {
        if isBookmarked(site: detail.site, id: detail.id) {
            remove(site: detail.site, id: detail.id)
        } else {
            await add(detail)
        }
    }

    /// Also reads back this site's resolveKey (see the protocol doc-
    /// comment) — the caller (ExternalGalleryDetailView) already has the
    /// full detail loaded, meaning the provider's own cache is populated
    /// RIGHT NOW, this is the one moment it's guaranteed to be available.
    func add(_ detail: ExternalGalleryDetail, toFolder folderId: String? = nil) async {
        let key = await ExternalSiteRegistry.provider(for: detail.site).resolveKey(for: detail.id)
        add(site: detail.site, galleryId: detail.id, title: detail.title,
            coverURL: detail.coverURL?.absoluteString, type: detail.type, toFolder: folderId, resolveKey: key)
    }

    /// Тот же add(_:toFolder:), но по отдельным полям, а не полному
    /// ExternalGalleryDetail — нужен из списка закладок (ExternalBookmarksView),
    /// где для смены папки уже забукмарканного тайтла нет и не нужен полный
    /// detail (со страницами/тегами/...), только то, что и так лежит в
    /// самой ExternalBookmark (см. ExternalAddToFolderSheet). `resolveKey`
    /// пробрасывается явно (а не читается тут же из провайдера), т.к.
    /// вызывающий может обновлять УЖЕ существующую закладку — тогда ключ
    /// нужно взять из неё самой (bm.resolveKey), а не пытаться заново
    /// вытащить из кэша провайдера, который к этому моменту мог уже
    /// протухнуть/очиститься.
    func add(site: ExternalSite, galleryId: Int, title: String, coverURL: String?, type: String, toFolder folderId: String? = nil, resolveKey: String? = nil) {
        guard !isBookmarked(site: site, id: galleryId) else {
            move(site: site, id: galleryId, toFolder: folderId)
            return
        }
        let bookmark = ExternalBookmark(
            site: site, galleryId: galleryId, title: title, coverURL: coverURL, type: type,
            addedAt: Date(), folderId: folderId, resolveKey: resolveKey
        )
        // Newest on top (the same order as "By date added" in
        // regular bookmarks, see BookmarksSortOption.dateAdded).
        bookmarks.insert(bookmark, at: 0)
        save()
    }

    /// Переместить уже сохранённую закладку в другую папку (или в «Все»,
    /// если folderId == nil) — используется ExternalAddToFolderSheet при
    /// повторном открытии уже забукмаркленного тайтла.
    func move(site: ExternalSite, id: Int, toFolder folderId: String?) {
        guard let idx = bookmarks.firstIndex(where: { $0.site == site && $0.galleryId == id }) else { return }
        bookmarks[idx].folderId = folderId
        save()
    }

    func remove(site: ExternalSite, id: Int) {
        bookmarks.removeAll { $0.site == site && $0.galleryId == id }
        save()
    }

    // MARK: Папки — та же схема nil="Все", что и BookmarksStore.allFolders/
    // titles(in:)/titlesCount(in:), но без серверной синхронизации.

    func titlesCount(in folderId: String?) -> Int {
        guard let folderId else { return bookmarks.count }
        return bookmarks.filter { $0.folderId == folderId }.count
    }

    func titles(in folderId: String?) -> [ExternalBookmark] {
        guard let folderId else { return bookmarks }
        return bookmarks.filter { $0.folderId == folderId }
    }

    @discardableResult
    func createFolder(name: String) -> ExternalBookmarkFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = ExternalBookmarkFolder(id: UUID().uuidString, name: trimmed)
        folders.append(folder)
        saveFolders()
        return folder
    }

    func renameFolder(_ folderId: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[idx].name = trimmed
        saveFolders()
    }

    /// Удаляет папку; тайтлы, лежавшие в ней, возвращаются в «Все» (nil) —
    /// они НЕ удаляются из закладок целиком, та же логика, что и у
    /// BookmarksStore.deleteFolder(moveTo:).
    func deleteFolder(_ folderId: String) {
        folders.removeAll { $0.id == folderId }
        for idx in bookmarks.indices where bookmarks[idx].folderId == folderId {
            bookmarks[idx].folderId = nil
        }
        saveFolders()
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

    private func loadFolders() {
        guard let data = defaults.data(forKey: Self.foldersStorageKey),
              let decoded = try? JSONDecoder().decode([ExternalBookmarkFolder].self, from: data) else { return }
        folders = decoded
    }

    private func saveFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        defaults.set(data, forKey: Self.foldersStorageKey)
    }
}
