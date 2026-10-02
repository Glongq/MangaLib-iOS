import Foundation

/// ViewModel экрана «Франшизы» (Меню → Каталог → Франшизы) — постраничный
/// список `GET /franchise` с поиском/сортировкой + подписка/отписка прямо в
/// строке списка (тот же `POST /favorites {source_type:"franchise"}`, что и
/// на детальном экране, см. MangaNetworkService.toggleFavorite).
@MainActor
final class FranchiseListViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }
    @Published var sort: FranchiseSort = .name {
        didSet { if oldValue != sort { reloadNow() } }
    }
    @Published var sortDescending = false {
        didSet { if oldValue != sortDescending { reloadNow() } }
    }

    @Published private(set) var items: [Franchise] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadOnce = false
    @Published private(set) var errorMessage: String?
    /// id франшиз, у которых прямо сейчас в процессе переключение подписки —
    /// строка показывает спиннер вместо колокольчика (см. FranchiseListView).
    @Published private(set) var togglingIds: Set<Int> = []

    private let service: MangaNetworkService
    private let debounce: Duration
    private var reloadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var page = 1
    private var hasNextPage = true

    init(service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)
    }

    func loadInitialIfNeeded() {
        guard !didLoadOnce else { return }
        reloadNow()
    }

    func retry() { reloadNow() }

    func loadMoreIfNeeded(currentItem item: Franchise) {
        guard let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
        loadMore()
    }

    func isToggling(_ id: Int) -> Bool { togglingIds.contains(id) }

    /// Подписка/отписка прямо из строки списка — обновляет ТОЛЬКО этот
    /// элемент массива по реальному ответу сервера (не предполагает новое
    /// состояние заранее).
    func toggleSubscription(_ franchise: Franchise) {
        guard !togglingIds.contains(franchise.id) else { return }
        togglingIds.insert(franchise.id)
        Task {
            defer { togglingIds.remove(franchise.id) }
            guard let result = try? await service.toggleFavorite(sourceId: franchise.id, sourceType: "franchise") else { return }
            guard let idx = items.firstIndex(where: { $0.id == franchise.id }) else { return }
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

    private func fetchPage(_ page: Int) async throws -> (items: [Franchise], hasNextPage: Bool) {
        try await service.fetchFranchises(
            page: page, sortBy: sort, sortType: sortDescending ? "desc" : "asc", query: query
        )
    }
}
