import Foundation
import Combine

// These deterministic providers replace the registry only in the standalone test executable.
struct ExternalCatalogItem: Identifiable, Hashable {
    let site: ExternalSite
    let galleryId: Int
    var id: String { "\(site.rawValue)#\(galleryId)" }
}

struct ExternalBookmark {
    let site: ExternalSite
    let galleryId: Int
    let addedAt: Date
    var resolveKey: String?
    var id: String { "\(site.rawValue)#\(galleryId)" }
}

@MainActor final class ExternalBookmarksStore {
    static let shared = ExternalBookmarksStore()
    var bookmarks: [ExternalBookmark] = []
    func isBookmarked(site: ExternalSite, id: Int) -> Bool { bookmarks.contains { $0.site == site && $0.galleryId == id } }
}

enum EHentaiCategory: Hashable { case manga; var bit: Int { 4 }; var displayName: String { "Manga" } }
enum ImhentaiCategory: Hashable { case manga; var bit: Int { 1 << 10 }; var displayName: String { "Manga" } }
enum ImhentaiLanguage: Hashable { case japanese; var bit: Int { 1 << 17 }; var displayName: String { "Japanese" } }

@MainActor final class ExternalCatalogFilterStore {
    static let shared = ExternalCatalogFilterStore()
    var selectedLanguages: Set<ExternalCatalogLanguage> = []
    var combinedExcludedCategories: Set<EHentaiCategory> = []
    var combinedExcludedImhentaiCategories: Set<ImhentaiCategory> = []
    var combinedExcludedImhentaiLanguages: Set<ImhentaiLanguage> = []
    var excludedCategories: [ExternalSite: Set<EHentaiCategory>] = [:]
    var excludedImhentaiCategories: [ExternalSite: Set<ImhentaiCategory>] = [:]
    var excludedImhentaiLanguages: [ExternalSite: Set<ImhentaiLanguage>] = [:]
}

struct ImhentaiAdvancedQuery { var tags: [String] = []; func clauses() -> [String] { tags.map { "+tag:\"\($0)\"" } } }
struct SimplyHentaiAdvancedQuery { var tags: [String] = []; func encoded() -> String { tags.joined(separator: ",") } }
struct ThreeHentaiAdvancedQuery { var tags: [String] = []; func encoded() -> String { tags.joined(separator: ",") } }
@MainActor final class PixivAuthStore { static let shared = PixivAuthStore(); var isLoggedIn = true }

private func gallery(site: ExternalSite, id: Int, pages: Int = 10, language: String = "English") -> ExternalGalleryDetail {
    ExternalGalleryDetail(
        id: id, site: site, title: "Fixture \(id)", type: "Manga", language: language,
        tags: [.init(name: "topic", female: false, male: false), .init(name: "second topic", female: false, male: false)],
        artists: ["Author \(site.rawValue)"], groups: [], characters: [], series: [], related: [],
        pages: (0..<pages).map { .init(index: $0, key: "page-\($0)", width: 720, height: 1000, thumbnailURL: nil, thumbnailSpriteOffsetX: nil) },
        coverURL: nil, posted: nil, parentId: nil, visible: nil, fileSize: nil,
        favoritedCount: nil, ratingAverage: nil, ratingCount: nil, comments: []
    )
}

actor FixtureNetwork {
    static let shared = FixtureNetwork()
    struct Call { let site: ExternalSite; let kind: String; let cursor: String?; let id: Int? }
    private(set) var calls: [Call] = []
    var failing: Set<ExternalSite> = []
    var slow: Set<ExternalSite> = []
    var failingFull: Set<ExternalSite> = []

    func configure(failing: Set<ExternalSite> = [], slow: Set<ExternalSite> = [], failingFull: Set<ExternalSite> = []) {
        calls = []
        self.failing = failing
        self.slow = slow
        self.failingFull = failingFull
    }

    func list(site: ExternalSite, kind: String, cursor: String?) async throws -> (ids: [Int], nextCursor: String?) {
        calls.append(.init(site: site, kind: kind, cursor: cursor, id: nil))
        if failing.contains(site) { throw URLError(.cannotConnectToHost) }
        if slow.contains(site) {
            // Deliberately non-cooperative to test generation checks after cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
            }
        }
        let page = Int(cursor ?? "0") ?? 0
        guard page < 5 else { return ([], nil) }
        let first = page * 25 + (kind == "artist" ? 200 : 1)
        return (Array(first..<(first + 25)), String(page + 1))
    }

    func detail(site: ExternalSite, id: Int, preview: Bool) async throws -> ExternalGalleryDetail {
        calls.append(.init(site: site, kind: preview ? "preview" : "detail", cursor: nil, id: id))
        if !preview && failingFull.contains(site) { throw URLError(.networkConnectionLost) }
        if site == .ehentai && !preview { try await Task.sleep(for: .milliseconds(220)) }
        return gallery(site: site, id: id, pages: site == .ehentai && preview ? 2 : 10)
    }
}

