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
/// (fetchTopViews, три категории параллельно), коллекции + топ активных
/// недели (fetchHomeWidgets, см. его комментарий про неподтверждённый путь),
/// новинки (fetchCatalog(sort: .added)), последние обновления
/// (fetchLatestUpdates / уведомления).
///
/// Каждая секция грузится и падает НЕЗАВИСИМО — ошибка одной (например,
/// неподтверждённых виджетов) не должна очищать уже показанные остальные,
/// поэтому каждый load-метод сам ловит свою ошибку и просто оставляет
/// секцию пустой, а не пробрасывает исключение наверх.
///
/// ВАЖНО про повторные вызовы (баг из фидбека — "если на чуть-чуть свернуть
/// приложение, элементы то появляются, то пропадают"): reloadAll() раньше
/// не защищался от параллельного запуска — pull-to-refresh, повторный вызов
/// и т.п. могли выполняться ОДНОВРЕМЕННО, и более старый запрос, ответивший
/// ПОЗЖЕ нового, затирал свежие данные пустым/устаревшим результатом. Теперь
/// reloadTask хранится и отменяется перед стартом нового, а отмена (в
/// отличие от настоящей ошибки сети) НЕ очищает уже показанные данные — см.
/// isCancellationError в каждом load-методе.
@MainActor
final class HomeViewModel: ObservableObject {

    // MARK: Сейчас читают

    /// Все три категории грузятся параллельно и хранятся отдельно — виджет
    /// показывает их одновременно как страницы горизонтального пейджинга
    /// (см. HomeView), а не как одну вкладку по выбору.
    @Published private(set) var currentlyReadingBySort: [TopViewsSort: [MangaItem]] = [:]
    @Published private(set) var isLoadingCurrentlyReading = false
    @Published private(set) var currentlyReadingErrorMessage: String?
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
    /// Активная полная перезагрузка — отменяется перед стартом новой (см.
    /// комментарий у типа выше). Не хранит частичные (loadMoreUpdates и т.п.).
    private var reloadTask: Task<Void, Never>?
    /// Тайтлы «Продолжить читать», для которых уже идёт/прошёл фоновый
    /// докачивание totalChapters — не долбим сервер повторно при каждом
    /// перерисовывании карточки (см. loadChapterCountIfNeeded).
    private var chapterCountRequested: Set<String> = []

    init(service: MangaNetworkService = .shared) {
        self.service = service
    }

    // MARK: Точки входа

    func loadInitialIfNeeded() {
        guard !didLoadOnce else { return }
        scheduleReload()
    }

    /// Кнопка "Повторить" в состоянии ошибки — как и loadInitialIfNeeded,
    /// не проверяет didLoadOnce (тот выставляется в true и при неудаче).
    func retry() { scheduleReload() }

    /// Потянуть-обновить (.refreshable) — та же перезагрузка, отменяющая
    /// предыдущую, если она почему-то ещё не завершилась.
    func refresh() async {
        reloadTask?.cancel()
        let task = Task { await reloadAll() }
        reloadTask = task
        await task.value
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        let task = Task { await reloadAll() }
        reloadTask = task
    }

    private func reloadAll() async {
        isLoading = true
        async let a: Void = loadCurrentlyReading()
        async let b: Void = loadWidgets()
        async let c: Void = loadNewest()
        async let d: Void = reloadUpdates()
        _ = await (a, b, c, d)
        guard !Task.isCancelled else { isLoading = false; return }
        didLoadOnce = true
        isLoading = false
    }

    /// Отмена задачи (наш же reloadTask.cancel() перед новым запуском, или
    /// смена вкладки/сцены) — это НЕ ошибка сети: старые данные должны
    /// остаться на экране как есть, а не очищаться в пустоту.
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let networkError = error as? NetworkError, case .cancelled = networkError { return true }
        return false
    }

    // MARK: Сейчас читают

    /// Три категории — фиксированное, статически известное число детей,
    /// поэтому async let (а не withTaskGroup — тот в этом проекте, как
    /// выяснилось на withTaskGroup в DownloadsStore.run(), не наследует
    /// MainActor-изоляцию своего тела, и обращение к self изнутри требует
    /// лишних await MainActor.run{}; async let этой проблемы не создаёт).
    private func loadCurrentlyReading() async {
        isLoadingCurrentlyReading = true
        let period = currentlyReadingPeriod
        do {
            async let newestPage = service.fetchTopViews(period: period, sort: .newest)
            async let risingPage = service.fetchTopViews(period: period, sort: .rising)
            async let popularPage = service.fetchTopViews(period: period, sort: .popular)
            let (n, r, p) = try await (newestPage, risingPage, popularPage)
            currentlyReadingBySort = [
                .newest: Array(n.items.prefix(3)),
                .rising: Array(r.items.prefix(3)),
                .popular: Array(p.items.prefix(3))
            ]
            currentlyReadingErrorMessage = nil
        } catch {
            guard !isCancellation(error) else { isLoadingCurrentlyReading = false; return }
            currentlyReadingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            guard !isCancellation(error) else { return }
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
            guard !isCancellation(error) else { return }
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
                guard !isCancellation(error) else { return }
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
                guard !isCancellation(error) else { return }
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

    // MARK: Прогресс-бар «Продолжить читать»

    /// История аккаунта (`GET /user/chapters/history`) не знает общее число
    /// глав тайтла — только номер последней открытой (см.
    /// ReadingProgress.totalChapters == 0 в этом случае, комментарий в
    /// BookmarksStore). Чтобы прогресс-бар был не пустой полоской, а с
    /// реальной долей, докачиваем список глав тайтла один раз лениво (по
    /// .onAppear карточки в HomeView) и дозаполняем знаменатель — см.
    /// BookmarksStore.setTotalChaptersIfUnknown (не трогает readCount/
    /// lastReadAt, только total).
    func loadChapterCountIfNeeded(for entry: HistoryEntry) {
        let slug = entry.media.apiSlug
        guard chapterCountRequested.insert(slug).inserted else { return }
        guard (BookmarksStore.shared.readingProgress(forSlug: slug)?.totalChapters ?? 0) <= 0 else { return }
        Task { [service] in
            guard let chapters = try? await service.fetchChapters(slug: slug, siteId: entry.media.site) else { return }
            BookmarksStore.shared.setTotalChaptersIfUnknown(slug: slug, total: chapters.count)
        }
    }
}
