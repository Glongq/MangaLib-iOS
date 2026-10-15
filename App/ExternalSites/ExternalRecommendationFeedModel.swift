import Foundation
import Combine

/// Feed filters inherit explicit language/category exclusions, independently of catalog search text.
struct ExternalRecommendationFeedFilter: Equatable {
    var languages: Set<ExternalCatalogLanguage> = []
    var excludedTypes: [ExternalSite: Set<String>] = [:]
    var excludedLanguages: [ExternalSite: Set<String>] = [:]
    var categoryBits: [ExternalSite: Int] = [:]

    @MainActor
    static func current(combined: Bool) -> Self {
        let store = ExternalCatalogFilterStore.shared
        let eh = combined ? store.combinedExcludedCategories : store.excludedCategories[.ehentai] ?? []
        let ih = combined ? store.combinedExcludedImhentaiCategories : store.excludedImhentaiCategories[.imhentai] ?? []
        let ihLanguages = combined ? store.combinedExcludedImhentaiLanguages : store.excludedImhentaiLanguages[.imhentai] ?? []
        return Self(
            languages: store.selectedLanguages,
            excludedTypes: [.ehentai: Set(eh.map { normalizeType($0.displayName) }),
                            .imhentai: Set(ih.map { normalizeType($0.displayName) })],
            excludedLanguages: [.imhentai: Set(ihLanguages.map { ExternalRecommendationFeature.normalize($0.displayName) })],
            categoryBits: [.ehentai: eh.reduce(0) { $0 | $1.bit },
                           .imhentai: ih.reduce(0) { $0 | $1.bit } | ihLanguages.reduce(0) { $0 | $1.bit }]
        )
    }

    func allows(_ detail: ExternalGalleryDetail) -> Bool {
        if excludedTypes[detail.site]?.contains(Self.normalizeType(detail.type)) == true { return false }
        if let language = detail.language,
           excludedLanguages[detail.site]?.contains(ExternalRecommendationFeature.normalize(language)) == true { return false }
        let detected = ExternalCatalogLanguage.detectAll(from: detail.language)
        return languages.isEmpty || detected.isEmpty || !detected.isDisjoint(with: languages)
    }

    private static func normalizeType(_ value: String) -> String {
        ExternalRecommendationFeature.normalize(value).filter { $0.isLetter || $0.isNumber }
    }
}

struct ExternalRecommendationFeedItem: Identifiable {
    let detail: ExternalGalleryDetail
    let document: ExternalRecommendationDocument
    var isComplete = true
    var id: String { document.id }
}

