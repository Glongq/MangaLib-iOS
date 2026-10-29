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
        return ExternalCatalogLanguage.matches(rawLanguage: detail.language, selected: languages)
    }

    private static func normalizeType(_ value: String) -> String {
        ExternalRecommendationFeature.normalize(value).filter { $0.isLetter || $0.isNumber }
    }
}

struct ExternalRecommendationFeedItem: Identifiable {
    let detail: ExternalGalleryDetail
    let document: ExternalRecommendationDocument
    var isComplete = true
    var origins: [RecommendationOrigin] = []
    var selectedOrigin: RecommendationOrigin?
    var id: String { document.id }
}

/// Ranking never runs on the main actor, including profile evidence construction.
private actor ExternalRecommendationRankingWorker {
    struct Result: Sendable {
        let ranked: [RecommendationSelection]
        let interests: [ExternalRecommendationFeature]
        let topics: [[ExternalRecommendationFeature]]
        let groups: [RecommendationInterest]
        let policy: RecommendationChannelPolicy
        let interestAssignments: [String: String]
        static var empty: Self {
            Self(ranked: [], interests: [], topics: [], groups: [], policy: .init(), interestAssignments: [:])
        }
    }

    private var cachedKey: String?
    private var cachedEngine: ExternalRecommendationEngine?

    func rank(profile: ExternalRecommendationProfile, revision: Int, snapshot: LearningSnapshot, learningRevision: Int,
              candidates: [ExternalRecommendationDocument], origins: [String: [RecommendationOrigin]],
              recent: [ExternalRecommendationDocument], offset: Int) -> Result {
        guard !Task.isCancelled else { return .empty }
        let key = "\(revision)|\(learningRevision)|\(LearningSnapshot.algorithmVersion)"
        if cachedKey != key || cachedEngine.map({ Date().timeIntervalSince($0.now) > 60 }) != false {
            let now = Date()
            let learning = ExternalRecommendationLearningModel(profile: profile, snapshot: snapshot, now: now)
            guard !Task.isCancelled else { return .empty }
            cachedEngine = ExternalRecommendationEngine(profile: profile, learning: learning, now: now)
            cachedKey = key
        }
        let engine = cachedEngine!
        let ranked = Task.isCancelled ? [] : engine.ranked(candidates, origins: origins, after: recent, offset: offset,
                                                          seed: RecommendationMath.hash(key), limit: 16)
        let interests = engine.interests(rotation: offset)
        let assignments = Dictionary(uniqueKeysWithValues: interests.map { ($0.id, engine.learning.interestID(for: [$0])) })
        return Result(ranked: ranked, interests: interests, topics: engine.interestGroups(),
                      groups: engine.learning.interests, policy: engine.learning.policy, interestAssignments: assignments)
    }
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
    private var savedResolveKeys: [String: String] = [:]
    private var candidateOrigins: [String: [RecommendationOrigin]] = [:]
    private var discoveryScope = ""
    private let discoveryStore: ExternalRecommendationDiscoveryStore
    private var loadTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var rankingTask: Task<Void, Never>?
    private let rankingWorker = ExternalRecommendationRankingWorker()
    private var rankingRevision = 0
    private var rankAgain = false
    private var isRetrieving = false { didSet { updateLoadingState() } }
    private var isRanking = false { didSet { updateLoadingState() } }
    private var detailLoadToken = UUID()
    private var generation = UUID()
    private var laneRotation = 0
    private var presentationCount = 0
    private var isRunning = false
    private var isPaging = false
    private var retrievalInterests: [String] = []
    private var retrievalFeatures: [ExternalRecommendationFeature] = []
    private var retrievalTopics: [[ExternalRecommendationFeature]] = []
    private var retrievalGroups: [RecommendationInterest] = []
    private var retrievalAssignments: [String: String] = [:]
    private var channelPolicy = RecommendationChannelPolicy()
    private var needsPersonalizedRetrieval = false
    private let store: ExternalRecommendationStore

    init(store: ExternalRecommendationStore? = nil, discoveryStore: ExternalRecommendationDiscoveryStore? = nil) {
        self.store = store ?? .shared
        self.discoveryStore = discoveryStore ?? ExternalRecommendationDiscoveryStore()
    }

    private struct Lane: Identifiable {
        let site: ExternalSite
        var feature: ExternalRecommendationFeature?
        var secondFeature: ExternalRecommendationFeature?
        var seedGalleryID: Int?
        var pixivWorkType: String = "illust"
        var sortKey: String?
        var depth: ExternalRecommendationDepth = .latest
        var channel = RecommendationChannel(kind: .catalog)
        var samplesCorpus = false
        var id: String { "\(site.rawValue)|\(queryKey(feature, fallback: "catalog"))|\(queryKey(secondFeature, fallback: ""))|\(pixivWorkType)|\(sortKey ?? "")|\(depth.rawValue)" }

        private func queryKey(_ feature: ExternalRecommendationFeature?, fallback: String) -> String {
            guard let feature else { return fallback }
            // Pixiv searches the original label, even when its translated alias is shared elsewhere.
            return site == .pixiv ? "\(feature.retrievalID)|\(ExternalRecommendationFeature.normalize(feature.value))" : feature.retrievalID
        }

        var topicID: String { feature?.id ?? "catalog" }
        var origin: RecommendationOrigin {
            RecommendationOrigin(queryID: id, siteID: site.rawValue, depth: depth,
                                 channel: channel, samplesCorpus: samplesCorpus)
        }
    }

    private typealias LaneState = ExternalRecommendationDiscoveryState

    private struct ListingResult {
        let lane: Lane
        var ids: [Int] = []
        var nextCursor: String?
        var failed = false
        var requestedPage: Int?
        var resolveKeys: [Int: String] = [:]
        var probeRejected = false
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
            candidateOrigins = [:]
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
            retrievalFeatures = []
            retrievalTopics = []
            retrievalGroups = []
            retrievalAssignments = [:]
            channelPolicy = RecommendationChannelPolicy()
            needsPersonalizedRetrieval = false
            restoreDiscoveryProgress()
        }
        isRunning = true
        synchronizeBookmarks()
        rerank()
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
        rankingTask?.cancel()
        rankingTask = nil
        rankAgain = false
        isPaging = false
        isRanking = false
        loadingPagesID = nil
        pageListErrorID = nil
        for item in leasedCandidates.values {
            requested.remove(item.id)
            if !pending.contains(where: { $0.id == item.id }) { pending.insert(item, at: 0) }
        }
        leasedCandidates = [:]
        isRetrieving = false
        persistDiscoveryProgress()
        store.learning.flush()
    }

    func activate(_ id: String) {
        guard activeID != id, let item = items.first(where: { $0.id == id }) else { return }
        activeID = id
        pool[id]?.selectedOrigin = item.selectedOrigin
        if displayed.insert(id).inserted {
            displayedDuplicates.insert(item.document.duplicateKey)
            presentationCount += 1
        }
        if !isPaging { trimVisitedItems() }
        if remainingCount < 6 { requestMore() }
        loadActivePagesIfNeeded()
        rerank()
    }

    func didChangePreferences() {
        rerank()
    }

    func setPaging(_ paging: Bool) {
        guard isRunning else { return }
        isPaging = paging
        if !paging {
            trimVisitedItems()
            if rankAgain { rerank() }
        }
    }

    private func trimVisitedItems() {
        if let index = items.firstIndex(where: { $0.id == activeID }), index > 20 {
            items.removeFirst(index - 10)
        }
    }

    private func updateLoadingState() {
        let loading = isRetrieving || isRanking
        if isLoading != loading { isLoading = loading }
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
        isRetrieving = true
        let token = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            await fill(generation: token)
            guard generation == token else { return }
            loadTask = nil
            if needsPersonalizedRetrieval { requestMore() }
            else { isRetrieving = false }
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
                if remainingCount >= 12 && pool.count >= 24 { break }
            }
            let lanes = nextLanes()
            guard !lanes.isEmpty else { break }
            let bits = filter.categoryBits
            await withTaskGroup(of: ListingResult.self) { group in
                for lane in lanes {
                    let state = laneStates[lane.id] ?? LaneState()
                    group.addTask { await Self.fetchListing(lane, state: state, excludedBits: bits[lane.site] ?? 0) }
                }
                for await result in group {
                    guard !Task.isCancelled, generation == token else { group.cancelAll(); return }
                    if result.failed {
                        var state = laneStates[result.lane.id] ?? LaneState()
                        state.failedAt = Date()
                        if result.probeRejected, let page = result.requestedPage {
                            // Back off rejected deep probes without changing normal pagination or treating this as a known catalog size.
                            state.upperPage = max(1, page / 2)
                            state.probeUpdatedAt = Date()
                            state.round = (state.round + 1) % 1_000_000
                            state.windowDate = nil
                            state.cursor = nil
                            state.pagesInWindow = 0
                        }
                        laneStates[result.lane.id] = state
                        persistDiscoveryProgress()
                        continue
                    }
                    var state = laneStates[result.lane.id] ?? LaneState()
                    let oldCursor = state.cursor
                    state.fetchedAt = Date()
                    if state.refreshedAt == nil { state.refreshedAt = state.fetchedAt }
                    state.failedAt = nil
                    state.cursor = result.nextCursor
                    state.pagesInWindow += 1
                    if result.lane.depth.samplesArchive {
                        if result.ids.isEmpty, let page = result.requestedPage, page > 1 {
                            // A valid empty deep page narrows the next probe; transport errors never do.
                            state.upperPage = max(1, page / 2)
                            state.probeUpdatedAt = Date()
                        }
                        if state.pagesInWindow >= 2 || result.nextCursor == nil || result.ids.isEmpty {
                            state.round = (state.round + 1) % 1_000_000
                            state.windowDate = nil
                            state.cursor = nil
                            state.pagesInWindow = 0
                        }
                        state.exhausted = false
                    } else {
                        state.exhausted = result.nextCursor == nil || result.nextCursor == oldCursor
                    }
                    laneStates[result.lane.id] = state
                    var received: [ExternalCatalogItem] = []
                    for id in result.ids {
                        let item = ExternalCatalogItem(site: result.lane.site, galleryId: id)
                        let feedback = store.profile.feedback[item.id]
                        if result.lane.samplesCorpus, let document = feedback?.document {
                            store.learning.sample(document)
                        }
                        if result.lane.samplesCorpus, let document = pool[item.id]?.document {
                            store.learning.sample(document)
                        }
                        // Capture provenance before excluding known works from the visible queue.
                        var origins = candidateOrigins[item.id] ?? pool[item.id]?.origins ?? []
                        let origin = result.lane.origin
                        if let index = origins.firstIndex(where: { $0.queryID == origin.queryID && $0.channel == origin.channel }) {
                            origins[index].samplesCorpus = origins[index].samplesCorpus || origin.samplesCorpus
                        } else { origins.append(origin) }
                        let neutral = origins.first(where: \.samplesCorpus)
                        let rest = origins.filter { $0 != neutral }.suffix(neutral == nil ? 8 : 7)
                        candidateOrigins[item.id] = neutral.map { [$0] + Array(rest) } ?? Array(rest)
                        if pool[item.id] != nil { pool[item.id]?.origins = candidateOrigins[item.id] ?? [] }
                        let recentlySeen = feedback?.lastSeen.map { Date().timeIntervalSince($0) < 3 * 86_400 } ?? false
                        if feedback?.vote != nil || feedback?.bookmarked == true || recentlySeen { continue }
                        if !requested.contains(item.id) && !pending.contains(where: { $0.id == item.id }) {
                            if let key = result.resolveKeys[id] { savedResolveKeys[item.id] = key }
                            received.append(item)
                        }
                    }
                    if result.lane.feature != nil { pending.insert(contentsOf: received, at: 0) }
                    else { pending.append(contentsOf: received) }
                    trimPending()
                    persistDiscoveryProgress()
                    // Hydration begins after this bounded search packet, reserving neutral sample slots.
                }
            }
            guard !Task.isCancelled, generation == token else { return }
            await hydratePending(generation: token)
            if remainingCount >= 12 { break }
        }
        if remainingCount == 0 {
            errorMessage = sites == [.pixiv] && !PixivAuthStore.shared.isLoggedIn
                ? "Для рекомендаций Pixiv войди в аккаунт в настройках сайта."
                : "Новых тайтлов пока нет. Можно повторить поиск или проверить выбранные языки и скрытые теги."
        }
    }

    private func nextLanes() -> [Lane] {
        let interests = retrievalFeatures
        let availableSites = sites.filter { $0 != .pixiv || PixivAuthStore.shared.isLoggedIn }
        var discovery: [Lane] = []
        var personal: [Lane] = []
        func variants(_ lane: Lane) -> [Lane] {
            if lane.sortKey != nil { return [lane] }
            let canSample = !(lane.site == .hentaiPill && lane.feature == nil)
                && !(lane.site == .pixiv && lane.feature == nil)
            let depths: [ExternalRecommendationDepth] = canSample
                ? [.latest, .continuation, .middle, .archive] : [.latest, .continuation]
            return depths.map { depth in var copy = lane; copy.depth = depth; return copy }
        }
        for site in availableSites {
            discovery += variants(Lane(site: site))
            if site == .hitomi {
                for sort in [HitomiProvider.SortOption.popularWeek, .popularYear] {
                    discovery.append(Lane(site: site, sortKey: sort.rawValue, depth: .popular))
                }
            }
            for group in retrievalTopics {
                let topics = group.filter { $0.kind.isTag }
                if topics.count >= 2 && [.ehentai, .imhentai, .threeHentai, .simplyHentai, .pixiv].contains(site) {
                    let first = Self.tagSearchVariants(topics[0], for: site)
                    let second = Self.tagSearchVariants(topics[1], for: site)
                    // Only E-Hentai's combined queries encode gender namespaces.
                    for left in site == .ehentai ? first : Array(first.prefix(1)) {
                        for right in site == .ehentai ? second : Array(second.prefix(1)) {
                            personal += variants(Lane(site: site, feature: left, secondFeature: right))
                        }
                    }
                }
            }
            for feature in interests where feature.kind.isTag || feature.siteID == nil || feature.siteID == site.rawValue {
                if site == .pixiv && ![.tag, .female, .male, .artist].contains(feature.kind) { continue }
                let seed = feature.kind == .artist ? seedGalleryID(for: feature, site: site) : nil
                if site == .pixiv && feature.kind == .artist {
                    guard let seed else { continue }
                    for type in ["illust", "manga"] {
                        personal += variants(Lane(site: site, feature: feature, seedGalleryID: seed, pixivWorkType: type))
                    }
                } else {
                    for queryFeature in Self.tagSearchVariants(feature, for: site) {
                        personal += variants(Lane(site: site, feature: queryFeature, seedGalleryID: seed))
                        if site == .threeHentai && queryFeature.kind.isTag {
                            personal.append(Lane(site: site, feature: queryFeature,
                                sortKey: HitomiProvider.SortOption.popularYear.rawValue, depth: .popular))
                        }
                    }
                }
            }
        }
        func available(_ lane: Lane) -> Bool {
            var state = laneStates[lane.id] ?? LaneState()
            state.refresh(for: lane.depth, now: Date())
            laneStates[lane.id] = state
            let retryDelay: TimeInterval = lane.depth.samplesArchive && state.upperPage != nil ? 3 : 30
            return !state.exhausted && (state.failedAt.map { Date().timeIntervalSince($0) > retryDelay } ?? true)
        }
        var used = Set<String>()
        discovery = discovery.filter { used.insert($0.id).inserted && available($0) }
        personal = personal.filter { used.insert($0.id).inserted && available($0) }
        personal = personal.map { lane in
            var copy = lane
            let features = [lane.feature, lane.secondFeature].compactMap { $0 }
            let ids = Set(features.map(\.id))
            let match = retrievalGroups.map { group in
                (group.id, group.center.reduce(0.0) { $0 + (ids.contains($1.key) ? $1.value : 0) })
            }.max { $0.1 < $1.1 }
            let interest = match.flatMap { $0.1 > 0 ? $0.0 : nil }
                ?? features.first.flatMap { retrievalAssignments[$0.id] }
                ?? "favorite:\(features.first?.id ?? "global")"
            let kind: RecommendationChannel.Kind = lane.secondFeature != nil ? .tagPair
                : lane.feature?.kind == .artist ? .author : .singleTag
            copy.channel = RecommendationChannel(kind: kind, interestID: interest)
            return copy
        }
        discovery = discovery.map { lane in
            var copy = lane
            copy.channel = RecommendationChannel(kind: lane.sortKey == nil ? .catalog : .popular)
            return copy
        }
        let schedule: [ExternalRecommendationDepth] = [.latest, .archive, .middle, .continuation, .archive, .middle, .popular, .continuation]
        var chosen: [Lane] = []
        var random = RecommendationRandom(state: RecommendationMath.hash("retrieval|\(laneRotation)|\(store.revision)|\(store.learning.revision)"))
        for slot in 0..<3 {
            let desiredSite = availableSites.isEmpty ? nil : availableSites[(laneRotation + slot) % availableSites.count]
            let desiredDepth = schedule[(laneRotation + slot) % schedule.count]
            var candidates = (discovery + personal).filter { lane in !chosen.contains(where: { $0.id == lane.id }) }
            // The third request supplies an independent catalog sample, never a favorite-tag query.
            if slot == 2 {
                let neutral = candidates.filter { $0.channel.kind == .catalog }
                if !neutral.isEmpty { candidates = neutral }
            }
            guard !candidates.isEmpty else { continue }
            // Choose among the balanced source/depth frontier before sampling the semantic channel.
            let source = candidates.filter { $0.site == desiredSite }
            if !source.isEmpty { candidates = source }
            let period = candidates.filter { $0.depth == desiredDepth }
            if !period.isEmpty { candidates = period }
            if let channel = channelPolicy.choose(candidates.map(\.channel), random: &random, forceCatalog: slot == 2) {
                candidates = candidates.filter { $0.channel == channel }
            }
            let sorted = candidates.sorted { left, right in
                func priority(_ lane: Lane) -> Int {
                    (lane.site == desiredSite ? 8 : 0) + (lane.depth == desiredDepth ? 4 : 0)
                        + (chosen.contains(where: { $0.topicID == lane.topicID }) ? 0 : 2)
                }
                let a = priority(left), b = priority(right)
                return a == b ? left.id < right.id : a > b
            }
            let highest = sorted.first!
            let peers = sorted.filter { $0.site == highest.site && $0.depth == highest.depth }
            let differentTopics = peers.filter { lane in !chosen.contains(where: { $0.topicID == lane.topicID }) }
            let alternatives = differentTopics.isEmpty ? peers : differentTopics
            var selected = alternatives[(laneRotation / max(1, availableSites.count)) % alternatives.count]
            selected.samplesCorpus = slot == 2 && selected.channel.kind == .catalog
            chosen.append(selected)
        }
        laneRotation = (laneRotation + 1) % 1_000_000
        for lane in chosen where lane.depth.samplesArchive && laneStates[lane.id]?.windowDate == nil {
            laneStates[lane.id, default: LaneState()].windowDate = Date()
        }
        return chosen
    }

    /// Shared preferences still need native tag routes on sites that separate gender namespaces.
    nonisolated private static func tagSearchVariants(_ feature: ExternalRecommendationFeature, for site: ExternalSite) -> [ExternalRecommendationFeature] {
        guard feature.kind.isTag else { return [feature] }
        let kinds: [ExternalRecommendationFeature.Kind]
        switch site {
        case .hitomi, .ehentai, .threeHentai, .hentaiPill: kinds = [.tag, .female, .male]
        default: kinds = [.tag]
        }
        return kinds.map { .init(kind: $0, value: feature.value, alias: feature.alias) }
    }

    private func seedGalleryID(for feature: ExternalRecommendationFeature, site: ExternalSite) -> Int? {
        if let item = pool.values.first(where: { $0.detail.site == site && $0.document.features.contains(where: { $0.id == feature.id }) }) {
            return item.detail.id
        }
        return store.profile.feedback.values.first {
            $0.document.siteID == site.rawValue && $0.document.features.contains(where: { $0.id == feature.id })
        }?.document.galleryID
    }

    nonisolated private static func fetchListing(_ lane: Lane, state: LaneState, excludedBits: Int) async -> ListingResult {
        let provider = ExternalSiteRegistry.provider(for: lane.site)
        var requestedPage: Int?
        do {
            let seed = ExternalRecommendationDepth.seed(lane.id + "|" + String(state.round))
            var cursor = state.cursor
            let dateSearch = lane.site == .pixiv && lane.feature != nil && lane.feature?.kind != .artist
            var namespace: ExternalTagNamespace?
            if let feature = lane.feature {
                switch feature.kind {
                case .tag, .format: namespace = .tag
                case .female: namespace = .female
                case .male: namespace = .male
                case .artist: namespace = .artist
                case .group: namespace = .group
                case .character: namespace = .character
                case .series: namespace = .series
                }
            }
            let value = lane.feature.map { lane.site == .pixiv ? $0.value : $0.sharedValue }
            if cursor == nil && lane.depth.samplesArchive && !dateSearch {
                if lane.site == .hitomi {
                    cursor = try await provider.recommendationSampleCursor(namespace: namespace, value: value,
                        fraction: lane.depth.fraction(seed: seed), limit: 24)
                } else {
                    let page = lane.depth.page(seed: seed, upperBound: state.upperPage)
                    requestedPage = page
                    cursor = provider.cursorForPage(page, limit: 24)
                }
            }
            let page: (ids: [Int], nextCursor: String?)
            if let feature = lane.feature {
                if lane.site == .pixiv, feature.kind == .artist, let seedID = lane.seedGalleryID {
                    page = try await PixivProvider().fetchFeedAuthorGalleryIDs(seedGalleryID: seedID, type: lane.pixivWorkType, cursor: cursor)
                } else if dateSearch {
                    var query = PixivAdvancedQuery()
                    query.search = ([feature] + (lane.secondFeature.map { [$0] } ?? [])).map(\.value).joined(separator: " ")
                    let cycle = Int(ExternalRecommendationDepth.seed(lane.id) % 1_000) + state.round
                    if let window = lane.depth.dateWindow(round: cycle, now: state.windowDate ?? Date()) {
                        query.startDate = window.start
                        query.endDate = window.end.addingTimeInterval(-1)
                        query.sort = state.round.isMultiple(of: 2) ? .dateDesc : .dateAsc
                    }
                    page = try await provider.fetchIdsBySearch(query: query.encoded(), cursor: cursor, limit: 24)
                } else if let second = lane.secondFeature {
                    let query = combinationQuery([feature, second], for: lane.site)
                    page = try await provider.fetchIdsBySearch(query: query, excludedCategoryBits: excludedBits, sortKey: lane.sortKey, cursor: cursor, limit: 24)
                } else {
                    page = try await provider.fetchIdsByTag(namespace: namespace!, value: value!, sortKey: lane.sortKey, cursor: cursor, limit: 24)
                }
            } else {
                page = try await provider.fetchIdsBySearch(query: "", excludedCategoryBits: excludedBits, sortKey: lane.sortKey, cursor: cursor, limit: 24)
            }
            var keys: [Int: String] = [:]
            if lane.site == .ehentai {
                for id in page.ids {
                    if let key = await provider.resolveKey(for: id) { keys[id] = key }
                }
            }
            return ListingResult(lane: lane, ids: page.ids, nextCursor: page.nextCursor, requestedPage: requestedPage, resolveKeys: keys)
        } catch {
            let rejected = lane.depth.samplesArchive && requestedPage != nil && !(error is URLError) && !Task.isCancelled
            return ListingResult(lane: lane, failed: true, requestedPage: requestedPage, probeRejected: rejected)
        }
    }

    private func hydratePending(generation token: UUID) async {
        // Every source retains its unconsumed IDs; native page sizes are never discarded.
        var batch: [ExternalCatalogItem] = []
        // Interleave sources before metadata hydration, independent of network completion order.
        let start = sites.isEmpty ? 0 : laneRotation % sites.count
        let order = Array(sites.dropFirst(start)) + Array(sites.prefix(start))
        func neutralIndex(site: ExternalSite? = nil) -> Int? {
            pending.indices.filter { index in
                (site == nil || pending[index].site == site)
                    && candidateOrigins[pending[index].id]?.contains(where: \.samplesCorpus) == true
            }.min { RecommendationMath.hash(pending[$0].id) < RecommendationMath.hash(pending[$1].id) }
        }
        // Up to three of the existing nine metadata slots belong to neutral catalog documents.
        for site in order where batch.count < 3 {
            if let index = neutralIndex(site: site) {
                batch.append(pending.remove(at: index))
            }
        }
        while batch.count < 3, let index = neutralIndex() {
            batch.append(pending.remove(at: index))
        }
        while batch.count < 9 && !pending.isEmpty {
            let count = batch.count
            for site in order where batch.count < 9 {
                if let index = pending.firstIndex(where: { $0.site == site }) { batch.append(pending.remove(at: index)) }
            }
            if batch.count == count { break }
        }
        for item in batch {
            requested.insert(item.id)
            leasedCandidates[item.id] = item
        }
        let resolveKeys = savedResolveKeys
        await withTaskGroup(of: CandidateResult.self) { group in
            var iterator = batch.makeIterator()
            func enqueue() {
                guard let item = iterator.next() else { return }
                let resolveKey = resolveKeys[item.id]
                group.addTask {
                    let candidate = Task.isCancelled ? nil : try? await Self.fetchPreview(site: item.site, id: item.galleryId, resolveKey: resolveKey)
                    return CandidateResult(source: item, item: candidate)
                }
            }
            for _ in 0..<min(3, batch.count) { enqueue() }
            for await result in group {
                guard !Task.isCancelled, generation == token else { group.cancelAll(); return }
                leasedCandidates.removeValue(forKey: result.source.id)
                if result.item == nil { failedCandidates[result.source.id] = result.source }
                if var candidate = result.item {
                    candidate.origins = candidateOrigins[result.source.id] ?? []
                    if candidate.origins.contains(where: \.samplesCorpus) { store.learning.sample(candidate.document) }
                    guard filter.allows(candidate.detail), !candidate.detail.pages.isEmpty else { enqueue(); continue }
                    let detail = candidate.detail
                    let document = candidate.document
                    let saved = ExternalBookmarksStore.shared.isBookmarked(site: detail.site, id: detail.id)
                    if saved { store.setBookmark(true, for: document) }
                    if !displayedDuplicates.contains(document.duplicateKey) {
                        pool[document.id] = candidate
                    }
                    if items.isEmpty { rerank() }
                }
                enqueue()
            }
        }
        guard !Task.isCancelled, generation == token else { return }
        persistDiscoveryProgress()
        rerank()
        if pool.count > 120 {
            let keep = Set(items.map(\.id))
            let removable = pool.keys.filter { !keep.contains($0) }
            for id in removable.prefix(pool.count - 100) { pool.removeValue(forKey: id) }
        }
    }

    private func trimPending() {
        guard pending.count > 360 else { return }
        let neutral = pending.filter { candidateOrigins[$0.id]?.contains(where: \.samplesCorpus) == true }
        let personal = pending.filter { candidateOrigins[$0.id]?.contains(where: \.samplesCorpus) != true }
        let reserved = min(120, neutral.count)
        let selectedPersonal = Array(personal.prefix(360 - reserved))
        let selectedNeutral = Array(neutral.prefix(360 - selectedPersonal.count))
        let retained = Set((selectedPersonal + selectedNeutral).map(\.id))
        pending.removeAll { !retained.contains($0.id) }
    }

    private func rerank() {
        guard isRunning else { return }
        rankingRevision &+= 1
        rankAgain = true
        guard rankingTask == nil, !isPaging else { return }
        isRanking = true
        let token = generation
        rankingTask = Task { [weak self] in
            guard let self else { return }
            while rankAgain, isRunning, !isPaging, generation == token, !Task.isCancelled {
                rankAgain = false
                let revision = rankingRevision
                let profileRevision = store.revision
                let learningRevision = store.learning.revision
                let prefix: [ExternalRecommendationFeedItem]
                if let index = items.lastIndex(where: { self.displayed.contains($0.id) }) {
                    // Returning to an earlier title preserves already-visited forward positions.
                    prefix = Array(items.prefix(index + 1))
                } else { prefix = [] }
                let candidates = pool.values.filter {
                    !self.displayed.contains($0.id) && !self.displayedDuplicates.contains($0.document.duplicateKey) && self.filter.allows($0.detail)
                }.map(\.document)
                let result = await rankingWorker.rank(
                    profile: store.profile, revision: profileRevision, snapshot: store.learning.snapshot,
                    learningRevision: learningRevision, candidates: candidates,
                    origins: pool.mapValues(\.origins),
                    recent: prefix.map(\.document), offset: presentationCount
                )
                guard !Task.isCancelled, isRunning, generation == token else { return }
                if isPaging { rankAgain = true; break }
                guard revision == rankingRevision, profileRevision == store.revision,
                      learningRevision == store.learning.revision else { rankAgain = true; continue }
                store.learning.accept(result.groups)
                retrievalGroups = result.groups
                retrievalAssignments = result.interestAssignments
                channelPolicy = result.policy
                // A complete page list may arrive while ranking the older metadata snapshot.
                let preserved = prefix.map { old -> ExternalRecommendationFeedItem in
                    var item = self.pool[old.id] ?? old
                    item.selectedOrigin = old.selectedOrigin
                    return item
                }
                let next = preserved + result.ranked.compactMap { selection -> ExternalRecommendationFeedItem? in
                    guard var item = self.pool[selection.document.id] else { return nil }
                    item.selectedOrigin = selection.origin
                    return item
                }
                if items.map(\.id) != next.map(\.id)
                    || items.map(\.selectedOrigin) != next.map(\.selectedOrigin) { items = next }
                if activeID == nil, let first = items.first { activate(first.id) }
                if remainingCount > 0 { errorMessage = nil }
                let interests = result.interests.map(\.id) + result.topics.map { $0.map(\.id).joined(separator: ";") }
                if interests != retrievalInterests {
                    retrievalInterests = interests
                    retrievalFeatures = result.interests
                    retrievalTopics = result.topics
                    needsPersonalizedRetrieval = true
                    requestMore()
                }
            }
            guard generation == token else { return }
            rankingTask = nil
            isRanking = false
        }
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

    nonisolated private static func fetchPreview(site: ExternalSite, id: Int, resolveKey: String? = nil) async throws -> ExternalRecommendationFeedItem {
        let provider = ExternalSiteRegistry.provider(for: site)
        if let resolveKey { await provider.primeResolveKey(resolveKey, for: id) }
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
        let values = features.map { site == .pixiv ? $0.value : $0.sharedValue }
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

    private func restoreDiscoveryProgress() {
        var components = sites.map { "site=\($0.rawValue)" }.sorted()
        components += filter.languages.map { "language=\($0.rawValue)" }.sorted()
        for site in sites.sorted(by: { $0.rawValue < $1.rawValue }) {
            components.append("\(site.rawValue):\(filter.categoryBits[site] ?? 0)")
            components += (filter.excludedTypes[site] ?? []).sorted().map { "\(site.rawValue):type=\($0)" }
            components += (filter.excludedLanguages[site] ?? []).sorted().map { "\(site.rawValue):language=\($0)" }
        }
        discoveryScope = components.joined(separator: "\u{1}")
        let snapshot = discoveryStore.load(scope: discoveryScope)
        laneStates = snapshot.lanes
        laneRotation = max(0, min(999_999, snapshot.rotation))
        pending = snapshot.pending.filter { sites.contains($0.site) }.map(\.item)
        savedResolveKeys = Dictionary(snapshot.pending.compactMap { candidate in
            candidate.resolveKey.map { (candidate.item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        candidateOrigins = Dictionary(snapshot.pending.compactMap { candidate in
            candidate.origins.map { (candidate.item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func persistDiscoveryProgress() {
        guard !discoveryScope.isEmpty else { return }
        var used = Set<String>()
        let unconsumed = Array(leasedCandidates.values) + pending
        let saved = unconsumed.filter { used.insert($0.id).inserted }.prefix(360).map {
            ExternalRecommendationSavedCandidate(site: $0.site, galleryID: $0.galleryId, resolveKey: savedResolveKeys[$0.id],
                                                  origins: candidateOrigins[$0.id])
        }
        discoveryStore.save(.init(lanes: laneStates, pending: saved, rotation: laneRotation), scope: discoveryScope)
        let retained = Set(saved.map { $0.item.id })
        savedResolveKeys = savedResolveKeys.filter { retained.contains($0.key) }
        candidateOrigins = candidateOrigins.filter { retained.contains($0.key) || pool[$0.key] != nil }
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
            let full = ExternalRecommendationFeedItem(detail: detail, document: item.document,
                isComplete: detail.pages.count >= item.document.pageCount, origins: item.origins, selectedOrigin: item.selectedOrigin)
            if !full.isComplete { pageListErrorID = item.id }
            pool[item.id] = full
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = full }
        }
    }
}
