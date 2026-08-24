import Foundation

// MARK: - Network errors

enum NetworkError: LocalizedError {
    case invalidURL
    case forbidden                     // 403 — не прошла защита (отсутствуют/неверны заголовки)
    case notFound                      // 404
    case rateLimited                   // 429
    case server(status: Int)           // прочие 4xx/5xx
    case decoding(Error)
    case transport(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "Некорректный URL запроса."
        case .forbidden:             return "Доступ запрещён (403). Проверьте заголовки запроса."
        case .notFound:              return "Ресурс не найден (404)."
        case .rateLimited:           return "Слишком много запросов (429). Попробуйте позже."
        case .server(let status):    return "Ошибка сервера (\(status))."
        case .decoding(let error):   return "Ошибка разбора ответа: \(error.localizedDescription)"
        case .transport(let error):  return "Сетевая ошибка: \(error.localizedDescription)"
        case .cancelled:             return "Запрос отменён."
        }
    }
}

// MARK: - Network service

/// Единый сервис для всех сетевых запросов к API MangaLib.
/// Использует нативный `URLSession` и `async/await`.
final class MangaNetworkService {

    static let shared = MangaNetworkService()

    /// Базовый URL API. Согласно правилам MangaLib — `https://api.cdnlibs.org/api`.
    private let baseURL = URL(string: "https://api.cdnlibs.org/api")!

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: Обязательные заголовки

    /// User-Agent и Referer, без которых сервер (и CDN картинок) возвращает 403.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// Раньше было захардкожено на mangalib.me — теперь следует за активным
    /// сайтом (см. LibSite/SiteSession), как это делал бы настоящий браузер.
    static var referer: String { "https://\(SiteSession.shared.activeSite.host)/" }

    /// Заголовки, без которых сервер возвращает 403 / не резолвит одиночные тайтлы.
    /// `Site-Id` обязателен для эндпоинтов /manga/{slug}, /chapters, /chapter —
    /// поиск работает и по query-параметру site_id[], а детальные — только по
    /// заголовку. Теперь берётся из SiteSession.activeSite (переключатель сайта
    /// в меню), а не захардкожен на MangaLib.
    ///
    /// `Authorization` добавляется, только если есть токен сессии (см. AuthSession) —
    /// это единственное, что открывает 18+ тайтлы и их главы: сервер отдаёт такой
    /// контент только авторизованным запросам, привязанным к аккаунту. Никакого
    /// отдельного query-параметра "показать 18+" в API нет. Один и тот же токен
    /// работает на всех сайтах экосистемы — переключение сайта не требует
    /// повторного логина (см. комментарий в LibSite.swift).
    private var defaultHeaders: [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.userAgent,
            "Referer": Self.referer,
            "Accept": "application/json",
            "Site-Id": String(SiteSession.shared.activeSite.rawValue)
        ]
        if let token = AuthSession.shared.token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    // MARK: - Public API