struct FixtureProvider: ExternalSiteProvider {
    var site: ExternalSite = .pixiv
    enum SortOption: String { case popularWeek, popularMonth }
    var capabilities: ExternalSiteCapabilities {
        .init(hasCatalog: true, hasTagBrowser: true, hasSearch: true, hasCategoryFilter: true,
              hasPageJump: true, hasSortOptions: true, hasBookmarks: false, hasHistory: false,
              hasNotifications: false, hasComments: false, typicalPageSize: 25)
    }
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] { [] }
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] { [] }
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await FixtureNetwork.shared.list(site: site, kind: namespace == .artist ? "artist" : "tag", cursor: cursor)
    }
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await FixtureNetwork.shared.list(site: site, kind: query.isEmpty ? "catalog" : "search", cursor: cursor)
    }
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        try await FixtureNetwork.shared.detail(site: site, id: id, preview: false)
    }
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL { URL(string: "https://example.test/image")! }
    static func feedArtistID(for galleryID: Int) -> Int? { galleryID }
    func fetchFeedAuthorGalleryIDs(seedGalleryID: Int, type: String, cursor: String?) async throws -> (ids: [Int], nextCursor: String?) {
        try await FixtureNetwork.shared.list(site: site, kind: "artist", cursor: cursor)
    }
}

typealias HitomiProvider = FixtureProvider
typealias PixivProvider = FixtureProvider

struct EHentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .ehentai
    private var base: FixtureProvider { FixtureProvider(site: site) }
    var capabilities: ExternalSiteCapabilities { base.capabilities }
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] { [] }
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] { [] }
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await base.fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: limit)
    }
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await base.fetchIdsBySearch(query: query, cursor: cursor, limit: limit)
    }
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail { try await base.fetchGalleryDetail(id: id) }
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL { try await base.pageImageURL(galleryId: galleryId, page: page) }
    func fetchRecommendationPreview(id: Int) async throws -> (detail: ExternalGalleryDetail, totalPages: Int) {
        (try await FixtureNetwork.shared.detail(site: site, id: id, preview: true), 10)
    }
}

enum ExternalSiteRegistry {
    static func provider(for site: ExternalSite) -> any ExternalSiteProvider {
        if site == .ehentai { return EHentaiProvider() }
        return FixtureProvider(site: site)
    }
}