/// Retrieval, pagination and queue management live outside the paging views.
@MainActor
final class ExternalRecommendationFeedModel: ObservableObject {
    @Published private(set) var items: [ExternalRecommendationFeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeID: String?
    @Published private(set) var loadingPagesID: String?
    @Published private(set) var pageListErrorID: String?
    private(set) var sites: [ExternalSite] = []
    private var filter = ExternalRecommendationFeedFilter()
    private var pool: [String: ExternalRecommendationFeedItem] = [:]
    private var pending: [ExternalCatalogItem] = []
    private var requested = Set<String>()
    private var leasedCandidates: [String: ExternalCatalogItem] = [:]
    private var failedCandidates: [String: ExternalCatalogItem] = [:]
    private var displayed = Set<String>()
    private var displayedDuplicates = Set<String>()
    private var laneStates: [String: LaneState] = [:]
    private var loadTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailLoadToken = UUID()
    private var generation = UUID()
    private var laneRotation = 0
    private var presentationCount = 0
    private var isRunning = false
    private var retrievalInterests: [String] = []
    private var needsPersonalizedRetrieval = false
    private let store: ExternalRecommendationStore

    init(store: ExternalRecommendationStore? = nil) {
        self.store = store ?? .shared
    }

    private struct Lane: Identifiable {
        let site: ExternalSite
        var feature: ExternalRecommendationFeature?
        var secondFeature: ExternalRecommendationFeature?
        var seedGalleryID: Int?
        var pixivWorkType: String = "illust"
        var sortKey: String?
        var id: String { "\(site.rawValue)|\(feature?.id ?? "catalog")|\(secondFeature?.id ?? "")|\(pixivWorkType)|\(sortKey ?? "")" }
    }

    private struct LaneState {
        var cursor: String?
        var exhausted = false
        var failedAt: Date?
    }

    private struct ListingResult {
        let lane: Lane
        var ids: [Int] = []
        var nextCursor: String?
        var failed = false
    }

    private struct CandidateResult {
        let source: ExternalCatalogItem
        let item: ExternalRecommendationFeedItem?
    }

    func start(sites: [ExternalSite], filter: ExternalRecommendationFeedFilter) {
        guard !isRunning || self.sites != sites || self.filter != filter else { return }
        if self.sites != sites || self.filter != filter {
            stop()
            generation = UUID()
            self.sites = sites
            self.filter = filter
            items = []
            activeID = nil
            pool = [:]
            pending = []
            requested = []
            leasedCandidates = [:]
            failedCandidates = [:]
            displayed = []
            displayedDuplicates = []
            laneStates = [:]
            laneRotation = 0
            presentationCount = 0
            retrievalInterests = []
            needsPersonalizedRetrieval = false
        }
        isRunning = true
        synchronizeBookmarks()
        requestMore()
        loadActivePagesIfNeeded()
        let token = generation
        seedTask?.cancel()
        seedTask = Task { [weak self] in await self?.seedBookmarks(generation: token) }
    }

    func stop() {
        generation = UUID()
        isRunning = false
        loadTask?.cancel()
        loadTask = nil
        seedTask?.cancel()
        seedTask = nil
        detailTask?.cancel()
        detailTask = nil
        loadingPagesID = nil
        pageListErrorID = nil
        for item in leasedCandidates.values {
            requested.remove(item.id)
            if !pending.contains(where: { $0.id == item.id }) { pending.insert(item, at: 0) }
        }
        leasedCandidates = [:]
        isLoading = false
    }

    func activate(_ id: String) {
        guard activeID != id, let item = items.first(where: { $0.id == id }) else { return }
        activeID = id
        if displayed.insert(id).inserted {
            displayedDuplicates.insert(item.document.duplicateKey)
            presentationCount += 1
        }
        if let index = items.firstIndex(where: { $0.id == id }), index > 20 {
            items.removeFirst(index - 10)
        }
        if remainingCount < 6 { requestMore() }
        loadActivePagesIfNeeded()
    }

    func didChangePreferences() {
        let interests = ExternalRecommendationEngine(profile: store.profile).interests().map(\.id)
        if interests != retrievalInterests {
            retrievalInterests = interests
            needsPersonalizedRetrieval = true
        }
        rerank()
        if needsPersonalizedRetrieval || remainingCount < 8 || pool.count < 24 { requestMore() }
    }

    func synchronizeBookmarks() {
        store.synchronizeBookmarks(ExternalBookmarksStore.shared.bookmarks)
    }

    func retry() {
        for key in laneStates.keys {
            if laneStates[key]?.exhausted == true { laneStates[key] = LaneState() }
            else { laneStates[key]?.failedAt = nil }
        }
        for item in failedCandidates.values {
            requested.remove(item.id)
            if !pending.contains(where: { $0.id == item.id }) { pending.append(item) }
        }
        failedCandidates = [:]
        errorMessage = nil
        requestMore()
    }

    func loadMoreIfNeeded() {
        if remainingCount < 6 { requestMore() }
    }

    func retryActivePages() { loadActivePagesIfNeeded() }

    private var remainingCount: Int {
        guard let activeID, let index = items.firstIndex(where: { $0.id == activeID }) else { return items.count }
        return items.count - index - 1
    }

    private func requestMore() {
        guard isRunning, loadTask == nil, !sites.isEmpty else { return }
        isLoading = true
        let token = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            await fill(generation: token)
            guard generation == token else { return }
            loadTask = nil
            if needsPersonalizedRetrieval { requestMore() }
            else { isLoading = false }
        }
    }