    /// Поиск/каталог манги по текстовому запросу.
    /// `GET /manga?fields[]=rate_avg&fields[]=rate&fields[]=releaseDate&q={query}&site_id[]=1`
    /// Поиск — единственное место, где site_id[] может повторяться несколько
    /// раз: пользователь отдельными чекбоксами в меню включает поиск сразу по
    /// нескольким сайтам (SiteSession.effectiveSearchSites), независимо от
    /// того, какой сайт сейчас активен для каталога/закладок/истории.
    func searchManga(query: String) async throws -> [MangaItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "fields[]", value: "rate_avg"),
            URLQueryItem(name: "fields[]", value: "rate"),
            URLQueryItem(name: "fields[]", value: "releaseDate")
        ]
        for site in SiteSession.shared.effectiveSearchSites {
            items.append(URLQueryItem(name: "site_id[]", value: String(site.rawValue)))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }

        let request = try makeRequest(path: "/manga", queryItems: items)
        let response: APIListResponse<MangaItem> = try await perform(request)
        return response.data
    }

    /// Каталог с сортировкой, фильтрами и пагинацией.
    /// Базовые параметры совпадают с поиском; неизвестные серверу параметры он игнорирует.
    /// Тот же экран используется и для поиска по каталогу — поэтому здесь тоже
    /// несколько site_id[] из effectiveSearchSites (активный сайт + галочки).
    /// `sortByOverride`/`sortType` — для страниц с расширенным набором
    /// сортировок (напр. персонаж), где нужны значения вне каталожной
    /// SortOption. `siteIds` — явный набор сайтов вместо effectiveSearchSites
    /// (страница персонажа фильтрует по одному типу контента). `targetId`+
    /// `targetModel` — фильтр «тайтлы, где есть эта сущность» (персонаж и т.п.),
    /// ПОДТВЕРЖДЕНО перехватом `?target_id=1221&target_model=character`.
    /// `extraFields` — дополнительные значения `fields[]` сверх стандартного
    /// набора (напр. "metadata" — см. fetchLatestUpdates). Пустой массив по
    /// умолчанию не меняет поведение существующих вызовов ни на бит.
    func fetchCatalog(query: String, sort: SortOption, filter: MangaFilter, page: Int = 1,
                      sortByOverride: String? = nil, sortType: String = "desc",
                      siteIds: [Int]? = nil,
                      targetId: Int? = nil, targetModel: String? = nil,
                      extraFields: [String] = []) async throws -> CatalogPage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "fields[]", value: "rate"),
            URLQueryItem(name: "fields[]", value: "rate_avg"),
            URLQueryItem(name: "fields[]", value: "userBookmark"),
            URLQueryItem(name: "fields[]", value: "releaseDate"),
            URLQueryItem(name: "page", value: String(max(page, 1)))
        ]
        for field in extraFields {
            items.append(URLQueryItem(name: "fields[]", value: field))
        }
        let sites = siteIds ?? SiteSession.shared.effectiveSearchSites.map(\.rawValue)
        for site in sites {
            items.append(URLQueryItem(name: "site_id[]", value: String(site)))
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }

        if let targetId {
            items.append(URLQueryItem(name: "target_id", value: String(targetId)))
        }
        if let targetModel {
            items.append(URLQueryItem(name: "target_model", value: targetModel))
        }

        if let sortBy = sortByOverride ?? sort.apiSortBy {
            items.append(URLQueryItem(name: "sort_by", value: sortBy))
            items.append(URLQueryItem(name: "sort_type", value: sortType))
        }

        // Числовые диапазоны.
        appendRange(&items, "chap_count_min", filter.chaptersFrom)
        appendRange(&items, "chap_count_max", filter.chaptersTo)
        appendRange(&items, "year_min", filter.yearFrom)
        appendRange(&items, "year_max", filter.yearTo)
        appendRange(&items, "rating_min", filter.ratingFrom)
        appendRange(&items, "rating_max", filter.ratingTo)
        appendRange(&items, "rate_min", filter.votesFrom)
        appendRange(&items, "rate_max", filter.votesTo)

        // Трёхпозиционные секции: включение и исключение.
        appendTri(&items, "genres", filter.genres)
        appendTri(&items, "tags", filter.tags)

        // «Строгое совпадение» = AND по выбранным жанрам/тегам (по умолчанию сервер даёт OR).
        // Имя параметра — предположительное; сервер игнорирует неизвестные параметры.
        if filter.genresStrict && !filter.genres.included.isEmpty {
            items.append(URLQueryItem(name: "genres_and", value: "true"))
        }
        if filter.tagsStrict && !filter.tags.included.isEmpty {
            items.append(URLQueryItem(name: "tags_and", value: "true"))
        }
        appendTri(&items, "caution", filter.ageRatings)
        appendTri(&items, "types", filter.types)
        appendTri(&items, "format", filter.formats)
        appendTri(&items, "status", filter.titleStatuses)
        appendTri(&items, "scanlate_status", filter.translationStatuses)

        let request = try makeRequest(path: "/manga", queryItems: items)
        let response: APIListResponse<MangaItem> = try await perform(request)
        return CatalogPage(items: response.data, hasNextPage: response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// «Последние обновления» на вкладке «Читают» (см. HomeView) — тот же
    /// каталог, отсортированный по дате последней главы (SortOption.updated →
    /// sort_by=last_chapter_at, ПОДТВЕРЖДЕНО реальным поведением каталога), но
    /// с попыткой попросить `fields[]=metadata`, чтобы получить "Том X Глава Y"
    /// (см. MangaItem.latestChapter) — ИМЯ ЭТОГО КОНКРЕТНОГО значения fields[]
    /// НЕ ПОДТВЕРЖДЕНО перехватом, только предположение по аналогии с полем
    /// "metadata" в агрегате главной страницы. Если сервер отклонит его (422,
    /// как уже бывает с неверным sort_by — см. CatalogViewModel.fetchPage),
    /// повторяем без него: список тайтлов не пропадает, просто без строки
    /// "Том/Глава".
    func fetchLatestUpdates(page: Int = 1) async throws -> CatalogPage {
        do {
            return try await fetchCatalog(query: "", sort: .updated, filter: MangaFilter(), page: page, extraFields: ["metadata"])
        } catch NetworkError.server(let status) where status == 422 {
            return try await fetchCatalog(query: "", sort: .updated, filter: MangaFilter(), page: page)
        }
    }

    /// «Мои обновления» на вкладке «Читают» — ПОДТВЕРЖДЕНО реальным
    /// перехватом (пользователь прислал полное тело ответа): `GET
    /// /user-latest-updates?page=`, форма элемента и пагинация — та же, что
    /// у fetchLatestUpdates (MangaItem + meta.has_next_page), просто с
    /// заранее включённым metadata.latest_items — без нашего fields[]=
    /// metadata и без риска 422. Судя по названию пути — обновления по
    /// тайтлам аккаунта (закладки/подписки), а не весь каталог, поэтому,
    /// как и /auth/me, скорее всего требует авторизации.
    func fetchUserLatestUpdates(page: Int = 1) async throws -> CatalogPage {
        let items: [URLQueryItem] = [URLQueryItem(name: "page", value: String(max(page, 1)))]
        let request = try makeRequest(path: "/user-latest-updates", queryItems: items)
        let response: APIListResponse<MangaItem> = try await perform(request)
        return CatalogPage(items: response.data, hasNextPage: response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// «Сейчас читают» — ПОДТВЕРЖДЕНО реальным перехватом (файл от
    /// пользователя): `GET /media/top-views`, пагинация как у обычного
    /// каталога (meta.has_next_page). Имя параметра периода — `time` (НЕ
    /// `period`) — ПОДТВЕРЖДЕНО реальным ответом сервера: первая попытка с
    /// `period=` дала 422 `{"time":["Поле Время обязательно для
    /// заполнения."]}` — сервер вообще не увидел параметр под тем именем.
    /// `sort`/значения sort_by — см. TopViewsSort: сами они всё ещё
    /// best-effort догадка (сервер на них не жаловался в том же перехвате,
    /// но и 200 с реальными данными пока не подтверждён).
    func fetchTopViews(page: Int = 1, period: TopViewsPeriod = .day, sort: TopViewsSort = .popular) async throws -> CatalogPage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "time", value: period.rawValue)
        ]
        if let sortBy = sort.apiSortBy {
            items.append(URLQueryItem(name: "sort_by", value: sortBy))
        }
        let request = try makeRequest(path: "/media/top-views", queryItems: items)
        let response: APIListResponse<MangaItem> = try await perform(request)
        return CatalogPage(items: response.data, hasNextPage: response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// Виджеты главной страницы (коллекции + топ активных читателей недели,
    /// см. HomeWidgetsPayload) — ЭНДПОИНТ НЕ ПОДТВЕРЖДЁН. В обоих
    /// перехваченных дампах от пользователя виден только домен
    /// api.cdnlibs.org и голый путь "/api/" без query — судя по всему,
    /// инструмент перехвата обрезал настоящие путь/тело запроса, сама ФОРМА
    /// ответа (HomeWidgetsPayload) при этом подтверждена дважды дословно.
    /// Путь ниже — правдоподобная догадка по конвенции остальных эндпоинтов
    /// этого файла. Если сервер ответит не 200 — вызывающий код (см.
    /// HomeViewModel) просто не показывает эти два раздела, приложение не
    /// падает. Чтобы поправить: перехватить реальный запрос (DevTools →
    /// Network на mangalib.me, "Copy as cURL") и подставить точный путь сюда.
    func fetchHomeWidgets() async throws -> HomeWidgetsPayload {
        let request = try makeRequest(path: "/home", queryItems: [])
        let response: APIObjectResponse<HomeWidgetsPayload> = try await perform(request)
        return response.data
    }

    /// Профиль текущего пользователя (ник + аватар) — только когда есть токен
    /// сессии (см. AuthSession), иначе сервер вернёт 401.
    /// `GET /auth/me`
    func fetchCurrentUser() async throws -> CurrentUser {
        let request = try makeRequest(path: "/auth/me", queryItems: [])
        let response: APIObjectResponse<CurrentUser> = try await perform(request)
        return response.data
    }

    /// Комментарии пользователя — ПОДТВЕРЖДЕНО перехватом
    /// `GET /user/{id}/comments?page=&sort_by=id&sort_type=desc`.
    func fetchUserComments(userId: Int, page: Int, sortType: String) async throws -> (comments: [UserComment], hasNextPage: Bool) {
        let items = [
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "sort_by", value: "id"),
            URLQueryItem(name: "sort_type", value: sortType)
        ]
        let request = try makeRequest(path: "/user/\(userId)/comments", queryItems: items)
        let response: LossyListResponse<UserComment> = try await perform(request)
        return (response.data, response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// Удаление своего комментария — ПОДТВЕРЖДЕНО перехватом
    /// `DELETE /comments/{id}` → 200 `{data:{toast:{message:"Комментарий был удалён"}}}`.
    func deleteComment(id: Int) async throws {
        let request = try makeRequest(path: "/comments/\(id)", queryItems: [], method: "DELETE")
        try await performVoid(request)
    }

    /// Профиль пользователя — ПОДТВЕРЖДЕНО перехватом `GET /user/{id}?fields[]=…`.
    func fetchUserProfile(id: Int) async throws -> UserProfile {
        let items = ["about", "gender", "background", "avatar_frame_id", "premium_background_id", "points"]
            .map { URLQueryItem(name: "fields[]", value: $0) }
        let request = try makeRequest(path: "/user/\(id)", queryItems: items)
        let response: APIObjectResponse<UserProfile> = try await perform(request)
        return response.data
    }

    /// Статистика профиля — ПОДТВЕРЖДЕНО перехватом `GET /user/{id}/stats`.
    func fetchUserStats(id: Int) async throws -> UserStats {
        let request = try makeRequest(path: "/user/\(id)/stats", queryItems: [])
        let response: APIObjectResponse<UserStats> = try await perform(request)
        return response.data
    }

    /// Тайтлы из закладок АККАУНТА на сервере — отдельного эндпоинта "мои
    /// закладки" в API нет (подтверждено по нескольким открытым клиентам —
    /// Kotatsu, Tachiyomi-расширение mangalib и др.): это тот же каталожный
    /// `/manga`, но с фильтром `bookmarks[]=<numericFolderId>` и токеном
    /// авторизации (см. AuthSession) — сервер сам подставляет "мои" по токену.
    /// Работает только с валидным Bearer-токеном, иначе вернёт пусто/401.
    /// Числовые id папок: 1=Читаю, 2=В планах, 3=Брошено, 4=Прочитано, 5=Любимые.
    /// Закладки строго привязаны к ОДНОМУ активному сайту (не к
    /// effectiveSearchSites) — по требованию: чтобы увидеть закладки с
    /// HentaiLib, находясь на MangaLib, нужно сначала переключить активный
    /// сайт в меню.
    func fetchBookmarks(numericFolderId: Int, page: Int = 1) async throws -> CatalogPage {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "fields[]", value: "rate"),
            URLQueryItem(name: "fields[]", value: "rate_avg"),
            URLQueryItem(name: "fields[]", value: "userBookmark"),
            URLQueryItem(name: "fields[]", value: "releaseDate"),
            URLQueryItem(name: "site_id[]", value: String(SiteSession.shared.activeSite.rawValue)),
            URLQueryItem(name: "bookmarks[]", value: String(numericFolderId)),
            URLQueryItem(name: "page", value: String(max(page, 1)))
        ]
        let request = try makeRequest(path: "/manga", queryItems: items)
        let response: APIListResponse<MangaItem> = try await perform(request)
        return CatalogPage(items: response.data, hasNextPage: response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// НАСТОЯЩИЙ эндпоинт "мои закладки" аккаунта — `GET /bookmarks?page=&
    /// sort_by=name&sort_type=desc&status=<N>&user_id=<accountId>`,
    /// подтверждено реальным перехваченным запросом (см. чат/файл
    /// "Релализация ЗАКЛАДОК норм.txt"). В отличие от fetchBookmarks(numericFolderId:)
    /// выше (который на самом деле бьёт по каталожному /manga?bookmarks[]= и
    /// никогда не отдаёт настоящий id записи закладки), этот эндпоинт
    /// возвращает объекты с "id" САМОЙ ЗАПИСИ закладки — то, чего не хватало
    /// для настоящего DELETE /bookmarks/{id} у закладок, подтянутых через
    /// синхронизацию (а не добавленных в этой сессии через setBookmarkStatus).
    /// `status = 0` в перехваченном запросе соответствует вкладке "Все" на
    /// сайте — одним запросом получаем закладки из ВСЕХ папок сразу, дальше
    /// раскладываем по `entry.status` локально (см. BookmarksStore.syncFromServer).
    /// Требует numeric id аккаунта (`AuthSession.userId`, из /auth/me).
    /// ВАЖНО: при холодном старте `AuthSession.init()` запускает `refreshProfile()`
    /// (получает userId) и `syncAccountData()` → `syncFromServer()` (нужен
    /// userId) как ДВА ПАРАЛЛЕЛЬНЫХ Task без гарантии порядка — раньше здесь
    /// просто бросали ошибку, если userId ещё не пришёл, и тогда вся
    /// синхронизация закладок молча проваливалась (а поскольку
    /// BookmarksView.task выполняется один раз за жизнь вьюхи, эта ОДНА
    /// неудачная попытка означала, что serverId так и не подтягивался за всю
    /// сессию — отсюда и "удаление не работает", хотя эндпоинт был верный).
    /// Теперь вместо броска — при отсутствии кэша донтягиваем /auth/me прямо
    /// здесь и кэшируем результат обратно в AuthSession, чтобы больше не
    /// зависеть от того, успел ли параллельный refreshProfile() отработать.
    func fetchBookmarksAccountList(status: Int = 0, page: Int = 1) async throws -> (items: [BookmarkListEntry], hasNextPage: Bool) {
        let userId: Int
        if let cached = AuthSession.shared.userId {
            userId = cached
        } else {
            let user = try await fetchCurrentUser()
            await AuthSession.shared.cacheUserId(user.id)
            userId = user.id
        }
        let items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "sort_by", value: "name"),
            URLQueryItem(name: "sort_type", value: "desc"),
            URLQueryItem(name: "status", value: String(status)),
            URLQueryItem(name: "user_id", value: String(userId))
        ]
        let request = try makeRequest(path: "/bookmarks", queryItems: items)
        // LossyListResponse, а не APIListResponse — обычный `[T]` атомарен:
        // если хотя бы ОДНА закладка в списке "битая" (например, снятый с
        // публикации тайтл), весь decode массива падает и synchFromServer
        // тихо ничего не получает вообще (см. комментарий у LossyArray).
        let response: LossyListResponse<BookmarkListEntry> = try await perform(request)
        return (response.data, response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// Изменить статус папки закладок тайтла в РЕАЛЬНОМ аккаунте.
    /// `POST /bookmarks` — реальный, подтверждённый эндпоинт (перехвачен из
    /// Network настоящего приложения/сайта, не из открытых read-only
    /// клиентов — там его не было, поэтому раньше мы не знали о нём).
    /// Тело: `{"media_type":"manga","media_slug":slug,"bookmark":{"status":N},"meta":{}}`.
    /// N совпадает с BookmarkFolder.apiId (1=Читаю, 2=В планах, 3=Брошено,
    /// 4=Прочитано, 5=Любимые) — подтверждено (status:3 → «Брошено», status:5
    /// → «Любимые»). Ответ — `{"data":{"id":N,"type":"manga_bookmark",...}}`,
    /// подтверждено реальным перехваченным запросом — возвращаем этот "id":
    /// это ID самой ЗАПИСИ закладки (не тайтла и не slug), он нужен для
    /// реального удаления (см. removeBookmark(id:) ниже). Декодирование
    /// специально не бросает при ошибке формы — сам факт успешного
    /// статус-кода уже значит, что смена статуса произошла на сервере, даже
    /// если "id" почему-то не удалось прочитать.
    @discardableResult
    func setBookmarkStatus(slug: String, status: Int) async throws -> Int? {
        let payload = BookmarkPayload(media_type: "manga", media_slug: slug, bookmark: .init(status: status), meta: .init())
        let request = try makeJSONRequest(path: "/bookmarks", method: "POST", body: payload)
        let data = try await performOptionalData(request)
        return try? decoder.decode(APIObjectResponse<BookmarkRecordID>.self, from: data).data.id
    }

    /// Убрать тайтл из закладок аккаунта — `DELETE /bookmarks/{id}`, где id —
    /// ЧИСЛОВОЙ id самой записи закладки (см. setBookmarkStatus выше), а НЕ
    /// slug тайтла. ВАЖНО: путь с id подтверждён перехватом, но тело — НЕТ,
    /// раньше здесь отправлялось пустое тело (EmptyBody, `{}`), и реальный
    /// тест через приложение (см. журнал в Настройках → Логи сети) показал
    /// 422: `{"media_type":["Поле media type обязательно для заполнения."]}`.
    /// Значит сервер — Laravel-валидатор, которому и для DELETE по числовому
    /// id всё равно нужно тело с media_type (и, по аналогии с POST/старой
    /// догадкой ниже, media_slug) — поэтому теперь используем тот же
    /// BookmarkPayload, что и setBookmarkStatus, просто без "bookmark" (нет
    /// смысла слать статус при удалении).
    /// Ответ при успехе — `{"data":{"toast":{"type":"info","message":"Тайтл
    /// удалён из вашего списка"}}}`, нам из него ничего не нужно.
    func removeBookmark(id: Int, slug: String) async throws {
        let payload = BookmarkPayload(media_type: "manga", media_slug: slug, bookmark: nil, meta: .init())
        let request = try makeJSONRequest(path: "/bookmarks/\(id)", method: "DELETE", body: payload)
        try await performVoid(request)
    }

    /// Запасной вариант удаления по slug — эндпоинт НЕ подтверждён (см.
    /// комментарий у removeBookmark(id:) выше). Используется, только когда
    /// у локальной записи нет числового serverId.
    func removeBookmarkGuessing(slug: String) async throws {
        let payload = BookmarkPayload(media_type: "manga", media_slug: slug, bookmark: nil, meta: .init())
        let request = try makeJSONRequest(path: "/bookmarks", method: "DELETE", body: payload)
        try await performVoid(request)
    }

    /// Создать пользовательскую папку закладок в РЕАЛЬНОМ аккаунте —
    /// `POST /bookmarks/folder`, подтверждено перехваченным запросом: тело
    /// всего лишь `{"name": "<строка>"}`, сервер сам присваивает id/цвет/
    /// порядок/site_ids. Ответ (201 Created) — `{"data":{"id":N,"name":...,
    /// "public":false,"notify":false,"color":"#...","textColor":"#...",
    /// "order":N,"count":0,"site_ids":[...]}}`. Нам из ответа нужен только
    /// числовой id — он потребуется, если понадобится настоящее удаление/
    /// переименование папки на сервере (эти эндпоинты пока не перехвачены).
    func createBookmarkFolder(name: String) async throws -> ServerBookmarkFolder {
        let request = try makeJSONRequest(path: "/bookmarks/folder", method: "POST", body: CreateFolderPayload(name: name))
        let response: APIObjectResponse<ServerBookmarkFolder> = try await perform(request)
        return response.data
    }

    /// Отмечает главу просмотренной в РЕАЛЬНОМ аккаунте — настоящий,
    /// подтверждённый эндпоинт (перехвачен из Network сайта, ответ содержит
    /// `"message": "Глава помечена просмотренной"`). Это и есть настоящий
    /// триггер записи истории — обычный `GET .../chapter?number=&volume=`
    /// (fetchPages, который мы и так вызываем при чтении) её НЕ пишет, как
    /// предполагалось раньше; это отдельный, специальный вызов.
    /// `POST /manga/{manga_id}/chapters/{chapter_id}/view`, без тела.
    func markChapterViewed(mangaId: Int, chapterId: Int) async throws {
        var request = try makeRequest(path: "/manga/\(mangaId)/chapters/\(chapterId)/view", queryItems: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await performVoid(request)
    }

    /// Реальная история чтения аккаунта — `GET /user/chapters/history?page=N`.
    /// Подтверждённый перехватом настоящего запроса эндпоинт (см. чат).
    /// Пагинация: страниц запрашивают, пока сервер не вернёт пустой список —
    /// отдельного meta.has_next_page для этого эндпоинта не подтверждено.
    func fetchHistory(page: Int = 1) async throws -> [HistoryEntry] {
        let items: [URLQueryItem] = [URLQueryItem(name: "page", value: String(max(page, 1)))]
        let request = try makeRequest(path: "/user/chapters/history", queryItems: items)
        let response: APIListResponse<HistoryEntry> = try await perform(request)
        return response.data
    }

    /// `GET /comments?page=&post_id=&post_type=&sort_by=id&sort_type=desc` —
    /// ПОДТВЕРЖДЕНО реальным перехваченным запросом. Ответ — ДВА отдельных
    /// массива под "data": "root" (корневые, comment_level:0) и "replies"
    /// (вложенные ответы, comment_level>=1) + честная "meta.has_next_page"
    /// (см. CommentsListResponse — раньше это было неподтверждённым
    /// предположением, что "replies" содержит ВСЁ одним списком и что
    /// пагинации приходится добиваться эвристикой; пользователь прислал
    /// перехват из devtools самого сайта, который опроверг оба предположения).
    /// Дерево строится на клиенте по comment_level/parent_comment (см.
    /// Comment.groupedByParent) из объединённого root+replies.
    /// `sortType` — "desc" (новые сначала, подтверждённый дефолт сайта) или
    /// "asc" (старые сначала) — тот же параметр, что и в запросе, просто
    /// переворачиваем значение; сортировка "Популярные" — НЕ через сервер (не
    /// подтверждено, что сервер это умеет), считается на клиенте по score
    /// (см. MangaDetailViewModel.commentSort/MangaDetailView).
    func fetchComments(postId: Int, postType: String = "manga", postPage: Int? = nil, sortBy: String = "id", sortType: String = "desc", page: Int = 1) async throws -> (comments: [Comment], hasNextPage: Bool) {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "post_id", value: String(postId)),
            URLQueryItem(name: "post_type", value: postType),
            // ПОДТВЕРЖДЕНО перехватом: Новые — id/desc, Старые — id/asc,
            // Популярные — votes_up/desc (серверная сортировка по популярности).
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "sort_type", value: sortType),
            URLQueryItem(name: "page", value: String(max(page, 1)))
        ]
        // Комментарии в читалке привязаны к конкретной СТРАНИЦЕ главы (post_page).
        if let postPage {
            items.append(URLQueryItem(name: "post_page", value: String(postPage)))
        }
        let request = try makeRequest(path: "/comments", queryItems: items)
        let response: CommentsListResponse = try await perform(request)
        return (response.comments, response.hasNextPage)
    }

    /// `POST /comments` — ПОДТВЕРЖДЕНО реальным перехваченным запросом (см.
    /// "comments Отправка.txt", 201 Created): ответ реально возвращает
    /// созданный комментарий целиком (та же форма, что и в списке, см.
    /// Comment) — поэтому возвращаем его, а не просто успех/провал, чтобы
    /// сразу вставить в список без полной перезагрузки.
    ///
    /// Тело запроса ИСПРАВЛЕНО по РЕАЛЬНОМУ ответу сервера (422, перехвачен
    /// пользователем через NetworkLogsView) на первую версию (обычная строка
    /// + без comment_level):
    ///   {"data":{"comment":["Имеется неизвестный блок «null»"],
    ///            "comment_level":["Поле comment level обязательно для заполнения."]}}
    /// Отсюда два подтверждённых факта: 1) поле comment_level ОБЯЗАТЕЛЬНО в
    /// запросе (сервер его не вычисляет сам из parent_comment, как
    /// предполагалось раньше) — 0 для корневого, иначе commentLevel
    /// родителя+1 (та же схема, что видна в подтверждённых GET-ответах:
    /// root=0, прямой ответ=1 и т.д.); 2) "неизвестный блок «null»" при
    /// отправке ОБЫЧНОЙ строки — это формулировка ошибки rich-text/ProseMirror
    /// валидатора про НЕИЗВЕСТНЫЙ ТИП БЛОКА, а не просто "строка не подходит".
    /// В этом же API поле summary (MangaDetail) подтверждённо приходит именно
    /// ProseMirror-деревом `{"type":"doc","content":[{"type":"paragraph",
    /// "content":[{"type":"text","text":"..."}]}]}` (см. SummaryDoc в
    /// MangaModels.swift) — по аналогии с ЭТИМ ЖЕ полем в ЭТОМ ЖЕ API комментарий,
    /// скорее всего, ожидается в такой же форме. Это ОБОСНОВАННОЕ предположение
    /// по аналогии (не гадание с нуля) — если сервер всё ещё вернёт 422, тело
    /// снова будет видно в NetworkLogsView и можно поправить точнее.
    func postComment(postId: Int, postType: String = "manga", postPage: Int? = nil, text: String, commentLevel: Int, parentComment: Int? = nil) async throws -> Comment {
        let payload = CommentPayload(
            post_id: postId, post_type: postType, post_page: postPage,
            comment: ProseMirrorDoc(text: text),
            comment_level: commentLevel,
            parent_comment: parentComment
        )
        let request = try makeJSONRequest(path: "/comments", method: "POST", body: payload)
        let response: APIObjectResponse<Comment> = try await perform(request)
        return response.data
    }

    /// Голосование за комментарий — ПОДТВЕРЖДЕНО реальным перехватом:
    /// `POST /comments/{id}/vote`, тело `{"vote":1}` (плюс), ответ
    /// `{"data":{"up":8,"down":0,"user":1}}` — актуальные счётчики + голос юзера
    /// (1 = плюс, 0 = минус, null = не голосовал), как и у «Похожего». Возвращаем
    /// их, чтобы сразу обновить UI без перезагрузки списка.
    @discardableResult
    func voteComment(id: Int, direction: Int) async throws -> SimilarVotes {
        let payload = CommentVotePayload(vote: direction)
        let request = try makeJSONRequest(path: "/comments/\(id)/vote", method: "POST", body: payload)
        let response: APIObjectResponse<SimilarVotes> = try await perform(request)
        return response.data
    }

    /// Справочники фильтров (жанры, теги, типы и т.д.) с реальными id.
    func fetchConstants() async throws -> ConstantsResponse.Payload {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "fields[]", value: "genres"),
            URLQueryItem(name: "fields[]", value: "tags"),
            URLQueryItem(name: "fields[]", value: "types"),
            URLQueryItem(name: "fields[]", value: "format"),
            URLQueryItem(name: "fields[]", value: "status"),
            URLQueryItem(name: "fields[]", value: "scanlateStatus"),
            URLQueryItem(name: "fields[]", value: "ageRestriction"),
            // Не подтверждено перехватом реального запроса (в отличие от
            // остальных полей выше) — но безопасно попробовать: если сервер
            // не знает такого поля, он его просто не вернёт (imageServers
            // останется nil), и приложение продолжит работать на
            // захардкоженном списке (см. MangaImageURL.imageServers).
            URLQueryItem(name: "fields[]", value: "imageServers")
        ]
        let request = try makeRequest(path: "/constants", queryItems: items)
        let response: ConstantsResponse = try await perform(request)
        return response.data
    }

    private func appendRange(_ items: inout [URLQueryItem], _ name: String, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { items.append(URLQueryItem(name: name, value: v)) }
    }

    private func appendSet(_ items: inout [URLQueryItem], _ name: String, _ set: Set<Int>) {
        for id in set.sorted() {
            items.append(URLQueryItem(name: name, value: String(id)))
        }
    }

    /// Добавляет трёхпозиционный выбор: `{name}[]` для включённых и `{name}_exclude[]` для исключённых.
    private func appendTri(_ items: inout [URLQueryItem], _ name: String, _ selection: TriStateSelection) {
        appendSet(&items, "\(name)[]", selection.included)
        appendSet(&items, "\(name)_exclude[]", selection.excluded)
    }

    /// Детальная информация о манге по её slug.
    /// `GET /manga/{slug}?fields[]=summary&fields[]=genres&fields[]=tags&fields[]=authors&fields[]=format&fields[]=releaseDate&fields[]=views`
    ///
    /// НАЙДЕНА И ИСПРАВЛЕНА РЕАЛЬНАЯ ПРИЧИНА ошибки 422 на этом эндпоинте:
    /// раньше здесь ЕЩЁ был "fields[]=description" (добавлен "на всякий
    /// случай" в одном из более ранних раундов, ДО того как был получен
    /// подтверждённый сырой JSON ответа). Судя по всему сервер валидирует
    /// значения fields[] по белому списку (похоже на Laravel FormRequest
    /// + Rule::in([...])) — и ОДНО неизвестное серверу значение ("description"
    /// — такого поля в ответе вообще не существует, реальное поле называется
    /// "summary") валит ВЕСЬ запрос целиком с 422, а не просто игнорируется.
    /// Именно это полностью объясняло, почему до сих пор не приходили ни
    /// summary, ни releaseDate, ни views, ни format — весь /manga/{slug}
    /// падал целиком, а Тип/Статус в UI продолжали показываться только
    /// благодаря запасному пути через listItem (данные из каталога).
    /// Все ОСТАЛЬНЫЕ значения ниже подтверждены — каждое из них реально
    /// присутствует как ключ в перехваченном сыром JSON ответа.
    ///
    /// "background" добавлен отдельно и тоже ПОДТВЕРЖДЁН реальным перехватом
    /// (запрос настоящего сайта включал fields[]=background среди прочих, и
    /// ответ реально содержал ключ "background": {"filename":...,"url":...}) —
    /// см. MangaDetail.background/MangaBackgroundImage. Без явного fields[]
    /// сервер это поле не присылает вообще, так же как summary/genres/etc.
    func fetchMangaDetail(slug: String, siteId: Int? = nil) async throws -> MangaDetail {
        let data = try await fetchMangaDetailRawData(slug: slug, siteId: siteId)
        do {
            return try decoder.decode(APIObjectResponse<MangaDetail>.self, from: data).data
        } catch {
            throw NetworkError.decoding(error)
        }
    }

    /// Сырое тело ответа карточки тайтла — используется как fetchMangaDetail
    /// (то же самое HTTP-декодирование/статус-коды), но без разбора в модель.
    /// Нужно DownloadsManager, чтобы сохранить JSON на диск и открыть
    /// скачанный тайтл офлайн с тем же описанием/оценкой, что и онлайн (см.
    /// DownloadsManager.cachedDetail).
    func fetchMangaDetailRawData(slug: String, siteId: Int? = nil) async throws -> Data {
        let items: [URLQueryItem] = [
            // Оценка тайтла: без явных rate/rate_avg сервер НЕ кладёт объект
            // `rating` в ответ, и на карточке (обложка/виджет) оценка пропадала
            // при входе из закладок/«Похожего», где у элемента её нет. Оба поля
            // подтверждены рабочим каталогом (fields[]=rate&fields[]=rate_avg).
            URLQueryItem(name: "fields[]", value: "rate"),
            URLQueryItem(name: "fields[]", value: "rate_avg"),
            URLQueryItem(name: "fields[]", value: "summary"),
            URLQueryItem(name: "fields[]", value: "genres"),
            URLQueryItem(name: "fields[]", value: "tags"),
            URLQueryItem(name: "fields[]", value: "authors"),
            URLQueryItem(name: "fields[]", value: "format"),
            URLQueryItem(name: "fields[]", value: "releaseDate"),
            URLQueryItem(name: "fields[]", value: "views"),
            URLQueryItem(name: "fields[]", value: "background"),
            // ПОДТВЕРЖДЕНО реальным перехватом запроса сайта (fields[]=otherNames,
            // fields[]=eng_name → 200): альтернативные названия и английское имя
            // для sheet по тапу на название (см. TitleNamesSheet / MangaDetail).
            URLQueryItem(name: "fields[]", value: "otherNames"),
            URLQueryItem(name: "fields[]", value: "eng_name"),
            // "moderated" — ПОДТВЕРЖДЕНО реальным перехваченным запросом (см.
            // MangaDetail.moderated) — нужно для проверки "главы удалены по
            // требованию правообладателя/РКН, либо тайтл на проверке".
            URLQueryItem(name: "fields[]", value: "moderated")
        ]
        let request = try makeRequest(path: "/manga/\(encodePath(slug))", queryItems: items, siteId: siteId)
        return try await performOptionalData(request)
    }

    /// Список глав манги.
    /// `GET /manga/{slug}/chapters`
    func fetchChapters(slug: String, siteId: Int? = nil) async throws -> [ChapterItem] {
        let request = try makeRequest(path: "/manga/\(encodePath(slug))/chapters", queryItems: [], siteId: siteId)
        let response: APIListResponse<ChapterItem> = try await perform(request)
        return response.data
    }

    /// "Похожее" — ПОДТВЕРЖДЕНО реальным перехваченным запросом (пользователь
    /// прислал полное тело ответа): `GET /manga/{slug}/similar` →
    /// `{"data":[{"id","similar","user_id","media":{...MangaItem...},
    /// "votes":{"up","down","user"}}]}`. LossyListResponse — один "битый"
    /// элемент (например, у похожего тайтла media другой формы) не должен
    /// ронять всю карусель.
    func fetchSimilar(slug: String, siteId: Int? = nil) async throws -> [SimilarItem] {
        let request = try makeRequest(path: "/manga/\(encodePath(slug))/similar", queryItems: [], siteId: siteId)
        let response: LossyListResponse<SimilarItem> = try await perform(request)
        return response.data
    }

    /// Статистика тайтла (оценки + распределение по спискам) — ПОДТВЕРЖДЕНО
    /// перехватом: `GET /manga/{slug}/stats` → `{data:{bookmarks, rating}}`.
    func fetchMangaStats(slug: String, siteId: Int? = nil) async throws -> MangaStats {
        let data = try await fetchMangaStatsRawData(slug: slug, siteId: siteId)
        do {
            return try decoder.decode(APIObjectResponse<MangaStats>.self, from: data).data
        } catch {
            throw NetworkError.decoding(error)
        }
    }

    /// Сырое тело ответа статистики — см. fetchMangaDetailRawData, тот же смысл
    /// (кэш для DownloadsManager.cachedStats).
    func fetchMangaStatsRawData(slug: String, siteId: Int? = nil) async throws -> Data {
        // ОБЯЗАТЕЛЬНЫЕ query-параметры (подтверждено перехватом
        // `/manga/{slug}/stats?bookmarks=true&rating=true`) — без них сервер
        // не включает эти блоки в ответ.
        let items = [
            URLQueryItem(name: "bookmarks", value: "true"),
            URLQueryItem(name: "rating", value: "true")
        ]
        let request = try makeRequest(path: "/manga/\(encodePath(slug))/stats", queryItems: items, siteId: siteId)
        return try await performOptionalData(request)
    }

    /// Персонажи тайтла — ПОДТВЕРЖДЕНО перехватом:
    /// `GET /character?media_id={mangaId}&media_type=manga&limit=0` →
    /// `{data:[{id, slug_url, cover, name, rus_name, details:{position}}]}`.
    /// LossyListResponse — один «битый» персонаж не должен ронять всю строку.
    func fetchCharacters(mangaId: Int, siteId: Int? = nil) async throws -> [Character] {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "media_id", value: String(mangaId)),
            URLQueryItem(name: "media_type", value: "manga"),
            URLQueryItem(name: "limit", value: "0")
        ]
        let request = try makeRequest(path: "/character", queryItems: items, siteId: siteId)
        let response: LossyListResponse<Character> = try await perform(request)
        return response.data
    }

    /// Детальная страница персонажа — ПОДТВЕРЖДЕНО перехватом:
    /// `GET /character/{slug_url}` → `{data:{..., alt_name, dsc, stats,
    /// titles_count_details}}`.
    func fetchCharacterDetail(slugURL: String) async throws -> CharacterDetail {
        let request = try makeRequest(path: "/character/\(encodePath(slugURL))", queryItems: [])
        let response: APIObjectResponse<CharacterDetail> = try await perform(request)
        return response.data
    }

    /// Голос "+"/"-" за рекомендацию из "Похожего" — ПОДТВЕРЖДЕНО реальным
    /// перехватом: `POST /similar/{id}/vote`, тело `{"vote":1}` для "+",
    /// `{"vote":0}` для "-"; ответ — АКТУАЛЬНЫЕ up/down/user целиком (не
    /// просто успех/провал), поэтому возвращаем SimilarVotes и сразу
    /// подставляем в UI вместо перезагрузки всего списка (см.
    /// MangaDetailViewModel.voteSimilar). `id` здесь — id ЭЛЕМЕНТА "Похожего"
    /// (SimilarItem.id), а НЕ id самой манги — тоже подтверждено перехватом
    /// (URL был `/similar/492/vote`, где 492 — id элемента из списка).
    func voteSimilar(id: Int, isUp: Bool) async throws -> SimilarVotes {
        let payload = SimilarVotePayload(vote: isUp ? 1 : 0)
        let request = try makeJSONRequest(path: "/similar/\(id)/vote", method: "POST", body: payload)
        let response: APIObjectResponse<SimilarVotes> = try await perform(request)
        return response.data
    }

    /// "Связанное" — ПОДТВЕРЖДЕНО реальным перехваченным запросом (пользователь
    /// прислал полное тело ответа): `GET /manga/{slug}/relations` →
    /// `{"data":[{"order","related_type":{"id","label"},"media":{...MangaItem...}}]}`.
    /// В отличие от "Похожего" — без голосов, без своего "id" у элемента (см.
    /// RelatedItem). Может быть пустым (у большинства тайтлов связей нет) —
    /// UI просто скрывает блок, см. MangaDetailView.relatedSection.
    func fetchRelated(slug: String, siteId: Int? = nil) async throws -> [RelatedItem] {
        let request = try makeRequest(path: "/manga/\(encodePath(slug))/relations", queryItems: [], siteId: siteId)
        let response: LossyListResponse<RelatedItem> = try await perform(request)
        return response.data
    }

    // MARK: - Уведомления

    /// `GET /notifications?notification_type=all&page=&read_type=&sort_type=` —
    /// ПОДТВЕРЖДЕНО реальным перехватом (три devtools-файла от пользователя).
    /// `notification_type` зафиксирован как "all" — отдельный фильтр по
    /// категориям (chapter/comments/message/card/...) в этом раунде не
    /// запрашивался, оставлен как есть, раз подтверждённое значение — "all".
    /// Ни в одном перехвате нет meta для этого эндпоинта — как и у fetchHistory,
    /// используем эвристику "непустая страница = вероятно есть ещё" через
    /// LossyListResponse.meta (там уже есть fallback на !data.isEmpty).
    func fetchNotifications(readType: String, sortType: String, page: Int = 1) async throws -> (items: [NotificationItem], hasNextPage: Bool) {
        let items: [URLQueryItem] = [
            URLQueryItem(name: "notification_type", value: "all"),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "read_type", value: readType),
            URLQueryItem(name: "sort_type", value: sortType)
        ]
        let request = try makeRequest(path: "/notifications", queryItems: items)
        let response: LossyListResponse<NotificationItem> = try await perform(request)
        return (response.data, response.meta?.hasNextPage ?? !response.data.isEmpty)
    }

    /// `GET /notifications/count` — ПОДТВЕРЖДЕНО реальным перехватом, без
    /// query-параметров: счётчики unread/read/all по категориям.
    func fetchNotificationCounts() async throws -> NotificationCounts {
        let request = try makeRequest(path: "/notifications/count", queryItems: [])
        let response: APIObjectResponse<NotificationCounts> = try await perform(request)
        return response.data
    }

    /// Страницы конкретной главы + признак "уже просмотрена" (см.
    /// ChapterPagesData.isViewed — не подтверждено перехватом, декодируется
    /// защитно, по умолчанию false).
    /// `GET /manga/{slug}/chapter?number={number}&volume={volume}[&branch_id={id}]`
    func fetchPages(slug: String, volume: String, number: String, branchId: Int? = nil, siteId: Int? = nil) async throws -> ChapterPagesResult {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "number", value: number),
            URLQueryItem(name: "volume", value: volume)
        ]
        if let branchId {
            items.append(URLQueryItem(name: "branch_id", value: String(branchId)))
        }
        let request = try makeRequest(path: "/manga/\(encodePath(slug))/chapter", queryItems: items, siteId: siteId)
        let response: ChapterPagesResponse = try await perform(request)
        return ChapterPagesResult(pages: response.data.pages, isViewed: response.data.isViewed ?? false)
    }

    // MARK: - Request building

    /// `siteId` — переопределяет заголовок `Site-Id` для этого запроса (по
    /// умолчанию активный сайт). Нужно для тайтлов с ДРУГОГО сайта (напр. из
    /// «Похожего»/«Связанного»/«Персонажей»): их карточку/главы надо запрашивать
    /// с их собственным Site-Id, иначе сервер отвечает 404.
    private func makeRequest(path: String, queryItems: [URLQueryItem], siteId: Int? = nil, method: String = "GET") throws -> URLRequest {
        // Собираем URL из строки, чтобы избежать percent-encoding разделителей пути
        // (appendingPathComponent мог кодировать «/» и ломать путь → 404).
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard var components = URLComponents(string: baseURL.absoluteString + normalizedPath) else {
            throw NetworkError.invalidURL
        }
        // URLComponents сам выполняет percent-encoding значений (в т.ч. кириллицы).
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else { throw NetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let siteId {
            request.setValue(String(siteId), forHTTPHeaderField: "Site-Id")
        }
        return request
    }

    /// Запрос с JSON-телом (POST/DELETE и т.д.) — для write-эндпоинтов вроде
    /// /bookmarks, в отличие от makeRequest выше (только GET, без тела).
    private func makeJSONRequest<Body: Encodable>(path: String, method: String, body: Body) throws -> URLRequest {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: baseURL.absoluteString + normalizedPath) else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Percent-encoding сегмента пути (slug может содержать кириллицу/спецсимволы).
    private func encodePath(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }

    // MARK: - Execution

    /// ЕДИНАЯ точка, через которую реально уходит каждый запрос приложения —
    /// perform/performVoid/performOptionalData ниже это просто три разных
    /// обработчика РЕЗУЛЬТАТА одного и того же вызова (декодировать в T /
    /// игнорировать тело / вернуть тело как есть). Именно поэтому запись в
    /// NetworkLogger (см. NetworkLogger.swift — debug-журнал сети в Настройках)
    /// сделана ровно тут один раз, а не в каждом из трёх методов отдельно —
    /// так гарантированно логируется вообще ВСЁ, без риска забыть добавить
    /// логирование в какой-то новый метод в будущем.
    private func executeLogged(_ request: URLRequest) async throws -> (data: Data, http: HTTPURLResponse) {
        let start = Date()
        let method = request.httpMethod ?? "GET"
        let urlString = request.url?.absoluteString ?? "?"
        let requestBody = request.httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            await NetworkLogger.shared.log(method: method, url: urlString, requestBody: requestBody,
                                            statusCode: nil, responseBody: nil,
                                            duration: Date().timeIntervalSince(start),
                                            isError: true, errorText: "Отменено")
            throw NetworkError.cancelled
        } catch is CancellationError {
            await NetworkLogger.shared.log(method: method, url: urlString, requestBody: requestBody,
                                            statusCode: nil, responseBody: nil,
                                            duration: Date().timeIntervalSince(start),
                                            isError: true, errorText: "Отменено")
            throw NetworkError.cancelled
        } catch {
            await NetworkLogger.shared.log(method: method, url: urlString, requestBody: requestBody,
                                            statusCode: nil, responseBody: nil,
                                            duration: Date().timeIntervalSince(start),
                                            isError: true, errorText: "\(error)")
            throw NetworkError.transport(error)
        }

        let duration = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else {
            await NetworkLogger.shared.log(method: method, url: urlString, requestBody: requestBody,
                                            statusCode: nil, responseBody: data, duration: duration,
                                            isError: true, errorText: "Ответ не HTTP")
            throw NetworkError.server(status: -1)
        }

        await NetworkLogger.shared.log(method: method, url: urlString, requestBody: requestBody,
                                        statusCode: http.statusCode, responseBody: data, duration: duration,
                                        isError: !(200...299).contains(http.statusCode))
        return (data, http)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, http) = try await executeLogged(request)

        switch http.statusCode {
        case 200...299:
            break
        case 403:
            throw NetworkError.forbidden
        case 404:
            throw NetworkError.notFound
        case 429:
            throw NetworkError.rateLimited
        default:
            throw NetworkError.server(status: http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(error)
        }
    }

    /// То же самое, что perform(_:) выше, но без декодирования ответа —
    /// для write-эндпоинтов (/bookmarks), чей формат ответа нам не известен
    /// и не нужен: важен только успешный статус-код.
    private func performVoid(_ request: URLRequest) async throws {
        let (_, http) = try await executeLogged(request)

        switch http.statusCode {
        case 200...299:
            return
        case 403:
            throw NetworkError.forbidden
        case 404:
            throw NetworkError.notFound
        case 429:
            throw NetworkError.rateLimited
        default:
            throw NetworkError.server(status: http.statusCode)
        }
    }

    /// Как performVoid — проверяет статус-код и бросает при ошибке — но
    /// возвращает "сырое" тело ответа, если оно нужно вызывающему коду
    /// (например, setBookmarkStatus хочет достать id записи закладки из
    /// ответа). В отличие от perform(_:) НЕ бросает при ошибке декодирования
    /// — сам факт успешного статус-кода уже значит, что действие на сервере
    /// произошло, а тело ответа — это "бонус", терять который из-за
    /// непредвиденной формы JSON не стоит.
    private func performOptionalData(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await executeLogged(request)

        switch http.statusCode {
        case 200...299:
            return data
        case 403:
            throw NetworkError.forbidden
        case 404:
            throw NetworkError.notFound
        case 429:
            throw NetworkError.rateLimited
        default:
            throw NetworkError.server(status: http.statusCode)
        }
    }
}