@main
struct ExternalRecommendationFeedTests {
    @MainActor
    static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 4,
                          file: StaticString = #file, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out waiting for the feed", file: file, line: line)
    }

    @MainActor
    static func main() async {
        let suite = "external-recommendation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExternalRecommendationStore(defaults: defaults)
        let model = ExternalRecommendationFeedModel(store: store)

        await FixtureNetwork.shared.configure()
        model.start(sites: [.imhentai], filter: .init())
        await waitUntil { model.items.count >= 9 && !model.isLoading }
        let initialCallCount = await FixtureNetwork.shared.calls.count
        model.start(sites: [.imhentai], filter: .init())
        try? await Task.sleep(for: .milliseconds(30))
        let repeatedCallCount = await FixtureNetwork.shared.calls.count
        precondition(repeatedCallCount == initialCallCount, "Repeated appearance callbacks must not restart an active feed")
        let original = model.activeID!
        let visited = Array(model.items.prefix(3).map(\.id))
        model.activate(visited[1])
        model.activate(visited[2])
        model.activate(visited[1])
        model.didChangePreferences()
        precondition(Array(model.items.prefix(3).map(\.id)) == visited, "Returning to an earlier title must preserve already-visited forward positions")
        model.activate(original)
        await waitUntil { !model.isLoading }
        let upcoming = model.items[3]
        let beforePaging = model.items.map(\.id)
        model.setPaging(true)
        store.toggleVote(.dislike, for: upcoming.document)
        model.didChangePreferences()
        try? await Task.sleep(for: .milliseconds(40))
        precondition(model.items.map(\.id) == beforePaging, "Ranking must not replace a gallery during an interactive page transition")
        model.setPaging(false)
        await waitUntil { !model.isLoading }
        precondition(!model.items.contains { $0.id == upcoming.id }, "Deferred ranking must apply after the gesture finishes")
        store.toggleVote(.dislike, for: upcoming.document)
        model.didChangePreferences()
        await waitUntil { !model.isLoading }
        let current = model.items.first { $0.id == original }!
        store.toggleVote(.like, for: current.document)
        model.didChangePreferences()
        await waitUntil { !model.isLoading }
        precondition(model.activeID == original, "Feedback must preserve the active gallery")
        let personalizedCalls = await FixtureNetwork.shared.calls
        precondition(personalizedCalls.contains { $0.kind == "artist" || $0.kind == "tag" }, "Feedback must retrieve new candidates, not only reorder a static batch")
        for _ in 0..<5 {
            if let next = model.items.last { model.activate(next.id) }
            model.loadMoreIfNeeded()
            await waitUntil { !model.isLoading }
        }
        let paginatedCalls = await FixtureNetwork.shared.calls
        precondition(paginatedCalls.contains { $0.cursor != nil }, "Retrieval must advance beyond the first catalog page")
        let restored = ExternalRecommendationStore(defaults: defaults)
        precondition(restored.vote(for: current.document) == .like, "Feedback must survive a new store instance")
        model.stop()

        await FixtureNetwork.shared.configure(failing: [.hitomi])
        let fallback = ExternalRecommendationFeedModel(store: ExternalRecommendationStore(defaults: .init(suiteName: suite + "-fallback")!))
        fallback.start(sites: [.hitomi, .imhentai], filter: .init())
        await waitUntil { !fallback.items.isEmpty }
        precondition(fallback.items.allSatisfy { $0.detail.site == .imhentai }, "A broken source must not prevent another source from producing a feed")
        fallback.stop()
        defaults.removePersistentDomain(forName: suite + "-fallback")

        await FixtureNetwork.shared.configure(slow: [.hitomi])
        let cancellation = ExternalRecommendationFeedModel(store: ExternalRecommendationStore(defaults: .init(suiteName: suite + "-cancel")!))
        cancellation.start(sites: [.hitomi], filter: .init())
        try? await Task.sleep(for: .milliseconds(25))
        cancellation.stop()
        cancellation.start(sites: [.imhentai], filter: .init())
        await waitUntil { !cancellation.items.isEmpty && !cancellation.isLoading }
        try? await Task.sleep(for: .milliseconds(400))
        precondition(cancellation.items.allSatisfy { $0.detail.site == .imhentai }, "Late canceled responses must never contaminate the new source")
        cancellation.stop()
        defaults.removePersistentDomain(forName: suite + "-cancel")

        await FixtureNetwork.shared.configure()
        let partial = ExternalRecommendationFeedModel(store: ExternalRecommendationStore(defaults: .init(suiteName: suite + "-partial")!))
        partial.start(sites: [.ehentai], filter: .init())
        await waitUntil { !partial.items.isEmpty }
        let initial = partial.items.first!
        precondition(initial.document.pageCount == 10 && initial.detail.pages.count == 2, "Preview metadata must preserve the real page count")
        await waitUntil { partial.items.first?.isComplete == true }
        await waitUntil { !partial.isLoading }
        precondition(partial.items.first?.isComplete == true, "Async ranking must not replace completed page metadata with an older preview")
        let detailCalls = await FixtureNetwork.shared.calls.filter { $0.kind == "detail" }
        precondition(detailCalls.count == 1, "Only the visible gallery should fetch its complete page list")
        precondition(partial.activeID == initial.id, "Completing page metadata must not change the active gallery")
        partial.stop()
        defaults.removePersistentDomain(forName: suite + "-partial")

        await FixtureNetwork.shared.configure(failingFull: [.ehentai])
        let retry = ExternalRecommendationFeedModel(store: ExternalRecommendationStore(defaults: .init(suiteName: suite + "-retry")!))
        retry.start(sites: [.ehentai], filter: .init())
        await waitUntil { retry.pageListErrorID != nil }
        let retryID = retry.activeID
        await FixtureNetwork.shared.configure()
        retry.retryActivePages()
        await waitUntil { retry.items.first?.isComplete == true }
        precondition(retry.activeID == retryID && retry.pageListErrorID == nil, "Page-list retries must recover without resetting the gallery")
        retry.stop()
        defaults.removePersistentDomain(forName: suite + "-retry")

        let languageFilter = ExternalRecommendationFeedFilter(languages: [.english])
        precondition(!languageFilter.allows(gallery(site: .imhentai, id: 1, language: "Japanese")), "Language filters must apply to recommendation candidates")
        let categoryFilter = ExternalRecommendationFeedFilter(excludedTypes: [.imhentai: ["manga"]])
        precondition(!categoryFilter.allows(gallery(site: .imhentai, id: 1)), "Category exclusions must apply to personalized retrieval too")
        print("External recommendation feed: all checks passed")
    }
}