    private func fill(generation token: UUID) async {
        errorMessage = nil
        let personalizing = needsPersonalizedRetrieval
        needsPersonalizedRetrieval = false
        for round in 0..<4 {
            guard !Task.isCancelled, generation == token else { return }
            if !pending.isEmpty && !(personalizing && round == 0) {
                await hydratePending(generation: token)
                rerank()
                if remainingCount >= 12 && pool.count >= 24 { break }
            }
            let lanes = nextLanes()
            guard !lanes.isEmpty else { break }
            let bits = filter.categoryBits
            await withTaskGroup(of: ListingResult.self) { group in
                for lane in lanes {
                    let cursor = laneStates[lane.id]?.cursor
                    group.addTask { await Self.fetchListing(lane, cursor: cursor, excludedBits: bits[lane.site] ?? 0) }
                }
                for await result in group {
                    guard !Task.isCancelled, generation == token else { group.cancelAll(); return }
                    if result.failed {
                        laneStates[result.lane.id, default: LaneState()].failedAt = Date()
                        continue
                    }
                    let oldCursor = laneStates[result.lane.id]?.cursor
                    laneStates[result.lane.id] = LaneState(
                        cursor: result.nextCursor,
                        exhausted: result.nextCursor == nil || result.nextCursor == oldCursor
                    )
                    var received: [ExternalCatalogItem] = []
                    for id in result.ids {
                        let item = ExternalCatalogItem(site: result.lane.site, galleryId: id)
                        if !requested.contains(item.id) && !pending.contains(where: { $0.id == item.id }) {
                            received.append(item)
                        }
                    }
                    if result.lane.feature != nil { pending.insert(contentsOf: received, at: 0) }
                    else { pending.append(contentsOf: received) }
                    // Publish the first usable source immediately, while other sources finish.
                    if remainingCount < 8 {
                        await hydratePending(generation: token)
                        rerank()
                    }
                }
            }
            guard !Task.isCancelled, generation == token else { return }
            await hydratePending(generation: token)
            rerank()
            if remainingCount >= 12 { break }
        }
        if remainingCount == 0 {
            errorMessage = sites == [.pixiv] && !PixivAuthStore.shared.isLoggedIn
                ? "Для рекомендаций Pixiv войди в аккаунт в настройках сайта."
                : "Новых тайтлов пока нет. Можно повторить поиск или проверить выбранные языки и скрытые теги."
        }
    }

    private func nextLanes() -> [Lane] {
        let engine = ExternalRecommendationEngine(profile: store.profile)
        let interests = engine.interests(limit: 10)
        var discovery: [Lane] = []
        var popular: [Lane] = []
        var personal: [Lane] = []
        for site in sites {
            if site == .pixiv && !PixivAuthStore.shared.isLoggedIn { continue }
            discovery.append(Lane(site: site))
            if site == .hitomi {
                popular.append(Lane(site: site, sortKey: HitomiProvider.SortOption.popularWeek.rawValue))
                popular.append(Lane(site: site, sortKey: HitomiProvider.SortOption.popularMonth.rawValue))
            }
            let topics = interests.filter { [.tag, .female, .male].contains($0.kind) }
            if topics.count >= 2 && [.ehentai, .imhentai, .threeHentai, .simplyHentai, .pixiv].contains(site) {
                // These providers support conjunctions without fetching an entire tag index.
                personal.append(Lane(site: site, feature: topics[0], secondFeature: topics[1]))
            }
            for feature in interests where feature.siteID == nil || feature.siteID == site.rawValue {
                if site == .pixiv && ![.tag, .female, .male, .artist].contains(feature.kind) { continue }
                let seed = feature.kind == .artist ? seedGalleryID(for: feature, site: site) : nil
                if site == .pixiv && feature.kind == .artist {
                    guard let seed else { continue }
                    personal += [Lane(site: site, feature: feature, seedGalleryID: seed, pixivWorkType: "illust"),
                                 Lane(site: site, feature: feature, seedGalleryID: seed, pixivWorkType: "manga")]
                } else {
                    personal.append(Lane(site: site, feature: feature, seedGalleryID: seed))
                }
            }
        }
        discovery += popular
        func available(_ lane: Lane) -> Bool {
            let state = laneStates[lane.id] ?? LaneState()
            return !state.exhausted && (state.failedAt.map { Date().timeIntervalSince($0) > 30 } ?? true)
        }
        discovery = discovery.filter(available)
        personal = personal.filter(available)
        var chosen: [Lane] = []
        if !personal.isEmpty {
            let start = laneRotation % personal.count
            chosen += (0..<min(2, personal.count)).map { personal[(start + $0) % personal.count] }
        }
        let capacity = 3 - chosen.count
        if !discovery.isEmpty {
            chosen += (0..<min(capacity, discovery.count)).map { discovery[(laneRotation + $0) % discovery.count] }
        }
        laneRotation += 1
        return chosen
    }

