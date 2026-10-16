import Foundation
import Combine

/// A compact local reading position. Images and complete page lists are never persisted.
struct ExternalHistoryEntry: Codable, Identifiable, Hashable {
    let site: ExternalSite
    let galleryID: Int
    var title: String
    var coverURL: String?
    var type: String
    var lastViewedAt: Date
    var page: Int?
    var pageCount: Int
    var resolveKey: String?

    var id: String { "\(site.rawValue)#\(galleryID)" }
}

@MainActor
final class ExternalHistoryStore: ObservableObject {
    static let shared = ExternalHistoryStore()
    @Published private(set) var entries: [ExternalHistoryEntry]
    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private static let storageKey = "external_reading_history_v1"
    private static let migrationKey = "external_reading_history_imported_feedback_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([ExternalHistoryEntry].self, from: $0) } ?? []
    }

    func record(_ detail: ExternalGalleryDetail, page: Int? = nil, pageCount: Int? = nil, resolveKey: String? = nil) {
        record(document: detail.recommendationDocument, detail: detail, page: page,
               pageCount: pageCount, resolveKey: resolveKey)
    }

    func record(document: ExternalRecommendationDocument, detail: ExternalGalleryDetail? = nil,
                page: Int? = nil, pageCount: Int? = nil, resolveKey: String? = nil) {
        guard let site = ExternalSite(rawValue: document.siteID) else { return }
        let previous = entries.first { $0.id == document.id }
        let total = max(0, pageCount ?? document.pageCount)
        let entry = ExternalHistoryEntry(
            site: site, galleryID: document.galleryID, title: document.title,
            coverURL: detail?.coverURL?.absoluteString ?? previous?.coverURL,
            type: detail?.type ?? previous?.type ?? "", lastViewedAt: Date(),
            page: page.map { min(max(1, $0), max(1, total)) } ?? previous?.page,
            pageCount: total, resolveKey: resolveKey ?? previous?.resolveKey
        )
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        scheduleSave()
    }

    /// Refresh an old history card after opening it, without changing its reading date or position.
    func updateMetadata(_ detail: ExternalGalleryDetail, resolveKey: String?) {
        guard let index = entries.firstIndex(where: { $0.site == detail.site && $0.galleryID == detail.id }) else { return }
        var entry = entries[index]
        entry.title = detail.title
        entry.coverURL = detail.coverURL?.absoluteString ?? entry.coverURL
        entry.type = detail.type
        entry.pageCount = detail.pages.count
        entry.resolveKey = resolveKey ?? entry.resolveKey
        if let page = entry.page { entry.page = min(page, max(1, entry.pageCount)) }
        guard entry != entries[index] else { return }
        entries[index] = entry
        scheduleSave()
    }

    /// Existing feedback provides real dates and titles; unique-page counts are not page positions.
    func importLegacyFeedback(_ profile: ExternalRecommendationProfile, bookmarks: [ExternalBookmark]) {
        let importReadHistory = !defaults.bool(forKey: Self.migrationKey)
        var imported = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in profile.feedback.values where record.vote == .like || (importReadHistory && record.lastSeen != nil) {
            let document = record.document
            guard imported[document.id] == nil, let site = ExternalSite(rawValue: document.siteID) else { continue }
            let bookmark = saved[document.id]
            imported[document.id] = ExternalHistoryEntry(
                site: site, galleryID: document.galleryID, title: document.title,
                coverURL: bookmark?.coverURL, type: bookmark?.type ?? "",
                lastViewedAt: record.lastSeen ?? record.likedAt ?? record.updatedAt,
                page: nil, pageCount: document.pageCount, resolveKey: bookmark?.resolveKey
            )
        }
        if imported.count != entries.count {
            entries = imported.values.sorted {
                $0.lastViewedAt == $1.lastViewedAt ? $0.id < $1.id : $0.lastViewedAt > $1.lastViewedAt
            }
            dirty = true
        }
        flush()
        defaults.set(true, forKey: Self.migrationKey)
    }

    /// Coalesce fast page turns; reader dismissal and backgrounding flush the final position.
    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            persist()
            saveTask = nil
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func persist() {
        guard dirty, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
        dirty = false
    }
}
