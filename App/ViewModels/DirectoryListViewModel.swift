import Foundation

/// ViewModel списка одного вида каталожной сущности (Команды/Персонажи/
/// Люди/Издательства) — постраничный `GET {kind.apiPath}` с поиском/
/// сортировкой + подписка прямо в строке, когда она подтверждена
/// (`kind.sourceType != nil`, см. DirectoryKind). Один и тот же класс
/// переиспользуется для всех четырёх экранов — 1-в-1 паттерн
/// FranchiseListViewModel, просто без зашитого под франшизу пути/сортировок.
@MainActor
final class DirectoryListViewModel: ObservableObject {

    let kind: DirectoryKind

    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }
    @Published var sort: DirectorySortOption
    @Published var sortDescending = true {
        didSet { if oldValue != sortDescending { reloadNow() } }
    }

    @Published private(set) var items: [DirectoryEntity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadOnce = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var togglingIds: Set<Int> = []

    private let service: MangaNetworkService
    private let debounce: Duration
    private var reloadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var page = 1
    private var hasNextPage = true

    init(kind: DirectoryKind, service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.kind = kind
        self.sort = kind.defaultSort
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)
    }

    func loadInitialIfNeeded() {
        guard !didLoadOnce else { return }
        reloadNow()
    }

    func retry() { reloadNow() }

    func changeSort(_ newSort: DirectorySortOption) {
        guard newSort != sort else { return }
        sort = newSort
        reloadNow()
    }

    func loadMoreIfNeeded(currentItem item: DirectoryEntity) {
        guard let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
        loadMore()
    }

    func isToggling(_ id: Int) -> Bool { togglingIds.contains(id) }

    func toggleSubscription(_ entity: DirectoryEntity) {
        guard let sourceType = kind.sourceType, !togglingIds.contains(entity.id) else { return }
        togglingIds.insert(entity.id)
        Task {
            defer { togglingIds.remove(entity.id) }
            guard let result = try? await service.toggleFavorite(sourceId: entity.id, sourceType: sourceType) else { return }
            guard let idx = items.firstIndex(where: { $0.id == entity.id }) else { return }
            items[idx].isSubscribed = result.isSubscribed
        }
    }

    // MARK: Загрузка

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
            items = result.items
            hasNextPage = result.hasNextPage
            didLoadOnce = true
        } catch is CancellationError {
        } catch NetworkError.cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            items = []
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
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = next
            hasNextPage = result.hasNextPage
        } catch {}
        isLoadingMore = false
    }

    /// Часть вариантов сортировки (см. DirectoryKind) добавлена по аналогии,
    /// без реального перехвата именно для /teams, /character, /people —
    /// сервер этой экосистемы строго валидирует sort_by и отвечает 422 на
    /// неизвестное значение (та же защита, что у CatalogViewModel.fetchPage/
    /// CharacterViewModel.fetchPage) вместо того, чтобы молча его
    /// проигнорировать. Если гипотеза окажется неверной — список не
    /// остаётся пустым с ошибкой, а просто грузится в серверном порядке по
    /// умолчанию (без sort_by вообще).
    private func fetchPage(_ page: Int) async throws -> (items: [DirectoryEntity], hasNextPage: Bool) {
        let sortType = sortDescending ? "desc" : "asc"
        do {
            return try await service.fetchDirectory(kind: kind, page: page, sortBy: sort.apiValue, sortType: sortType, query: query)
        } catch NetworkError.server(let status) where status == 422 {
            return try await service.fetchDirectory(kind: kind, page: page, sortBy: nil, sortType: sortType, query: query)
        }
    }
}
