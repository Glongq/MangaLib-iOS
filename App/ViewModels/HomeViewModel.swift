import Foundation
import Combine

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
/// (fetchTopViews — один запрос, все три категории сразу), коллекции + топ активных
/// недели (fetchHomeWidgets, см. его комментарий про неподтверждённый путь),
/// новинки (fetchCatalog(sort: .added)), последние обновления — Все
/// (fetchLatestUpdates) и Мои (fetchUserLatestUpdates), оба подтверждённые.
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
    // Дефолт true (не false) — у ВСЕХ isLoading* флагов на этой странице:
    // .task, который запускает первую загрузку, стартует не мгновенно в тот
    // же кадр, что тело View — с false здесь секция на долю секунды вообще
    // не рисуется (ни контента, ни скелетона), потом внезапно появляется
    // скелетон. С true скелетон уже на самом первом кадре.
    @Published private(set) var isLoadingCurrentlyReading = true
    @Published private(set) var currentlyReadingErrorMessage: String?
    @Published var currentlyReadingPeriod: TopViewsPeriod = .day {
        didSet { if oldValue != currentlyReadingPeriod { scheduleCurrentlyReadingReload() } }
    }

    // MARK: Коллекции / топ недели / новинки

    @Published private(set) var collections: [MangaCollection] = []
    @Published private(set) var topActiveUsers: [TopActiveUser] = []
    /// "Обновление популярных тайтлов" — тот же агрегат, что и
    /// collections/topActiveUsers (см. loadWidgets), поэтому отдельного
    /// isLoading-флага не заводим — используем общий isLoadingWidgets.
    @Published private(set) var popular: [MangaItem] = []
    @Published private(set) var isLoadingWidgets = true
    @Published private(set) var newest: [MangaItem] = []
    @Published private(set) var isLoadingNewest = true

    // MARK: Последние обновления (беск. скролл вниз)

    @Published var updatesTab: HomeUpdatesTab = .all {
        didSet {
            guard oldValue != updatesTab else { return }
            // Сброс СРАЗУ (не дожидаясь ответа) — иначе при переключении
            // вкладки на экране на мгновение виден список ПРЕДЫДУЩЕЙ вкладки
            // (например "Все" ещё на экране, пока грузятся "Мои"), что похоже
            // на баг. Теперь вместо чужих данных сразу показывается скелетон
            // (см. HomeView.updatesSection — isLoadingUpdates && updates.isEmpty).
            updates = []
            scheduleUpdatesReload()
        }
    }
    /// Общий список и для «Все обновления», и для «Мои обновления» — оба
    /// эндпоинта отдают одну и ту же форму (см. fetchUpdatesPage), сброс/
    /// перезагрузка при смене updatesTab делает reloadUpdates().
    @Published private(set) var updates: [MangaItem] = []
    /// Только НАЧАЛЬНАЯ загрузка страницы (reloadUpdates) — отдельно от
    /// isLoadingMoreUpdates (подгрузка следующей страницы при скролле вниз),
    /// чтобы HomeView мог показать скелетон только пока список ещё пуст, а
    /// не путать с уже подгруженным списком, который просто дозагружается.
    @Published private(set) var isLoadingUpdates = true
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
    /// Отдельная задача именно для "Последние обновления" — ДО этого поля
    /// смена updatesTab запускала голый Task{} без какой-либо отмены. Баг из
    /// фидбека ("переключаю на Мои обновления, сеть отдаёт 200, но список не
    /// меняется"): если запрос предыдущей вкладки (например, начальный
    /// reloadAll() для «Все») ещё не успел ответить и отвечает ПОЗЖЕ, чем
    /// только что запущенный запрос «Мои», он затирает уже показанные свежие
    /// данные устаревшими — классическая гонка "кто последний ответил, тот и
    /// победил". Теперь, как и у reloadTask, предыдущая задача отменяется
    /// перед стартом новой.
    private var updatesTask: Task<Void, Never>?
    /// Аналогично updatesTask, но для "Сейчас читают" — раньше смена
    /// currentlyReadingPeriod запускала голый Task{} без отмены: если
    /// пользователь успевал переключить период И активный сайт почти
    /// одновременно (или просто дважды быстро сменить период), два
    /// параллельных loadCurrentlyReading() могли ответить в обратном
    /// порядке — более старый (для уже неактуального периода/сайта)
    /// отвечал ПОЗЖЕ и затирал свежие данные устаревшими. Теперь, как и у
    /// reloadTask/updatesTask, предыдущая задача отменяется перед стартом новой.
    private var currentlyReadingTask: Task<Void, Never>?
    /// Тайтлы «Продолжить читать», для которых уже идёт/прошёл фоновый
    /// докачивание totalChapters — не долбим сервер повторно при каждом
    /// перерисовывании карточки (см. loadChapterCountIfNeeded).
    private var chapterCountRequested: Set<String> = []
    private var siteCancellable: AnyCancellable?

    init(service: MangaNetworkService = .shared) {
        self.service = service

        // Переключение активного сайта в меню (см. SiteSession) — все
        // секции ленты (продолжить читать, сейчас читают, коллекции, топ
        // недели, новинки, обновления) относятся к КОНКРЕТНОМУ сайту,
        // поэтому при смене сайта нужна полная перезагрузка, как и у
        // CatalogViewModel/BookmarksStore. dropFirst() — Published сразу
        // отдаёт текущее значение при подписке, этот "стартовый" эмит не
        // нужен (loadInitialIfNeeded() и так вызывается отдельно).
        siteCancellable = SiteSession.shared.$activeSite
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReload()
            }
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
        let a = scheduleCurrentlyReadingReload()
        async let b: Void = loadWidgets()
        async let c: Void = loadNewest()
        let d = scheduleUpdatesReload()
        await a.value
        _ = await (b, c)
        await d.value
        guard !Task.isCancelled else { isLoading = false; return }
        didLoadOnce = true
        isLoading = false
    }

    /// Отменяет предыдущую задачу "Последние обновления" (если ещё не
    /// ответила) и запускает новую — используется и при смене updatesTab, и
    /// внутри reloadAll(), чтобы обе точки входа координировались через одну
    /// и ту же задачу и не могли затереть данные друг друга (см. комментарий
    /// у updatesTask).
    @discardableResult
    private func scheduleUpdatesReload() -> Task<Void, Never> {
        updatesTask?.cancel()
        let task = Task { await reloadUpdates() }
        updatesTask = task
        return task
    }

    /// Отменяет предыдущую задачу "Сейчас читают" (если ещё не ответила) и
    /// запускает новую — используется и при смене currentlyReadingPeriod, и
    /// внутри reloadAll() (смена сайта), чтобы обе точки входа
    /// координировались через одну и ту же задачу (см. currentlyReadingTask).
    @discardableResult
    private func scheduleCurrentlyReadingReload() -> Task<Void, Never> {
        currentlyReadingTask?.cancel()
        let task = Task { await loadCurrentlyReading() }
        currentlyReadingTask = task
        return task
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

    /// ОДИН запрос уже возвращает все три категории сразу (см.
    /// TopViewsPayload/MangaNetworkService.fetchTopViews) — раньше здесь
    /// было три параллельных запроса (async let), пока не подтвердилось
    /// реальным перехватом, что сервер и так отдаёт всё одним ответом.
    private func loadCurrentlyReading() async {
        isLoadingCurrentlyReading = true
        do {
            let payload = try await service.fetchTopViews(period: currentlyReadingPeriod)
            var bySort: [TopViewsSort: [MangaItem]] = [:]
            for sort in TopViewsSort.allCases {
                bySort[sort] = (payload.items?[sort.groupKey] ?? []).map(\.media)
            }
            currentlyReadingBySort = bySort
            currentlyReadingErrorMessage = nil
        } catch {
            guard !isCancellation(error) else { isLoadingCurrentlyReading = false; return }
            currentlyReadingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingCurrentlyReading = false
    }

    // MARK: Коллекции + топ недели (эндпоинт не подтверждён — см. fetchHomeWidgets)

    private func loadWidgets() async {
        isLoadingWidgets = true
        do {
            let payload = try await service.fetchHomeWidgets()
            collections = payload.collections ?? []
            topActiveUsers = payload.weeklyTopUsers ?? []
            popular = payload.popular ?? []
        } catch {
            guard !isCancellation(error) else { isLoadingWidgets = false; return }
            collections = []
            topActiveUsers = []
            popular = []
        }
        isLoadingWidgets = false
    }

    // MARK: Новинки

    /// siteIds передаём ЯВНО (только активный сайт) — без этого fetchCatalog
    /// по умолчанию берёт SiteSession.effectiveSearchSites (активный сайт +
    /// ЛЮБЫЕ дополнительно отмеченные для поиска сайты, отдельная настройка,
    /// не связанная с переключателем активного сайта). Раньше «Новинки» на
    /// вкладке «Читают» — единственная секция здесь, использующая
    /// fetchCatalog, — могла тихо подмешивать тайтлы с ДРУГИХ сайтов, если у
    /// пользователя отмечены галочки мультипоиска: переключаешь активный
    /// сайт, а раздел всё равно показывает не только его. Остальные секции
    /// вкладки (сейчас читают/виджеты/обновления) и так завязаны только на
    /// активный сайт через заголовок Site-Id — теперь «Новинки» ведёт себя
    /// так же.
    private func loadNewest() async {
        isLoadingNewest = true
        do {
            let page = try await service.fetchCatalog(query: "", sort: .added, filter: MangaFilter(), page: 1,
                                                        siteIds: [SiteSession.shared.activeSite.rawValue])
            newest = page.items
        } catch {
            guard !isCancellation(error) else { isLoadingNewest = false; return }
            newest = []
        }
        isLoadingNewest = false
    }

    // MARK: Последние обновления

    /// Всё обновления и мои обновления — оба ПОДТВЕРЖДЁННЫЕ эндпоинты одной
    /// формы (CatalogPage: [MangaItem] + hasNextPage), см. fetchLatestUpdates
    /// / fetchUserLatestUpdates — поэтому загрузка/пагинация общие, разница
    /// только в том, какой из двух запросов делать.
    private func fetchUpdatesPage(_ page: Int) async throws -> CatalogPage {
        switch updatesTab {
        case .all:  return try await service.fetchLatestUpdates(page: page)
        case .mine: return try await service.fetchUserLatestUpdates(page: page)
        }
    }

    private func reloadUpdates() async {
        updatesPage = 1
        updatesHasNext = true
        isLoadingUpdates = true
        do {
            let page = try await fetchUpdatesPage(1)
            updates = page.items
            updatesHasNext = page.hasNextPage
        } catch {
            guard !isCancellation(error) else { isLoadingUpdates = false; return }
            updates = []
            updatesHasNext = false
        }
        isLoadingUpdates = false
    }

    func loadMoreUpdatesIfNeeded(currentId: Int) {
        guard updatesHasNext, !isLoadingMoreUpdates, currentId == updates.last?.id else { return }
        Task { await loadMoreUpdates() }
    }

    private func loadMoreUpdates() async {
        isLoadingMoreUpdates = true
        let next = updatesPage + 1
        do {
            let page = try await fetchUpdatesPage(next)
            let existing = Set(updates.map(\.id))
            updates.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            updatesPage = next
            updatesHasNext = page.hasNextPage
        } catch {
            // тихо игнорируем — можно попробовать снова при следующем скролле
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
