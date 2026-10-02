import Foundation

/// ViewModel экрана "Сейчас читают" (Меню → Каталог → Сейчас читают, см.
/// TopViewsListView) — полноэкранный постраничный список, ОТДЕЛЬНЫЙ от
/// компактного виджета главной (HomeViewModel/HomeView используют
/// MangaNetworkService.fetchTopViews напрямую, без ViewModel). Данные:
/// GET /media/top-views?time=&popularity=&page= (см.
/// MangaNetworkService.fetchTopViewsList).
@MainActor
final class TopViewsListViewModel: ObservableObject {

    @Published var sort: TopViewsSort {
        didSet { if oldValue != sort { Task { await reload() } } }
    }
    @Published var period: TopViewsPeriod = .day {
        didSet { if oldValue != period { Task { await reload() } } }
    }

    @Published private(set) var items: [MangaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadOnce = false
    @Published private(set) var errorMessage: String?

    private let service = MangaNetworkService.shared
    private var page = 1
    private var hasNext = true

    /// Стартовая вкладка — по прямой просьбе, для быстрого перехода с
    /// главной сразу на нужную вкладку (см. HomeView.newestSection/
    /// currentlyReadingSection). `sort` — БЕЗ инлайн-дефолта в объявлении
    /// (был `= .newest`) специально: присвоение в СОБСТВЕННОМ init для
    /// свойства, у которого ещё не было значения, didSet не вызывает (как и
    /// раньше для дефолтного случая) — но объявленный инлайн-дефолт плюс
    /// повторное присваивание здесь же в init было бы уже вторым
    /// присваиванием и МОГЛО бы завести лишний параллельный reload() ещё до
    /// loadIfNeeded() в .task.
    init(initialSort: TopViewsSort = .newest) {
        sort = initialSort
    }

    func loadIfNeeded() async {
        guard !didLoadOnce, !isLoading else { return }
        await reload()
    }

    func retry() {
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        page = 1
        hasNext = true
        do {
            let r = try await service.fetchTopViewsList(sort: sort, period: period, page: 1)
            items = r.items
            hasNext = r.hasNextPage
            didLoadOnce = true
        } catch NetworkError.cancelled {
        } catch {
            items = []
            didLoadOnce = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: MangaItem) async {
        guard hasNext, !isLoading, !isLoadingMore else { return }
        guard items.suffix(6).contains(where: { $0.id == current.id }) else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            let r = try await service.fetchTopViewsList(sort: sort, period: period, page: next)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: r.items.filter { !existing.contains($0.id) })
            page = next
            hasNext = r.hasNextPage
        } catch {}
        isLoadingMore = false
    }
}
