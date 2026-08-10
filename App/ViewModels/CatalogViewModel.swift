import Foundation
import Combine

/// ViewModel экрана «Каталог»: поиск с debounce, сортировка, фильтры и пагинация.
@MainActor
final class CatalogViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }
    @Published var sort: SortOption = .relevance {
        didSet { if oldValue != sort { reloadNow() } }
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

    init(service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)

        // Переключение активного сайта в меню (см. SiteSession) должно сразу
        // обновлять список каталога — по требованию "После переключения
        // каталог обновляется". searchSites (чекбоксы мультипоиска) тоже
        // влияют на fetchCatalog (см. effectiveSearchSites), поэтому слушаем
        // и их — любое изменение набора сайтов даёт мгновенный reload.
        siteCancellable = Publishers.Merge(
            SiteSession.shared.$activeSite.map { _ in () }.eraseToAnyPublisher(),
            SiteSession.shared.$searchSites.map { _ in () }.eraseToAnyPublisher()
        )
        // dropFirst(2): оба Publisher'а синхронно отдают текущее значение при
        // подписке (по одному каждый) — пропускаем ровно эти два "стартовых"
        // события, чтобы не делать лишний reload до loadInitialIfNeeded().
        .dropFirst(2)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
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
            let result = try await service.fetchCatalog(query: query, sort: sort, filter: filter, page: 1)
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

    private func fetchNextPage() async {
        isLoadingMore = true
        let next = page + 1
        do {
            let result = try await service.fetchCatalog(query: query, sort: sort, filter: filter, page: next)
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