/// Тело запроса POST/DELETE /bookmarks — см. setBookmarkStatus/removeBookmark.
/// `bookmark` = nil при удалении (сервер, предположительно, не ждёт статус
/// в теле DELETE-запроса — это неподтверждённое предположение, см. комментарий
/// у removeBookmark).
private struct BookmarkPayload: Encodable {
    let media_type: String
    let media_slug: String
    let bookmark: BookmarkStatus?
    let meta: EmptyMeta

    struct BookmarkStatus: Encodable { let status: Int }
    struct EmptyMeta: Encodable {}
}

/// БОЛЬШЕ НЕ ИСПОЛЬЗУЕТСЯ — раньше это было тело для DELETE /bookmarks/{id},
/// пока реальный тест через приложение не показал 422 "media type обязательно
/// для заполнения" (см. removeBookmark(id:slug:) выше): пустое тело там не
/// подходит, нужен BookmarkPayload с media_type/media_slug. Оставлено на
/// случай, если ещё где-то понадобится буквально пустое `{}` тело.
private struct EmptyBody: Encodable {}

/// Достаём из ответа POST /bookmarks только "id" записи закладки — остальные
/// поля (progress/status/item/...) нам здесь не нужны, см. setBookmarkStatus.
private struct BookmarkRecordID: Decodable {
    let id: Int
}

