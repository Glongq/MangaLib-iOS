import Foundation
import Combine

/// ViewModel экрана «Каталог»: поиск с debounce, сортировка, фильтры и пагинация.
@MainActor
final class CatalogViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }
    @Published var sort: SortOption = .popularity {
        didSet { if oldValue != sort { reloadNow() } }
    }
    /// Направление сортировки: true — по убыванию (desc), false — по возрастанию (asc).
    @Published var sortDescending: Bool = true {
        didSet { if oldValue != sortDescending { reloadNow() } }
    }
    @Published private(set) var filter = MangaFilter()

    @Published private(set) var results: [MangaItem] = []
    @Published private(set) var isLoading = false       // первичная загрузка
    @Published private(set) var isLoadingMore = false   // дозагрузка страницы
    @Published private(set) var errorMessage: String?
    @Published private(set) var didLoadOnce = false

    private let service: MangaNetworkService
    private let debounce: Duration
    private var reloadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?

    private var page = 1
    private var hasNextPage = true
    private var siteCancellable: AnyCancellable?
    private var searchSitesCancellable: AnyCancellable?

    init(service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)

        // Переключение активного сайта в меню (см. SiteSession) должно сразу
        // сбрасывать фильтры каталога (фильтры одного сайта — например
        // жанры MangaLib — почти наверняка не валидны/не то же самое на
        // другом сайте) и перезагружать список — по требованию "После
        // переключения сайтов сбрасываются все фильтры".
        // dropFirst(): Published синхронно отдаёт текущее значение при
        // подписке — пропускаем этот "стартовый" эмит, чтобы не сбрасывать
        // фильтры и не делать лишний reload до loadInitialIfNeeded().
        siteCancellable = SiteSession.shared.$activeSite
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resetFilters()
            }

        // searchSites (чекбоксы мультипоиска) тоже влияют на fetchCatalog
        // (см. effectiveSearchSites) — любое изменение набора сайтов даёт
        // мгновенный reload, но без сброса фильтров (это не смена активного
        // сайта, а лишь добавление источников для поиска/каталога).
        searchSitesCancellable = SiteSession.shared.$searchSites
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadNow()
            }
    }

    // MARK: Точки входа

    func loadInitialIfNeeded() {
        ConstantsStore.shared.loadIfNeeded()
        guard !didLoadOnce else { return }
        reloadNow()
    }

    func apply(filter newFilter: MangaFilter) {
        filter = newFilter
        reloadNow()
    }

    func resetFilters() {
        filter.reset()
        reloadNow()
    }

    /// Вызывается, когда на экране появляется один из последних элементов.
    func loadMoreIfNeeded(currentItem item: MangaItem) {
        guard let index = results.firstIndex(of: item) else { return }
        // Порог: за 6 элементов до конца.
        guard index >= results.count - 6 else { return }
        loadMore()
    }

    // MARK: Загрузка

    private func scheduleReload(debounced: Bool) {
        reloadTask?.cancel()
        pageTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            if debounced {
                do { try await Task.sleep(for: self.debounce) } catch { return }
            }
            await self.reload()
        }
    }

    private func reloadNow() { scheduleReload(debounced: false) }

    /// Полная перезагрузка с первой страницы.
    private func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        hasNextPage = true
        do {
            let result = try await fetchPage(1)
            guard !Task.isCancelled else { return }
            results = result.items
            hasNextPage = result.hasNextPage
            didLoadOnce = true
        } catch is CancellationError {
        } catch NetworkError.cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            didLoadOnce = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Дозагрузка следующей страницы (бесконечный скролл).
    private func loadMore() {
        guard hasNextPage, !isLoading, !isLoadingMore, pageTask == nil else { return }
        pageTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchNextPage()
            self.pageTask = nil
        }
    }

    /// Запрос страницы с текущими сортировкой/направлением. Если сервер
    /// отклонит sort_by (422 «Выбранное значение для sort by ошибочно»),
    /// повторяем без сортировки (порядок по умолчанию), чтобы каталог не
    /// оказался пустым.
    private func fetchPage(_ page: Int) async throws -> CatalogPage {
        let type = sortDescending ? "desc" : "asc"
        let result: CatalogPage
        do {
            result = try await service.fetchCatalog(query: query, sort: sort, filter: filter, page: page, sortType: type)
        } catch NetworkError.server(let status) where status == 422 {
            result = try await service.fetchCatalog(query: query, sort: .popularity, filter: filter, page: page, sortType: type)
        }
        // "По популярности" — единственная сортировка без своего sort_by
        // (см. SortOption.apiSortBy): сервер не принимает НИ ОДНО значение
        // для неё (проверено — rate/rating/votes/total_votes/popularity/...
        // все дают 422), так что sort_type там серверу передать не на что и
        // переключатель "по возрастанию/по убыванию" молча не работал.
        // Раз сервер не даёт управлять направлением, разворачиваем страницу
        // на клиенте — переключатель хотя бы ощутимо меняет порядок, как и
        // для остальных сортировок.
        guard sort == .popularity, !sortDescending else { return result }
        return CatalogPage(items: result.items.reversed(), hasNextPage: result.hasNextPage)
    }

    private func fetchNextPage() async {
        isLoadingMore = true
        let next = page + 1
        do {
            let result = try await fetchPage(next)
            guard !Task.isCancelled else { isLoadingMore = false; return }
            // Добавляем только новые (защита от дублей).
            let existing = Set(results.map(\.id))
            results.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = next
            hasNextPage = result.hasNextPage
        } catch {
            // тихо игнорируем — можно попробовать снова при следующем скролле
        }
        isLoadingMore = false
    }
}
