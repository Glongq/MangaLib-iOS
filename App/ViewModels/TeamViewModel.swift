import Foundation

/// ViewModel страницы переводчика: детальная инфа (аватар/фон/соцсети/
/// статистика/описание) + грид тайтлов, где эта команда — переводчик (тот же
/// каталожный `/manga`, но с `target_id`+`target_model=team`), с поиском,
/// сортировкой, фильтрами, переключателем сайта и пагинацией. Почти 1-в-1
/// зеркало CharacterViewModel — тот же самый паттерн, другая модель/target_model.
@MainActor
final class TeamViewModel: ObservableObject {

    let slugURL: String

    // Детальная часть.
    @Published private(set) var detail: TeamDetail?
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var detailError: String?

    // Участники (ПОДТВЕРЖДЕНО отдельным эндпоинтом GET /teams/{slug}/users —
    // см. MangaNetworkService.fetchTeamMembers) и подписка (ПОДТВЕРЖДЕНО
    // GET /favorites/team/{id} для реального стартового статуса + тот же
    // POST /favorites, что и у TeamChipView, для переключения).
    @Published private(set) var members: [TeamMemberEntry] = []
    @Published private(set) var isSubscribed = false
    @Published private(set) var isTogglingSubscription = false

    // Грид тайтлов.
    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }
    @Published var sort: CharacterTitleSort = .popularity {
        didSet { if oldValue != sort { reloadNow() } }
    }

    enum SiteFilter: Hashable, Identifiable {
        case all
        case site(LibSite)
        var id: String { switch self { case .all: return "all"; case .site(let s): return "s\(s.rawValue)" } }
    }
    @Published var siteFilter: SiteFilter = .all {
        didSet { if oldValue != siteFilter { reloadNow() } }
    }
    @Published private(set) var filter = MangaFilter()

    @Published private(set) var titles: [MangaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadOnce = false
    @Published private(set) var errorMessage: String?

    // Вкладка "Обновления" — ПОДТВЕРЖДЕНО GET /teams/{id}/chapters (см.
    // MangaNetworkService.fetchTeamChapters), тот же пагинация-паттерн, что
    // и у грида тайтлов выше (page/hasNextPage/pageTask), только своё
    // состояние — переключение вкладок не должно сбрасывать уже
    // загруженный список тайтлов и наоборот.
    @Published private(set) var updates: [TeamChapterGroup] = []
    @Published private(set) var isLoadingUpdates = false
    @Published private(set) var isLoadingMoreUpdates = false
    @Published private(set) var didLoadUpdatesOnce = false
    private var updatesPage = 1
    private var updatesHasNextPage = true
    private var updatesPageTask: Task<Void, Never>?

    private let service: MangaNetworkService
    private let debounce: Duration
    private var reloadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var page = 1
    private var hasNextPage = true

    /// Числовой id команды из slug_url ("13075--sweet-house-taiper-naidis" → 13075).
    private var teamId: Int {
        Int(String(slugURL.prefix(while: { $0.isNumber }))) ?? (detail?.id ?? 0)
    }

    init(slugURL: String, service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.slugURL = slugURL
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)
    }

    var availableSites: [LibSite] {
        let counts = detail?.titlesCountBySite ?? [:]
        if counts.isEmpty { return LibSite.allCases }
        let withTitles = LibSite.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }
        return withTitles.isEmpty ? LibSite.allCases : withTitles
    }

    func titlesCount(for site: LibSite) -> Int? { detail?.titlesCountBySite[site.rawValue] }

    var availableFilters: [SiteFilter] { availableSites.map { .site($0) } + [.all] }

    private var selectedSiteIds: [Int] {
        switch siteFilter {
        case .all: return availableSites.map(\.rawValue)
        case .site(let s): return [s.rawValue]
        }
    }

    /// Реальный хост+заголовок Site-Id (см. FranchiseViewModel.overrideSiteId).
    private var overrideSiteId: Int? {
        switch siteFilter {
        case .all: return nil
        case .site(let s): return s.rawValue
        }
    }

    // MARK: Загрузка

    func loadIfNeeded() async {
        guard !didLoadOnce, !isLoading else { return }
        async let detailTask: Void = loadDetail()
        async let membersTask: Void = loadMembers()
        async let subscriptionTask: Void = loadSubscriptionStatus()
        _ = await (detailTask, membersTask, subscriptionTask)
        if let best = availableSites.max(by: { (titlesCount(for: $0) ?? 0) < (titlesCount(for: $1) ?? 0) }) {
            let target = SiteFilter.site(best)
            if siteFilter != target { siteFilter = target; return }
        }
        reloadNow()
    }

    private func loadDetail() async {
        isLoadingDetail = true
        detailError = nil
        do {
            detail = try await service.fetchTeamDetail(slugURL: slugURL)
        } catch NetworkError.cancelled {
        } catch {
            detailError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingDetail = false
    }

    /// Молчаливый провал (как loadSimilar/loadRelated у тайтла) — список
    /// участников не критичен для остального экрана.
    private func loadMembers() async {
        members = (try? await service.fetchTeamMembers(slugURL: slugURL)) ?? []
    }

    private func loadSubscriptionStatus() async {
        guard let result = try? await service.fetchFavoriteStatus(sourceId: teamId, sourceType: "team") else { return }
        isSubscribed = result.isSubscribed
    }

    func toggleSubscription() {
        guard !isTogglingSubscription else { return }
        isTogglingSubscription = true
        Task {
            defer { isTogglingSubscription = false }
            guard let result = try? await service.toggleFavorite(sourceId: teamId, sourceType: "team") else { return }
            isSubscribed = result.isSubscribed
        }
    }

    func apply(filter newFilter: MangaFilter) {
        filter = newFilter
        reloadNow()
    }

    func loadMoreIfNeeded(_ item: MangaItem) {
        guard let index = titles.firstIndex(of: item), index >= titles.count - 6 else { return }
        loadMore()
    }

    // MARK: Вкладка "Обновления"

    /// Первая загрузка ленты — вызывается лениво (см. TeamView.onChange(of:
    /// selectedTab)) только когда пользователь реально открыл вкладку, а не
    /// сразу вместе с тайтлами/деталями команды.
    func loadUpdatesIfNeeded() async {
        guard !didLoadUpdatesOnce, !isLoadingUpdates else { return }
        isLoadingUpdates = true
        do {
            let result = try await service.fetchTeamChapters(teamId: teamId, page: 1)
            updates = result.items
            updatesHasNextPage = result.hasNextPage
            updatesPage = 1
        } catch {
            updates = []
        }
        didLoadUpdatesOnce = true
        isLoadingUpdates = false
    }

    func loadMoreUpdatesIfNeeded(_ group: TeamChapterGroup) {
        guard let index = updates.firstIndex(of: group), index >= updates.count - 4 else { return }
        guard updatesHasNextPage, !isLoadingUpdates, !isLoadingMoreUpdates, updatesPageTask == nil else { return }
        updatesPageTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchNextUpdatesPage()
            self.updatesPageTask = nil
        }
    }

    private func fetchNextUpdatesPage() async {
        isLoadingMoreUpdates = true
        let next = updatesPage + 1
        do {
            let result = try await service.fetchTeamChapters(teamId: teamId, page: next)
            let existing = Set(updates.map(\.id))
            updates.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            updatesPage = next
            updatesHasNextPage = result.hasNextPage
        } catch {}
        isLoadingMoreUpdates = false
    }

    private func scheduleReload(debounced: Bool) {
        reloadTask?.cancel()
        pageTask?.cancel()
        pageTask = nil
        reloadTask = Task { [weak self] in
            guard let self else { return }
            if debounced { do { try await Task.sleep(for: self.debounce) } catch { return } }
            await self.reload()
        }
    }

    // Не private — нужен вызов извне для кнопки "Повторить" на сетке тайтлов (см. View).
    func reloadNow() { scheduleReload(debounced: false) }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        hasNextPage = true
        do {
            let result = try await fetchPage(1)
            guard !Task.isCancelled else { return }
            titles = result.items
            hasNextPage = result.hasNextPage
            didLoadOnce = true
        } catch is CancellationError {
        } catch NetworkError.cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            titles = []
            didLoadOnce = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() {
        guard hasNextPage, !isLoading, !isLoadingMore, pageTask == nil else { return }
        pageTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchNextPage()
            self.pageTask = nil
        }
    }

    private func fetchNextPage() async {
        isLoadingMore = true
        let next = page + 1
        do {
            let result = try await fetchPage(next)
            guard !Task.isCancelled else { isLoadingMore = false; return }
            let existing = Set(titles.map(\.id))
            titles.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = next
            hasNextPage = result.hasNextPage
        } catch {}
        isLoadingMore = false
    }

    private func fetchPage(_ page: Int) async throws -> CatalogPage {
        do {
            return try await request(page: page, sortBy: sort.sortBy)
        } catch NetworkError.server(let status) where status == 422 {
            return try await request(page: page, sortBy: nil)
        }
    }

    private func request(page: Int, sortBy: String?) async throws -> CatalogPage {
        try await service.fetchCatalog(
            query: query,
            sort: .popularity,
            filter: filter,
            page: page,
            sortByOverride: sortBy,
            sortType: sort.sortType,
            siteIds: selectedSiteIds, siteId: overrideSiteId,
            targetId: teamId,
            targetModel: "team"
        )
    }
}