/// Тело запроса POST /bookmarks/folder — см. createBookmarkFolder.
private struct CreateFolderPayload: Encodable {
    let name: String
}

/// Тело запроса POST /comments — см. MangaNetworkService.postComment. post_id/
/// post_type/comment_level/parent_comment подтверждены реальным 422-ответом
/// сервера (см. комментарий у postComment); форма самого поля `comment` —
/// обоснованное предположение по аналогии с полем summary этого же API (см.
/// ProseMirrorDoc ниже).
private struct CommentPayload: Encodable {
    let post_id: Int
    let post_type: String
    /// Страница главы для комментариев в читалке (nil у комментариев тайтла —
    /// синтезированный Encodable опускает nil-поля, так что для manga его нет).
    let post_page: Int?
    let comment: ProseMirrorDoc
    let comment_level: Int
    let parent_comment: Int?
}

/// Rich-text дерево в формате ProseMirror/TipTap — та же форма, в которой
/// сервер ПОДТВЕРЖДЁННО отдаёт поле summary у тайтла (см. SummaryDoc в
/// MangaModels.swift: `{"type":"doc","content":[{"type":"paragraph",
/// "content":[{"type":"text","text":"..."}]}]}`). Строится из простого
/// текста здесь для отправки комментария — см. постановку задачи у
/// MangaNetworkService.postComment (ошибка сервера "неизвестный блок «null»"
/// при отправке обычной строки).
private struct ProseMirrorDoc: Encodable {
    let type = "doc"
    let content: [ProseMirrorParagraph]

