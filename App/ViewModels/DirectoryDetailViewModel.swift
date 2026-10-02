import Foundation

/// ViewModel карточки одной каталожной сущности (Люди/Издательства) —
/// детальная инфа (обложка/описание/счётчики/подписка) + грид тайтлов (тот
/// же каталожный `/manga`, но с `target_id`+`target_model=`), с поиском,
/// сортировкой, фильтрами, переключателем сайта и пагинацией. 1-в-1
/// CharacterViewModel/TeamViewModel/FranchiseViewModel — тот же паттерн,
/// параметризован DirectoryKind вместо зашитого под один вид.
@MainActor
final class DirectoryDetailViewModel: ObservableObject {

    let kind: DirectoryKind
    let slugURL: String

    @Published private(set) var detail: DirectoryEntity?
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var detailError: String?
    @Published private(set) var isTogglingSubscription = false

    var isSubscribed: Bool { detail?.isSubscribed ?? false }

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

    private let service: MangaNetworkService
    private let debounce: Duration
    private var reloadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var page = 1
    private var hasNextPage = true

    /// Числовой id из slug_url ("119--amemiya-yuki" → 119).
    private var entityId: Int {
        Int(String(slugURL.prefix(while: { $0.isNumber }))) ?? (detail?.id ?? 0)
    }

    init(kind: DirectoryKind, slugURL: String, service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.kind = kind
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
        await loadDetail()
        if let best = availableSites.max(by: { (titlesCount(for: $0) ?? 0) < (titlesCount(for: $1) ?? 0) }) {
            let target = SiteFilter.site(best)
            if siteFilter != target { siteFilter = target; return } // didSet сам перезагрузит
        }
        reloadNow()
    }

    private func loadDetail() async {
        isLoadingDetail = true
        detailError = nil
        do {
            detail = try await service.fetchDirectoryDetail(kind: kind, slugURL: slugURL)
        } catch NetworkError.cancelled {
        } catch {
            detailError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingDetail = false
    }

    func toggleSubscription() {
        guard let sourceType = kind.sourceType, !isTogglingSubscription else { return }
        isTogglingSubscription = true
        Task {
            defer { isTogglingSubscription = false }
            guard let result = try? await service.toggleFavorite(sourceId: entityId, sourceType: sourceType) else { return }
            detail?.isSubscribed = result.isSubscribed
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
            targetId: entityId,
            targetModel: kind.targetModel
        )
    }
}
