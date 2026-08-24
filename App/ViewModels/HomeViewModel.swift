import Foundation

/// Вкладка «Мои обновления» внутри секции «Последние обновления» (см.
/// HomeView) — по словам пользователя это те же данные, что и на вкладке
/// «Новое» (уведомления), просто в виде ленты обновлений, а не бейджей.
enum HomeUpdatesTab: String, CaseIterable, Identifiable {
    case all, mine
    var id: String { rawValue }
    var title: String { self == .all ? "Все обновления" : "Мои обновления" }
}

/// ViewModel вкладки «Читают» — главная лента приложения (см. HomeView):
/// продолжить читать (из BookmarksStore, локально), сейчас читают
/// (fetchTopViews), коллекции + топ активных недели (fetchHomeWidgets, см.
/// его комментарий про неподтверждённый путь), новинки (fetchCatalog(sort:
/// .added)), последние обновления (fetchLatestUpdates / уведомления).
///
/// Каждая секция грузится и падает НЕЗАВИСИМО — ошибка одной (например,
/// неподтверждённых виджетов) не должна очищать уже показанные остальные,
/// поэтому каждый load-метод сам ловит свою ошибку и просто оставляет
/// секцию пустой, а не пробрасывает исключение наверх.
@MainActor
final class HomeViewModel: ObservableObject {

    // MARK: Сейчас читают

    @Published private(set) var currentlyReading: [MangaItem] = []
    @Published private(set) var isLoadingCurrentlyReading = false
    @Published var currentlyReadingSort: TopViewsSort = .newest {
        didSet { if oldValue != currentlyReadingSort { Task { await loadCurrentlyReading() } } }
    }
    @Published var currentlyReadingPeriod: TopViewsPeriod = .day {
        didSet { if oldValue != currentlyReadingPeriod { Task { await loadCurrentlyReading() } } }
    }

    // MARK: Коллекции / топ недели / новинки

    @Published private(set) var collections: [MangaCollection] = []
    @Published private(set) var topActiveUsers: [TopActiveUser] = []
    @Published private(set) var newest: [MangaItem] = []

    // MARK: Последние обновления (беск. скролл вниз)

    @Published var updatesTab: HomeUpdatesTab = .all {
        didSet { if oldValue != updatesTab { Task { await reloadUpdates() } } }
    }
    @Published private(set) var updates: [MangaItem] = []
    @Published private(set) var myUpdates: [NotificationItem] = []
    @Published private(set) var isLoadingMoreUpdates = false

    // MARK: Общее состояние экрана

    @Published private(set) var isLoading = false
    @Published private(set) var didLoadOnce = false

    private let service: MangaNetworkService
    private var updatesPage = 1
    private var updatesHasNext = true

    init(service: MangaNetworkService = .shared) {
        self.service = service
    }

    // MARK: Точки входа

    func loadInitialIfNeeded() {
        guard !didLoadOnce else { return }
        Task { await reloadAll() }
    }

    func retry() { Task { await reloadAll() } }

    func refresh() async { await reloadAll() }

    private func reloadAll() async {
        isLoading = true
        async let a: Void = loadCurrentlyReading()
        async let b: Void = loadWidgets()
        async let c: Void = loadNewest()
        async let d: Void = reloadUpdates()
        _ = await (a, b, c, d)
        didLoadOnce = true
        isLoading = false
    }

    // MARK: Сейчас читают

    private func loadCurrentlyReading() async {
        isLoadingCurrentlyReading = true
        do {
            let page = try await service.fetchTopViews(period: currentlyReadingPeriod, sort: currentlyReadingSort)
            currentlyReading = Array(page.items.prefix(15))
        } catch {
            currentlyReading = []
        }
        isLoadingCurrentlyReading = false
    }

    // MARK: Коллекции + топ недели (эндпоинт не подтверждён — см. fetchHomeWidgets)

    private func loadWidgets() async {
        do {
            let payload = try await service.fetchHomeWidgets()
            collections = payload.collections ?? []
            topActiveUsers = payload.weeklyTopUsers ?? []
        } catch {
            collections = []
            topActiveUsers = []
        }
    }

    // MARK: Новинки

    private func loadNewest() async {
        do {
            let page = try await service.fetchCatalog(query: "", sort: .added, filter: MangaFilter(), page: 1)
            newest = page.items
        } catch {
            newest = []
        }
    }

    // MARK: Последние обновления

    private func reloadUpdates() async {
        updatesPage = 1
        updatesHasNext = true
        switch updatesTab {
        case .all:
            do {
                let page = try await service.fetchLatestUpdates(page: 1)
                updates = page.items
                updatesHasNext = page.hasNextPage
            } catch {
                updates = []
                updatesHasNext = false
            }
        case .mine:
            do {
                // "Мои обновления" — та же лента, что и вкладка «Новое»
                // (уведомления), отфильтрованная до категории "chapter"
                // (новая глава), см. NotificationCategoryCounts.chapter.
                let result = try await service.fetchNotifications(readType: "all", sortType: "desc", page: 1)
                myUpdates = result.items.filter { $0.category == "chapter" }
                updatesHasNext = result.hasNextPage
            } catch {
                myUpdates = []
                updatesHasNext = false
            }
        }
    }

    func loadMoreUpdatesIfNeeded(currentId: Int) {
        guard updatesHasNext, !isLoadingMoreUpdates else { return }
        switch updatesTab {
        case .all:
            guard currentId == updates.last?.id else { return }
        case .mine:
            guard currentId == myUpdates.last?.id else { return }
        }
        Task { await loadMoreUpdates() }
    }

    private func loadMoreUpdates() async {
        isLoadingMoreUpdates = true
        let next = updatesPage + 1
        switch updatesTab {
        case .all:
            do {
                let page = try await service.fetchLatestUpdates(page: next)
                let existing = Set(updates.map(\.id))
                updates.append(contentsOf: page.items.filter { !existing.contains($0.id) })
                updatesPage = next
                updatesHasNext = page.hasNextPage
            } catch {
                // тихо игнорируем — можно попробовать снова при следующем скролле
            }
        case .mine:
            do {
                let result = try await service.fetchNotifications(readType: "all", sortType: "desc", page: next)
                let fresh = result.items.filter { $0.category == "chapter" }
                let existing = Set(myUpdates.map(\.id))
                myUpdates.append(contentsOf: fresh.filter { !existing.contains($0.id) })
                updatesPage = next
                updatesHasNext = result.hasNextPage
            } catch {
                // тихо игнорируем
            }
        }
        isLoadingMoreUpdates = false
    }
}