    /// Перенос строки → новый параграф (обычное поведение rich-text
    /// редакторов: Enter = новый блок), пустые параграфы просто без text-узла.
    init(text: String) {
        content = text.components(separatedBy: "\n").map(ProseMirrorParagraph.init)
    }
}

private struct ProseMirrorParagraph: Encodable {
    let type = "paragraph"
    let content: [ProseMirrorText]

    init(_ text: String) {
        content = text.isEmpty ? [] : [ProseMirrorText(text: text)]
    }
}

private struct ProseMirrorText: Encodable {
    let type = "text"
    let text: String
}

/// Тело запроса голосования — см. MangaNetworkService.voteComment (эндпоинт
/// НЕ подтверждён, метод сейчас нигде не вызывается из UI).
private struct CommentVotePayload: Encodable {
    let vote: Int
}

/// Тело запроса голоса за "Похожее" — см. MangaNetworkService.voteSimilar.
/// ПОДТВЕРЖДЕНО реальным перехватом: `{"vote":1}` для "+", `{"vote":0}` для
/// "-" (та же форма, что и у CommentVotePayload выше, но отдельный тип —
/// разные эндпоинты, не хочется случайно смешивать неподтверждённое с
/// подтверждённым).
private struct SimilarVotePayload: Encodable {
    let vote: Int
}

