import Foundation

/// ViewModel экрана "Избранное" (Меню → Профиль → Избранное, см.
/// FavoritesListView) — постраничный `GET /favorites` с поиском (debounce —
/// тот же паттерн, что и в DirectoryListViewModel/FranchiseListViewModel),
/// перезагружает список при смене категории (см. category didSet).
@MainActor
final class FavoritesListViewModel: ObservableObject {

    @Published var category: FavoritesCategory = .team {
        didSet { if oldValue != category { reloadNow() } }
    }
    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }

    @Published private(set) var items: [DirectoryEntity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadOnce = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var removingIds: Set<Int> = []

    private let service = MangaNetworkService.shared
    private let debounce: Duration = .milliseconds(350)
    private var reloadTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var page = 1
    private var hasNextPage = true

    func loadInitialIfNeeded(userId: Int) {
        guard !didLoadOnce else { return }
        reloadNow(userId: userId)
    }

    func retry(userId: Int) { reloadNow(userId: userId) }

    func loadMoreIfNeeded(currentItem item: DirectoryEntity, userId: Int) {
        guard let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
        loadMore(userId: userId)
    }

    func isRemoving(_ id: Int) -> Bool { removingIds.contains(id) }

    /// Убрать из избранного (красная мусорка) — ПОДТВЕРЖДЕНО перехватом:
    /// тот же `POST /favorites {source_id, source_type}`, что и
    /// toggleFavorite (DirectoryListViewModel/FranchiseListViewModel) —
    /// повторный вызов на уже избранном снимает его (is_subscribed:false в
    /// ответе), отдельного DELETE-эндпоинта не существует. Строку убираем
    /// из списка ТОЛЬКО когда сервер реально подтвердил is_subscribed:false
    /// — не оптимистично, и только если категория за время запроса не
    /// сменилась (иначе можно случайно убрать элемент из УЖЕ ДРУГОГО списка).
    func remove(_ entity: DirectoryEntity) {
        guard !removingIds.contains(entity.id) else { return }
        removingIds.insert(entity.id)
        let requestedCategory = category
        let sourceType = requestedCategory.sourceType
        Task { [weak self] in
            guard let self else { return }
            defer { self.removingIds.remove(entity.id) }
            guard let result = try? await self.service.toggleFavorite(sourceId: entity.id, sourceType: sourceType) else { return }
            guard !result.isSubscribed, self.category == requestedCategory else { return }
            self.items.removeAll { $0.id == entity.id }
        }
    }

    // MARK: Загрузка

    /// userId хранится тут же (не параметр didSet) — didSet у category/query
    /// не может принять его отдельно, поэтому запоминаем при первой загрузке.
    private var cachedUserId: Int?

    private func reloadNow() {
        guard let userId = cachedUserId else { return }
        reloadNow(userId: userId)
    }

    private func reloadNow(userId: Int) {
        cachedUserId = userId
        scheduleReload(userId: userId, debounced: false)
    }

    private func scheduleReload(userId: Int, debounced: Bool) {
        reloadTask?.cancel()
        pageTask?.cancel()
        pageTask = nil
        reloadTask = Task { [weak self] in
            guard let self else { return }
            if debounced { do { try await Task.sleep(for: self.debounce) } catch { return } }
            await self.reload(userId: userId)
        }
    }

    private func scheduleReload(debounced: Bool) {
        guard let userId = cachedUserId else { return }
        scheduleReload(userId: userId, debounced: debounced)
    }

    private func reload(userId: Int) async {
        isLoading = true
        errorMessage = nil
        page = 1
        hasNextPage = true
        do {
            let result = try await service.fetchFavorites(userId: userId, category: category, page: 1, query: query)
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

    private func loadMore(userId: Int) {
        guard hasNextPage, !isLoading, !isLoadingMore, pageTask == nil else { return }
        pageTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchNextPage(userId: userId)
            self.pageTask = nil
        }
    }

    private func fetchNextPage(userId: Int) async {
        isLoadingMore = true
        let next = page + 1
        do {
            let result = try await service.fetchFavorites(userId: userId, category: category, page: next, query: query)
            guard !Task.isCancelled else { isLoadingMore = false; return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            page = next
            hasNextPage = result.hasNextPage
        } catch {}
        isLoadingMore = false
    }
}