    private func seedGalleryID(for feature: ExternalRecommendationFeature, site: ExternalSite) -> Int? {
        if let item = pool.values.first(where: { $0.detail.site == site && $0.document.features.contains(where: { $0.id == feature.id }) }) {
            return item.detail.id
        }
        return store.profile.feedback.values.first {
            $0.document.siteID == site.rawValue && $0.document.features.contains(where: { $0.id == feature.id })
        }?.document.galleryID
    }

    nonisolated private static func fetchListing(_ lane: Lane, cursor: String?, excludedBits: Int) async -> ListingResult {
        let provider = ExternalSiteRegistry.provider(for: lane.site)
        do {
            let page: (ids: [Int], nextCursor: String?)
            if let feature = lane.feature {
                if let second = lane.secondFeature {
                    let query = combinationQuery([feature, second], for: lane.site)
                    page = try await provider.fetchIdsBySearch(query: query, excludedCategoryBits: excludedBits, cursor: cursor, limit: 24)
                } else if lane.site == .pixiv, feature.kind == .artist, let seed = lane.seedGalleryID {
                    page = try await PixivProvider().fetchFeedAuthorGalleryIDs(seedGalleryID: seed, type: lane.pixivWorkType, cursor: cursor)
                } else if lane.site == .pixiv {
                    page = try await provider.fetchIdsBySearch(query: feature.value, cursor: cursor, limit: 24)
                } else {
                    let namespace: ExternalTagNamespace
                    switch feature.kind {
                    case .tag, .format: namespace = .tag
                    case .female: namespace = .female
                    case .male: namespace = .male
                    case .artist: namespace = .artist
                    case .group: namespace = .group
                    case .character: namespace = .character
                    case .series: namespace = .series
                    }
                    let value = feature.siteID == nil && lane.site != .pixiv ? feature.alias ?? feature.value : feature.value
                    page = try await provider.fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: 24)
                }
            } else {
                page = try await provider.fetchIdsBySearch(query: "", excludedCategoryBits: excludedBits, sortKey: lane.sortKey, cursor: cursor, limit: 24)
            }
            return ListingResult(lane: lane, ids: page.ids, nextCursor: page.nextCursor)
        } catch {
            return ListingResult(lane: lane, failed: true)
        }
    }

    private func hydratePending(generation token: UUID) async {
        // Every source retains its unconsumed IDs; native page sizes are never discarded.
        let batch = Array(pending.prefix(9))
        pending.removeFirst(batch.count)
        for item in batch {
            requested.insert(item.id)
            leasedCandidates[item.id] = item
        }
        await withTaskGroup(of: CandidateResult.self) { group in
            var iterator = batch.makeIterator()
            func enqueue() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    let candidate = Task.isCancelled ? nil : try? await Self.fetchPreview(site: item.site, id: item.galleryId)
                    return CandidateResult(source: item, item: candidate)
                }
            }
            for _ in 0..<min(3, batch.count) { enqueue() }
            for await result in group {
                guard !Task.isCancelled, generation == token else { group.cancelAll(); return }
                leasedCandidates.removeValue(forKey: result.source.id)
                if result.item == nil { failedCandidates[result.source.id] = result.source }
                if let candidate = result.item, filter.allows(candidate.detail), !candidate.detail.pages.isEmpty {
                    let detail = candidate.detail
                    let document = candidate.document
                    let saved = ExternalBookmarksStore.shared.isBookmarked(site: detail.site, id: detail.id)
                    if saved { store.setBookmark(true, for: document) }
                    if !displayedDuplicates.contains(document.duplicateKey) {
                        pool[document.id] = candidate
                    }
                    rerank()
                }
                enqueue()
            }
        }
        if pool.count > 120 {
            let keep = Set(items.map(\.id))
            let removable = pool.keys.filter { !keep.contains($0) }
            for id in removable.prefix(pool.count - 100) { pool.removeValue(forKey: id) }
        }
    }

    private func rerank() {
        let engine = ExternalRecommendationEngine(profile: store.profile)
        let prefix: [ExternalRecommendationFeedItem]
        if let index = items.lastIndex(where: { displayed.contains($0.id) }) {
            // Going back must preserve every already-visited position, including forward navigation.
            prefix = Array(items.prefix(index + 1))
        } else {
            prefix = []
        }
        let candidates = pool.values.filter {
            !displayed.contains($0.id) && !displayedDuplicates.contains($0.document.duplicateKey) && filter.allows($0.detail)
        }.map(\.document)
        let ranked = engine.ranked(candidates, after: prefix.map(\.document), offset: presentationCount, limit: 16)
        items = prefix + ranked.compactMap { pool[$0.id] }
        if activeID == nil, let first = items.first { activate(first.id) }
    }

    private func seedBookmarks(generation token: UUID) async {
        let seeds = ExternalBookmarksStore.shared.bookmarks.filter {
            sites.contains($0.site) && store.profile.feedback[$0.id] == nil
        }.sorted { $0.addedAt > $1.addedAt }.prefix(12)
        for bookmark in seeds {
            guard !Task.isCancelled, generation == token else { return }
            let provider = ExternalSiteRegistry.provider(for: bookmark.site)
            if let key = bookmark.resolveKey { await provider.primeResolveKey(key, for: bookmark.galleryId) }
            if let candidate = try? await Self.fetchPreview(site: bookmark.site, id: bookmark.galleryId) {
                guard !Task.isCancelled, generation == token else { return }
                store.setBookmark(true, for: candidate.document)
            }
        }
        guard !Task.isCancelled, generation == token else { return }
        didChangePreferences()
    }

    nonisolated private static func fetchPreview(site: ExternalSite, id: Int) async throws -> ExternalRecommendationFeedItem {
        let provider = ExternalSiteRegistry.provider(for: site)
        if let ehentai = provider as? EHentaiProvider {
            let preview = try await ehentai.fetchRecommendationPreview(id: id)
            var document = preview.detail.recommendationDocument
            document.pageCount = preview.totalPages
            return ExternalRecommendationFeedItem(detail: preview.detail, document: document, isComplete: preview.detail.pages.count >= preview.totalPages)
        }
        let detail = try await provider.fetchGalleryDetail(id: id)
        return ExternalRecommendationFeedItem(detail: detail, document: detail.recommendationDocument)
    }

    nonisolated private static func combinationQuery(_ features: [ExternalRecommendationFeature], for site: ExternalSite) -> String {
        let values = features.map { site == .pixiv ? $0.value : $0.alias ?? $0.value }
        switch site {
        case .ehentai:
            return zip(features, values).map { feature, value in
                let namespace = feature.kind == .female ? "female" : feature.kind == .male ? "male" : "other"
                return "\(namespace):\(value.replacingOccurrences(of: " ", with: "+"))"
            }.joined(separator: " ")
        case .imhentai:
            var query = ImhentaiAdvancedQuery()
            query.tags = values
            return query.clauses().joined(separator: " ")
        case .simplyHentai:
            var query = SimplyHentaiAdvancedQuery()
            query.tags = values
            return query.encoded()
        case .threeHentai:
            var query = ThreeHentaiAdvancedQuery()
            query.tags = values
            return query.encoded()
        default:
            return values.joined(separator: " ")
        }
    }

    private func loadActivePagesIfNeeded() {
        detailTask?.cancel()
        detailTask = nil
        loadingPagesID = nil
        pageListErrorID = nil
        detailLoadToken = UUID()
        guard isRunning, let item = items.first(where: { $0.id == activeID }), !item.isComplete else { return }
        let token = generation
        let request = detailLoadToken
        loadingPagesID = item.id
        detailTask = Task { [weak self] in
            let provider = ExternalSiteRegistry.provider(for: item.detail.site)
            let detail = try? await provider.fetchGalleryDetail(id: item.detail.id)
            guard !Task.isCancelled, let self, generation == token, detailLoadToken == request, activeID == item.id else { return }
            loadingPagesID = nil
            guard let detail else { pageListErrorID = item.id; return }
            let full = ExternalRecommendationFeedItem(detail: detail, document: item.document, isComplete: detail.pages.count >= item.document.pageCount)
            if !full.isComplete { pageListErrorID = item.id }
            pool[item.id] = full
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = full }
        }
    }
}