// MARK: - Выбор сервера картинок (Первый / Второй / Сжатия)

/// Как на сайте MangaLib — три варианта сервера картинок. Пользователь
/// выбирает предпочитаемый (в читалке-настройках и в окне скачивания); он
/// пробуется ПЕРВЫМ, остальные остаются резервом (см. MangaImageURL.pageURLs).
/// Значение хранится в UserDefaults по ключу Key.
enum ImageServerChoice: Int, CaseIterable, Identifiable {
    case first = 0     // Первый  (основной)
    case second = 1    // Второй  (зеркало)
    case compress = 2  // Сжатия  (сжатый/лёгкий)

    var id: Int { rawValue }
    static let defaultsKey = "image_server_choice"

    var title: String {
        switch self {
        case .first:    return "Первый"
        case .second:   return "Второй"
        case .compress: return "Сжатия"
        }
    }

    /// Базовый хост для этого варианта. Значения — известные серверы картинок
    /// экосистемы Lib (могут быть перекрыты реальным списком из /constants, см.
    /// MangaImageURL.updateServers).
    var baseURL: String {
        switch self {
        case .first:    return "https://img2.imglib.info"
        case .second:   return "https://img4.imgslib.link"
        case .compress: return "https://img3.cdnlibs.org"
        }
    }

