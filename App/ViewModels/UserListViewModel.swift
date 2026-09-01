import Foundation

/// ViewModel экрана «Пользователи» (Меню → Каталог → Пользователи) —
/// постраничный `GET /user?sort_by=id&sort_type=desc` с поиском. Совсем
/// другая форма данных, чем у DirectoryListViewModel (учётные записи, не
/// контент-сущности) — свой, более простой класс.
@MainActor
final class UserListViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleReload(debounced: true) } }
    }

    @Published private(set) var items: [DirectoryUserEntry] = []
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

    init(service: MangaNetworkService = .shared, debounceMilliseconds: Int = 350) {
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)
    }

    func loadInitialIfNeeded() {
        guard !didLoadOnce else { return }
        reloadNow()
    }

    func retry() { reloadNow() }

    func loadMoreIfNeeded(currentItem item: DirectoryUserEntry) {
        guard let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
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

    private func fetchPage(_ page: Int) async throws -> (items: [DirectoryUserEntry], hasNextPage: Bool) {
        try await service.fetchUsers(page: page, filter: nil, query: query)
    }
}
