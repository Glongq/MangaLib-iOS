import Foundation

/// ViewModel экрана персонажа: детальная инфа (фото/имена/счётчики/описание)
/// + грид тайтлов, где есть этот персонаж (тот же каталожный `/manga`, но с
/// `target_id`+`target_model=character`), с поиском, сортировкой, фильтрами,
/// переключателем типа контента (сайта) и пагинацией.
@MainActor
final class CharacterViewModel: ObservableObject {

    let slugURL: String

    // Детальная часть.
    @Published private(set) var detail: CharacterDetail?
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var detailError: String?

    // Грид тайтлов.
    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }
    @Published var sort: CharacterTitleSort = .popularity {
        didSet { if oldValue != sort { reloadNow() } }
    }
    @Published var site: LibSite = .mangalib {
        didSet { if oldValue != site { reloadNow() } }
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

    /// Числовой id персонажа из slug_url ("1221--monkey-d-luffy" → 1221).
    private var characterId: Int {
        Int(String(slugURL.prefix(while: { $0.isNumber }))) ?? (detail?.id ?? 0)
    }

    init(slugURL: String, service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.slugURL = slugURL
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)
    }

    /// Сайты (типы контента), которые поддерживает приложение, — для
    /// переключателя. AnimeLib (site_id 5) сознательно не поддержан.
    /// Показываем только те, где реально есть тайтлы (по titles_count_details);
    /// если данных ещё нет — все поддерживаемые.
    var availableSites: [LibSite] {
        let counts = detail?.titlesCountBySite ?? [:]
        if counts.isEmpty { return LibSite.allCases }
        let withTitles = LibSite.allCases.filter { (counts[$0.rawValue] ?? 0) > 0 }
        return withTitles.isEmpty ? LibSite.allCases : withTitles
    }

    func titlesCount(for site: LibSite) -> Int? { detail?.titlesCountBySite[site.rawValue] }

    // MARK: Загрузка

    func loadIfNeeded() async {
        guard !didLoadOnce, !isLoading else { return }
        await loadDetail()
        // Дефолтный тип контента — где больше всего тайтлов среди поддерживаемых.
        if let best = availableSites.max(by: { (titlesCount(for: $0) ?? 0) < (titlesCount(for: $1) ?? 0) }) {
            // Обход didSet-reload: выставляем напрямую, затем один reload ниже.
            if best != site { site = best; return } // didSet сам перезагрузит
        }
        reloadNow()
    }

    private func loadDetail() async {
        isLoadingDetail = true
        detailError = nil
        do {
            detail = try await service.fetchCharacterDetail(slugURL: slugURL)
        } catch NetworkError.cancelled {
        } catch {
            detailError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingDetail = false
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

    private func reloadNow() { scheduleReload(debounced: false) }

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
            // Сервер отклонил sort_by — повторяем без сортировки, чтобы грид
            // всё равно наполнился (порядок по умолчанию).
            return try await request(page: page, sortBy: nil)
        }
    }

    private func request(page: Int, sortBy: String?) async throws -> CatalogPage {
        try await service.fetchCatalog(
            query: query,
            sort: .popularity,   // apiSortBy == nil; реальный порядок задаёт sortByOverride
            filter: filter,
            page: page,
            sortByOverride: sortBy,
            sortType: sort.sortType,
            siteIds: [site.rawValue],
            targetId: characterId,
            targetModel: "character"
        )
    }
}