    /// Текущее сохранённое значение (по умолчанию — Первый).
    static var current: ImageServerChoice {
        ImageServerChoice(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .first
    }
}

// MARK: - Image URL helpers

/// Построение полных URL изображений (обложки/страницы) из относительных путей.
enum MangaImageURL {

    /// Захардкоженный запасной список — используется, пока реальный список с
    /// сервера ещё не подтянулся (или если сервер вообще не отдаёт это поле,
    /// см. ConstantsResponse.Payload.imageServers).
    private static let fallbackServers: [String] = [
        "https://img2.imglib.info",   // main / secondary
        "https://img3.cdnlibs.org",   // compress / download
        "https://img4.imgslib.link"   // дополнительный резерв
    ]

    /// Серверы картинок MangaLib (site_id = 1). Изначально — захардкоженный
    /// список выше; при успешной загрузке /constants (см. ConstantsStore)
    /// подставляются РЕАЛЬНЫЕ серверы с сервера первыми (в приоритете), а
    /// захардкоженные остаются следом как дополнительный резерв — так,
    /// даже если формат ответа сервера окажется неожиданным, ничего не
    /// сломается, просто список останется прежним.
    /// Порядок = приоритет; при неудаче загрузчик пробует следующий.
    static var imageServers: [String] = fallbackServers

    /// Вызывается один раз из ConstantsStore после успешной загрузки
    /// /constants — если сервер реально прислал список, ставит его первым,
    /// сохраняя захардкоженные как резерв (без дублей).
    static func updateServers(fromAccount servers: [String]) {
        guard !servers.isEmpty else { return }
        var merged = servers
        for fallback in fallbackServers where !merged.contains(fallback) {
            merged.append(fallback)
        }
        imageServers = merged
    }

    /// Все варианты URL страницы (по разным серверам) — для перебора при ошибке загрузки.
    /// Важно: `url` приходит вида «//manga/.../001.jpg» (ведущий двойной слэш) — нормализуем.
    static func pageURLs(for page: PageItem) -> [URL] {
        guard let raw = page.relativePath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return []
        }
        // Локальный файл скачанной страницы (см. DownloadsManager/оффлайн-режим
        // ReaderViewModel) — отдаём как есть, без подстановки серверов картинок.
        if raw.hasPrefix("file://"), let local = URL(string: raw) {
            return [local]
        }
        // Уже абсолютный URL.
        if raw.hasPrefix("http"), let absolute = URL(string: raw) {
            return [absolute]
        }
        // Убираем все ведущие слэши: "//manga/..." или "/manga/..." → "manga/...".
        var path = raw
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return [] }

        // Выбранный пользователем сервер (Первый/Второй/Сжатия) пробуем ПЕРВЫМ,
        // остальные — как резерв (если выбранный не отдал картинку). Так и
        // читалка (перебор кандидатов в RemoteImage), и скачивание
        // (DownloadsManager.fetchData) используют предпочитаемый сервер.
        let preferred = ImageServerChoice.current.baseURL
        var ordered = imageServers
        if let idx = ordered.firstIndex(of: preferred) {
            ordered.remove(at: idx)
        }
        ordered.insert(preferred, at: 0)

        return ordered.compactMap { URL(string: $0 + "/" + path) }
    }

    /// Основной URL страницы (первый сервер).
    static func pageURL(for page: PageItem, serverIndex: Int = 0) -> URL? {
        let urls = pageURLs(for: page)
        guard !urls.isEmpty else { return nil }
        return urls[min(max(serverIndex, 0), urls.count - 1)]
    }
}
