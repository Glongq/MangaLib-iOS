import Foundation

// MARK: - API Envelopes

/// Обёртка ответа API MangaLib для списков: `{ "data": [ ... ], "meta": { ... } }`.
struct APIListResponse<T: Decodable>: Decodable {
    let data: [T]
    let meta: APIMeta?
}

/// Обёртка ответа API MangaLib для одиночного объекта: `{ "data": { ... } }`.
struct APIObjectResponse<T: Decodable>: Decodable {
    let data: T
}

/// Ленивое декодирование массива — один "сломанный" элемент не роняет чтение
/// ВСЕГО массива. Обычный `[T]` в Decodable атомарен: если ХОТЬ ОДИН элемент
/// не смог декодироваться, весь массив целиком бросает ошибку. Это критично
/// для `GET /bookmarks` (см. MangaNetworkService.fetchBookmarksAccountList) —
/// на аккаунте с историей за 1.5-2 года почти гарантированно найдётся хотя бы
/// одна закладка на снятый с публикации/удалённый тайтл, у которого "media"
/// не той формы, что MangaItem ожидает — раньше это тихо валило ВЕСЬ синк
/// закладок (через try? в цикле), и serverId не проставлялся вообще ни для
/// одной закладки, отсюда и "удаление всё равно не работает".
struct LossyArray<T: Decodable>: Decodable {
    let elements: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [T] = []
        // container.decode(_:) продвигает курсор массива независимо от того,
        // успешно ли декодировался элемент, поэтому try? здесь просто
        // пропускает битый элемент, не зацикливаясь и не роняя остальные.
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                result.append(value)
            }
        }
        elements = result
    }
}

/// Как APIListResponse<T>, но "data" — LossyArray (см. выше). Используем там,
/// где отдельные элементы реально могут быть "битыми" (закладки старых/
/// удалённых тайтлов), в отличие от обычного каталога, где такого не бывает.
struct LossyListResponse<T: Decodable>: Decodable {
    let data: [T]
    let meta: APIMeta?

    private enum CodingKeys: String, CodingKey { case data, meta }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? c.decode(LossyArray<T>.self, forKey: .data))?.elements ?? []
        meta = try? c.decodeIfPresent(APIMeta.self, forKey: .meta)
    }
}

/// Профиль текущего пользователя — `GET /auth/me` (только с валидным токеном
/// сессии, см. AuthSession). `avatar.url` — уже готовый абсолютный URL картинки,
/// в отличие от относительных путей обложек/страниц, которые собираются через
/// MangaImageURL.
struct CurrentUser: Decodable {
    let id: Int
    let username: String
    let avatar: Avatar?

    struct Avatar: Decodable {
        let url: String?
    }
}

// MARK: - История чтения (реальный аккаунт)

/// Одна запись реальной истории просмотров аккаунта —
/// `GET /user/chapters/history?page=N`. Подтверждено перехватом реального
/// запроса сайта (см. чат) — `media` по форме совпадает с MangaItem, `item` —
/// отдельная, более простая форма главы (плоский branch_id, а не вложенный
/// массив branches, как в ChapterItem).
struct HistoryEntry: Decodable, Identifiable, Hashable {
    let viewAt: Date
    let media: MangaItem
    let item: HistoryChapterRef

    /// Составной id — своего id у записи истории нет, только у media/item.
    var id: String { "\(media.id)-\(item.id)" }

    enum CodingKeys: String, CodingKey {
        case viewAt = "view_at"
        case media, item
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MangaItem.self, forKey: .media)
        item = try c.decode(HistoryChapterRef.self, forKey: .item)
        // "2026-07-26T21:15:10.000000Z" — ISO8601 с микросекундами.
        // ISO8601DateFormatter с .withFractionalSeconds не всегда переваривает
        // 6 знаков дробной части одинаково на всех версиях iOS — на случай
        // расхождения есть резервный DateFormatter с явным форматом.
        let raw = try c.decode(String.self, forKey: .viewAt)
        viewAt = Self.parseDate(raw) ?? Date()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return f
    }()

    private static func parseDate(_ raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
    }
}

/// Глава внутри записи истории — своя, более простая форма (в отличие от
/// ChapterItem: тут branch_id — плоское поле, а не вложенный массив branches).
struct HistoryChapterRef: Decodable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let branchId: Int?
    let mangaId: Int?

    enum CodingKeys: String, CodingKey {
        case id, volume, number
        case branchId = "branch_id"
        case mangaId = "manga_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        volume = try Self.flexibleString(c, .volume) ?? "1"
        number = try Self.flexibleString(c, .number) ?? "0"
        branchId = try? c.decodeIfPresent(Int.self, forKey: .branchId)
        mangaId = try? c.decodeIfPresent(Int.self, forKey: .mangaId)
    }

    // Та же защита, что и в ChapterItem — volume/number иногда приходят числом.
    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        return nil
    }
}

/// Метаинформация пагинации.
struct APIMeta: Decodable {
    let page: Int?
    let hasNextPage: Bool?

    enum CodingKeys: String, CodingKey {
        case page
        case hasNextPage = "has_next_page"
    }
}

/// Страница каталога: элементы + признак наличия следующей страницы.
struct CatalogPage {
    let items: [MangaItem]
    let hasNextPage: Bool
}

// MARK: - Cover

/// Набор ссылок на обложку. Сервер возвращает разные размеры.
struct MangaCover: Decodable {
    let filename: String?
    let thumbnail: String?
    let `default`: String?
    let md: String?

    /// Наиболее подходящий URL обложки для отображения в карточке.
    var bestURL: URL? {
        for candidate in [md, `default`, thumbnail, filename] {
            if let string = candidate, let url = URL(string: string) {
                return url
            }
        }
        return nil
    }
}

/// Фоновая картинка тайтла (MangaDetail.background) — ПОДТВЕРЖДЕНО реальным
/// перехваченным JSON: форма ДРУГАЯ, чем у обложки — `{"filename":"...",
/// "url":"https://cover.cdnlibs.org/uploads/cover/{slug}/background/{filename}"}`,
/// без thumbnail/default/md, зато с готовым абсолютным "url". Раньше здесь
/// по ошибке использовалась MangaCover (форма обложки) — ключи не совпадали,
/// поэтому background всегда декодировался в nil и картинка не подгружалась,
/// даже когда реально была на сервере.
struct MangaBackgroundImage: Decodable {
    let filename: String?
    let url: String?

    var bestURL: URL? { url.flatMap(URL.init(string:)) }
}

// MARK: - Status & Rating

struct MangaStatus: Decodable {
    let id: Int?
    let label: String?
}

struct MangaRating: Decodable {
    let average: String?
    let averageFormated: String?
    let votes: Int?

    /// Числовое значение рейтинга (например, 8.5).
    var value: Double? {
        if let average, let d = Double(average) { return d }
        if let averageFormated, let d = Double(averageFormated) { return d }
        return nil
    }
}

// MARK: - Named entity (жанр, тег, автор)

/// Универсальная сущность со `id` и `name` (жанры, теги, авторы).
struct NamedEntity: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
}

/// Элемент "Формат" (MangaDetail.format) — подтверждено реальным перехваченным
/// JSON: `[{"id":6,"name":"Веб"}]`, т.е. ключ "name", как у жанров/тегов.
/// Оставляем и запасной ключ "label" на случай другого сайта/варианта ответа.
struct FlexibleLabelEntity: Decodable {
    let label: String?

    private enum CodingKeys: String, CodingKey { case name, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let byName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let byLabel = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        label = [byName, byLabel].compactMap { $0 }.first { !$0.isEmpty }
    }
}

// MARK: - MangaItem (элемент каталога/поиска)

struct MangaItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let rusName: String?
    let engName: String?
    let slug: String
    let slugURL: String?
    let cover: MangaCover?
    let rating: MangaRating?
    let status: MangaStatus?
    let type: MangaStatus?
    let ageRestriction: MangaStatus?

    /// Название для отображения: русское, если есть, иначе оригинальное.
    var displayTitle: String { rusName?.isEmpty == false ? rusName! : name }

    /// Идентификатор для запросов к API (slug_url приоритетнее, т.к. содержит числовой префикс).
    var apiSlug: String { slugURL?.isEmpty == false ? slugURL! : slug }

    /// URL обложки строкой (для сохранения в закладки).
    var coverURLString: String? { cover?.bestURL?.absoluteString }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, cover, rating, status, type
        case rusName = "rus_name"
        case engName = "eng_name"
        case slugURL = "slug_url"
        case ageRestriction = "ageRestriction"
    }

    static func == (lhs: MangaItem, rhs: MangaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - "Похожее" (GET /manga/{slug}/similar)

/// Один элемент раздела "Похожее" — ПОДТВЕРЖДЕНО реальным перехваченным
/// запросом (пользователь прислал полное тело): `GET /manga/{slug}/similar`
/// → `{"data":[{"id":Int,"similar":"Схож по жанрам и сюжету","user_id":Int,
/// "media":{...та же форма, что MangaItem: id/name/rus_name/eng_name/slug/
/// slug_url/cover/status/type/ageRestriction...},"votes":{"up":Int,"down":Int,
/// "user":Int?}}]}`. "media" по форме СОВПАДАЕТ с MangaItem (как и у
/// BookmarkListEntry/HistoryEntry) — переиспользуем его напрямую.
struct SimilarItem: Decodable, Identifiable, Hashable {
    let id: Int
    /// Текст-объяснение, ПОЧЕМУ похоже — "Схож по жанрам и сюжету", "Схож по
    /// рисовке" и т.п., свободный текст с сервера.
    let similar: String?
    let media: MangaItem
    var votes: SimilarVotes

    static func == (lhs: SimilarItem, rhs: SimilarItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Голоса за "похожесть" — ПОДТВЕРЖДЕНО перехватом `POST /similar/{id}/vote`:
/// `user` — именно `Int?`, НЕ Bool. Реальные ответы из перехвата: после
/// голоса "+" (тело запроса `{"vote":1}`) → `{"up":1095,"down":28,"user":1}`;
/// после голоса "-" (тело `{"vote":0}`) → `{"up":1094,"down":29,"user":0}`.
/// Т.е. user:1 = голосовал "+", user:0 = голосовал "-", user:null = не
/// голосовал вовсе. Поведение "снять голос полностью" (вернуть user:null)
/// НЕ подтверждено ни одним перехватом — переключение между "+"/"-"
/// поддержано, отдельная кнопка "отменить голос" не добавлена, чтобы не
/// гадать про неподтверждённое поведение.
struct SimilarVotes: Decodable, Hashable {
    let up: Int
    let down: Int
    let user: Int?
}

// MARK: - "Связанное" (GET /manga/{slug}/relations)

/// Один элемент раздела "Связанное" — ПОДТВЕРЖДЕНО реальным перехваченным
/// запросом (пользователь прислал полное тело): `GET /manga/{slug}/relations`
/// → `{"data":[{"order":Int,"related_type":{"id":Int,"label":"Источник"},
/// "media":{...та же форма, что MangaItem}}]}`. В отличие от "Похожего" (см.
/// SimilarItem) — БЕЗ голосов и без своего "id" у самого элемента связи
/// (только order + related_type + media), поэтому Identifiable — по
/// media.id (гарантированно уникален, в отличие от order, который может
/// повторяться).
struct RelatedItem: Decodable, Identifiable, Hashable {
    var id: Int { media.id }
    let order: Int
    /// "Источник", "Сиквел", "Спин-офф" и т.п. — тип связи с сервера.
    let relatedType: MangaStatus?
    let media: MangaItem

    enum CodingKeys: String, CodingKey {
        case order, media
        case relatedType = "related_type"
    }

    static func == (lhs: RelatedItem, rhs: RelatedItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Реальные "мои закладки" аккаунта (GET /bookmarks)

/// Один элемент настоящего эндпоинта "мои закладки" — `GET /bookmarks?page=&
/// sort_by=name&sort_type=desc&status=N&user_id=<id>` (подтверждено реальным
/// перехваченным запросом, см. чат/файл "Релализация ЗАКЛАДОК норм.txt").
/// В отличие от старого предположения ("отдельного эндпоинта нет, это /manga
/// с фильтром bookmarks[]="), это НАСТОЯЩИЙ эндпоинт закладок, и его "id"
/// верхнего уровня — это id САМОЙ ЗАПИСИ закладки, ровно тот, что нужен для
/// `DELETE /bookmarks/{id}` (см. MangaNetworkService.removeBookmark(id:)).
/// "media" по форме совпадает с MangaItem (id/name/rus_name/slug/slug_url/
/// cover/status/type/ageRestriction — все ключи есть и называются так же),
/// поэтому переиспользуем MangaItem напрямую вместо отдельной модели.
struct BookmarkListEntry: Decodable {
    let id: Int
    /// Числовой статус папки — совпадает с BookmarkFolder.apiId
    /// (1=Читаю, 2=В планах, 3=Брошено, 4=Прочитано, 5=Любимые).
    let status: Int?
    let media: MangaItem
}

/// Ответ настоящего эндпоинта создания папки закладок — `POST /bookmarks/folder`
/// (подтверждено перехватом: тело `{"name":"она"}` → 201 Created, `{"data":
/// {"id":2717854,"name":"она","public":false,"notify":false,"color":"#b051ff",
/// "textColor":"#fff","order":5,"count":0,"site_ids":[1]}}`). Нам нужен только
/// числовой id — сохраняется как BookmarkFolder.serverId (см. BookmarksStore) —
/// остальные поля сервер присваивает сам, локально нам их дублировать незачем.
struct ServerBookmarkFolder: Decodable {
    let id: Int
    let name: String
}

// MARK: - Summary rich-text (ProseMirror/TipTap)

/// Описание тайтла (MangaDetail.summary) приходит НЕ обычной строкой, а
/// деревом rich-текста в формате ProseMirror/TipTap — подтверждено реальным
/// перехваченным JSON: `{"type":"doc","content":[{"type":"paragraph",
/// "content":[{"type":"text","text":"..."}]}]}`. SummaryDoc/SummaryNode
/// рекурсивно собирают из этого дерева чистый текст для отображения в UI.
struct SummaryDoc: Decodable {
    let content: [SummaryNode]?

    var plainText: String {
        (content ?? [])
            .map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

struct SummaryNode: Decodable {
    let text: String?
    let content: [SummaryNode]?

    var plainText: String {
        if let text, !text.isEmpty { return text }
        return (content ?? []).map(\.plainText).joined()
    }
}

/// Полностью универсальное JSON-значение — на случай, если реальная форма
/// "summary" всё-таки хоть немного отличается от SummaryDoc/SummaryNode
/// (другие имена узлов, лишняя обёртка и т.п.). Раз три попытки угадать
/// точную структуру не помогли — этот разбор вообще не завязан на структуру:
/// он декодирует ЛЮБОЙ JSON и сам ищет по нему читаемый текст.
enum AnyJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        self = .null
    }

    /// Сначала ищет строки под ключом "text" (конвенция ProseMirror/TipTap,
    /// сохраняет порядок, т.к. массивы всегда упорядочены). Если таких нет
    /// вообще — берёт любые строковые "листья" дерева длиннее нескольких
    /// символов (пропуская короткие однословные технические значения вроде
    /// "doc"/"paragraph"), чтобы не потерять текст даже при незнакомой форме.
    func extractReadableText() -> String {
        var textNodes: [String] = []
        collect(key: nil, into: &textNodes, targetKey: "text")
        if !textNodes.isEmpty {
            return textNodes.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        var anyStrings: [String] = []
        collectAnyStrings(into: &anyStrings)
        return anyStrings.joined(separator: "\n\n")
    }

    private func collect(key: String?, into result: inout [String], targetKey: String) {
        switch self {
        case .string(let s):
            if key == targetKey, !s.isEmpty { result.append(s) }
        case .object(let dict):
            for (k, v) in dict { v.collect(key: k, into: &result, targetKey: targetKey) }
        case .array(let arr):
            for v in arr { v.collect(key: key, into: &result, targetKey: targetKey) }
        default:
            break
        }
    }

    private func collectAnyStrings(into result: inout [String]) {
        switch self {
        case .string(let s):
            // Пропускаем короткие однословные значения без пробелов — это,
            // скорее всего, служебные теги вроде "type": "paragraph", а не
            // читаемый текст описания.
            if s.count > 3, s.contains(" ") || s.count > 20 {
                result.append(s)
            }
        case .object(let dict):
            for (_, v) in dict { v.collectAnyStrings(into: &result) }
        case .array(let arr):
            for v in arr { v.collectAnyStrings(into: &result) }
        default:
            break
        }
    }
}

// MARK: - MangaDetail (детальная карточка)

struct MangaDetail: Decodable, Identifiable {
    let id: Int
    let name: String
    let rusName: String?
    let engName: String?
    let slug: String
    let slugURL: String?
    let cover: MangaCover?
    /// Отдельная фоновая картинка тайтла (шире/выше обложки, для шапки
    /// экрана) — ПОДТВЕРЖДЕНО реальным перехваченным JSON (запрос с
    /// `fields[]=background`): `{"background":{"filename":"...","url":"https://
    /// cover.cdnlibs.org/uploads/cover/{slug}/background/{filename}"}}` — форма
    /// ДРУГАЯ, чем у обложки (см. MangaBackgroundImage), поэтому раньше (когда
    /// декодировалось как MangaCover) поле всегда получалось nil. Также
    /// подтверждено, что "background" нужно явно запрашивать через
    /// fields[]=background (см. fetchMangaDetail) — без этого сервер его не
    /// присылает вообще, как summary/genres/tags и т.п.
    let background: MangaBackgroundImage?
    let rating: MangaRating?
    let status: MangaStatus?
    let type: MangaStatus?
    /// Возрастной рейтинг («18+»/«16+»/«12+»/«6+»/«Нет») — та же форма
    /// (id+label), что и у MangaItem.ageRestriction (см. там), декодируется
    /// точно так же, без fields[] (это, судя по каталогу, поле по умолчанию,
    /// а не одно из "опциональных" типа summary/genres/tags/format/views/
    /// background, которые сервер отдаёт ТОЛЬКО по явному запросу). См.
    /// MangaDetailView.ageRatingChip — 18+/16+ показываются цветным чипом
    /// первыми в списке жанров/тегов, 12+/6+/"Нет" не показываются вовсе.
    let ageRestriction: MangaStatus?
    let summary: String?
    let genres: [NamedEntity]?
    let tags: [NamedEntity]?
    let authors: [NamedEntity]?
    let releaseDate: String?
    let views: Int?
    let format: [FlexibleLabelEntity]?
    /// Тайтл официально лицензирован (главы в связи с этим скрыты/удалены с
    /// сайта) — ПОДТВЕРЖДЕНО реальным перехваченным JSON (см. файл "проверка
    /// на лицензирование.txt"): `"is_licensed": true` у тайтла с
    /// `"items_count":{"uploaded":15,"total":0}` (главы загружены, но не
    /// видны). Поле по умолчанию, БЕЗ fields[] (как и ageRestriction/status/
    /// type/cover) — в перехваченном запросе его нет в списке fields[], но
    /// оно всё равно пришло в ответе.
    let isLicensed: Bool
    /// Статус модерации — ПОДТВЕРЖДЕНО тем же перехватом: `"moderated":
    /// {"id":1,"label":"Принято модерацией"}`, требует ЯВНОГО fields[]=moderated
    /// (есть в списке query у перехваченного запроса, см. fetchMangaDetail).
    /// См. MangaDetailView.isBlockedByLicenseOrModeration — вместе с
    /// isLicensed определяет, показывать ли вместо описания текст про
    /// удаление глав правообладателем/РКН.
    let moderated: MangaStatus?

    var displayTitle: String { rusName?.isEmpty == false ? rusName! : name }
    var apiSlug: String { slugURL?.isEmpty == false ? slugURL! : slug }

    /// Год выпуска в формате «2009г.».
    var yearString: String? {
        guard let releaseDate, !releaseDate.isEmpty else { return nil }
        let year = String(releaseDate.prefix(4))
        return year.count == 4 ? "\(year)г." : nil
    }

    /// Просмотры в формате «7.1тыс.» / «1.2млн».
    var viewsString: String? {
        guard let v = views, v > 0 else { return nil }
        switch v {
        case 1_000_000...:
            return String(format: "%.1fмлн", Double(v) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fтыс.", Double(v) / 1_000)
        default:
            return "\(v)"
        }
    }

    var formatLabels: [String] { (format ?? []).compactMap(\.label).filter { !$0.isEmpty } }

    /// true — есть подтверждённые маркеры, что глав нет НЕ потому что их
    /// просто ещё не залили, а потому что тайтл лицензирован (главы скрыты)
    /// или сейчас на проверке модерации. isLicensed — прямой, подтверждённый
    /// перехватом флаг. moderated.label — доп. эвристика (ключевое слово
    /// "проверк*"): у самого подтверждённого примера моdered.label был
    /// "Принято модерацией" (уже одобрено, не блокирует само по себе) — но
    /// для тайтлов, реально ЕЩЁ на проверке, метка, по всей видимости,
    /// другая ("На проверке"/"На модерации" и т.п.), поэтому проверяем ключевое
    /// слово, а не только isLicensed.
    var isBlockedByLicenseOrModeration: Bool {
        isLicensed || (moderated?.label?.localizedCaseInsensitiveContains("проверк") ?? false)
    }

    /// URL фоновой картинки для шапки экрана тайтла — своя (если реально
    /// пришла с сервера), иначе обложка (см. комментарий у background выше;
    /// именно это "если не удаётся — ставь обложку" и попросили).
    var backgroundURL: URL? { background?.bestURL ?? cover?.bestURL }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, cover, background, rating, status, type, summary, genres, tags, authors, views, format, moderated
        case ageRestriction = "ageRestriction"
        case isLicensed = "is_licensed"
        case rusName = "rus_name"
        case engName = "eng_name"
        case slugURL = "slug_url"
        case releaseDate = "releaseDate"
        case releaseDateString = "releaseDateString"
        case releaseDateSnake = "release_date"
        case viewsCount = "views_count"
        case description
    }

    // Защитный декодер: неизвестная форма второстепенных полей (год/просмотры/формат
    // отличаются от сайта к сайту) не должна ронять весь разбор карточки.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rusName = try? c.decodeIfPresent(String.self, forKey: .rusName) ?? nil
        engName = try? c.decodeIfPresent(String.self, forKey: .engName) ?? nil
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        slugURL = try? c.decodeIfPresent(String.self, forKey: .slugURL) ?? nil
        cover = try? c.decodeIfPresent(MangaCover.self, forKey: .cover) ?? nil
        background = try? c.decodeIfPresent(MangaBackgroundImage.self, forKey: .background) ?? nil
        rating = try? c.decodeIfPresent(MangaRating.self, forKey: .rating) ?? nil
        status = try? c.decodeIfPresent(MangaStatus.self, forKey: .status) ?? nil
        type = try? c.decodeIfPresent(MangaStatus.self, forKey: .type) ?? nil
        ageRestriction = try? c.decodeIfPresent(MangaStatus.self, forKey: .ageRestriction) ?? nil
        isLicensed = (try? c.decodeIfPresent(Bool.self, forKey: .isLicensed)) ?? false
        moderated = try? c.decodeIfPresent(MangaStatus.self, forKey: .moderated) ?? nil
        // "summary"/"description" — оба ключа пробуем, ПЛЮС на случай, если
        // описание приходит не голой строкой, а вложенным объектом (напр.
        // {"ru": "...", "text": "..."}) — тоже не подтверждено перехватом,
        // поэтому декодируем максимально гибко через decodeFlexibleText.
        let summaryValue = Self.decodeFlexibleText(c, .summary)
        let descriptionValue = Self.decodeFlexibleText(c, .description)
        summary = [summaryValue, descriptionValue].compactMap { $0 }.first { !$0.isEmpty }
        genres = try? c.decodeIfPresent([NamedEntity].self, forKey: .genres) ?? nil
        tags = try? c.decodeIfPresent([NamedEntity].self, forKey: .tags) ?? nil
        authors = try? c.decodeIfPresent([NamedEntity].self, forKey: .authors) ?? nil
        // Подтверждено реальным JSON: [{"id":6,"name":"Веб"}] — ключ "name",
        // как у жанров/тегов. FlexibleLabelEntity также пробует "label"
        // запасным вариантом.
        format = try? c.decodeIfPresent([FlexibleLabelEntity].self, forKey: .format) ?? nil

        // Год: releaseDate (строка/число), releaseDateString, либо
        // snake_case release_date — реальный ключ не подтверждён перехватом,
        // пробуем все варианты по очереди.
        if let s = try? c.decodeIfPresent(String.self, forKey: .releaseDate), !s.isEmpty {
            releaseDate = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .releaseDate) {
            releaseDate = String(i)
        } else if let s2 = try? c.decodeIfPresent(String.self, forKey: .releaseDateString), !s2.isEmpty {
            releaseDate = s2
        } else if let s3 = try? c.decodeIfPresent(String.self, forKey: .releaseDateSnake), !s3.isEmpty {
            releaseDate = s3
        } else if let i3 = try? c.decodeIfPresent(Int.self, forKey: .releaseDateSnake) {
            releaseDate = String(i3)
        } else {
            releaseDate = nil
        }

        // views — ПОДТВЕРЖДЕНО реальным JSON: объект `{"total":44819,
        // "short":"44.8 K","formated":"44 819"}`, а не голое число. Берём
        // "total" и форматируем сами по-русски (см. viewsString) — короткая
        // строка от сервера в английском стиле ("K"/"M") нам не подходит.
        // Старые варианты (число/строка/views_count) оставлены как запасные
        // на случай другого сайта.
        struct ViewsObject: Decodable { let total: Int? }
        if let obj = (try? c.decodeIfPresent(ViewsObject.self, forKey: .views)).flatMap({ $0 }), let t = obj.total {
            views = t
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .views) {
            views = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .views), let i = Int(s) {
            views = i
        } else if let i2 = try? c.decodeIfPresent(Int.self, forKey: .viewsCount) {
            views = i2
        } else if let s2 = try? c.decodeIfPresent(String.self, forKey: .viewsCount), let i2 = Int(s2) {
            views = i2
        } else {
            views = nil
        }
    }

    /// Гибкое декодирование текстового поля (описания): пробуем по очереди —
    /// 1) обычную строку; 2) ПОДТВЕРЖДЁННОЕ реальным JSON дерево ProseMirror/
    /// TipTap (см. SummaryDoc) — именно так реально приходит "summary";
    /// 3) произвольный вложенный объект с типичными под-ключами (ru/text/
    /// value/en/description) — запасной вариант на случай другого сайта.
    private static func decodeFlexibleText(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let plain = (try? c.decodeIfPresent(String.self, forKey: key)).flatMap({ $0 }), !plain.isEmpty {
            return plain
        }
        if let doc = (try? c.decodeIfPresent(SummaryDoc.self, forKey: key)).flatMap({ $0 }) {
            let text = doc.plainText
            if !text.isEmpty { return text }
        }
        struct NestedText: Decodable {
            let ru: String?
            let en: String?
            let text: String?
            let value: String?
            let description: String?
        }
        if let nested = (try? c.decodeIfPresent(NestedText.self, forKey: key)).flatMap({ $0 }) {
            if let found = [nested.ru, nested.text, nested.value, nested.en, nested.description]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty }) {
                return found
            }
        }
        // Последний рубеж: если ни одна из угаданных структур не подошла —
        // разбираем ЛЮБОЙ JSON под этим ключом и сами ищем в нём читаемый
        // текст (см. AnyJSON.extractReadableText). Это должно сработать,
        // даже если реальная форма чуть отличается от того, что мы уже
        // пробовали (другие имена узлов, лишняя обёртка и т.п.).
        if let generic = (try? c.decodeIfPresent(AnyJSON.self, forKey: key)).flatMap({ $0 }) {
            let text = generic.extractReadableText()
            if !text.isEmpty { return text }
        }
        return nil
    }
}

// MARK: - Chapter

/// Ветка перевода (сканлейт-команда) внутри главы.
struct ChapterBranch: Decodable, Identifiable, Hashable {
    let id: Int?
    let branchId: Int?
    let teams: [NamedEntity]?

    /// Стабильный идентификатор для SwiftUI (id может быть nil).
    var identity: Int { id ?? branchId ?? 0 }
    var idValue: Int { identity }

    enum CodingKeys: String, CodingKey {
        case id, teams
        case branchId = "branch_id"
    }

    static func == (lhs: ChapterBranch, rhs: ChapterBranch) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

struct ChapterItem: Decodable, Identifiable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let name: String?
    let branches: [ChapterBranch]?
    let createdAt: String?

    /// Заголовок главы для списка: «Том X, Глава Y — Название».
    var displayTitle: String {
        var parts = ["Том \(volume)", "Глава \(number)"]
        if let name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// Короткий заголовок «Том X Глава Y».
    var shortTitle: String { "Том \(volume) Глава \(number)" }

    /// Название главы (или короткий заголовок, если пусто).
    var titleOrShort: String { (name?.isEmpty == false) ? name! : shortTitle }

    /// Дата в формате «дд.мм.гггг» из created_at (ISO).
    var dateString: String? {
        guard let createdAt, createdAt.count >= 10 else { return nil }
        let d = String(createdAt.prefix(10))         // 2017-12-14
        let parts = d.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[2]).\(parts[1]).\(parts[0])"  // 14.12.2017
    }

    /// Первый доступный branch_id (нужен для запроса страниц, если веток несколько).
    var primaryBranchId: Int? { branches?.first?.branchId }

    enum CodingKeys: String, CodingKey {
        case id, volume, number, name, branches
        case createdAt = "created_at"
    }

    static func == (lhs: ChapterItem, rhs: ChapterItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Значения volume/number приходят то строкой, то числом — нормализуем к String.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        volume = try Self.flexibleString(c, .volume) ?? "1"
        number = try Self.flexibleString(c, .number) ?? "0"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        branches = try c.decodeIfPresent([ChapterBranch].self, forKey: .branches)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt) ?? nil
    }

    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        return nil
    }
}

// MARK: - Chapter pages

/// Ответ эндпоинта главы: содержит страницы. Иногда сервер отдаёт список серверов картинок.
struct ChapterPagesResponse: Decodable {
    let data: ChapterPagesData
}

struct ChapterPagesData: Decodable {
    let id: Int?
    let pages: [PageItem]
    /// Не подтверждено перехватом реального запроса — предположительное поле
    /// из общего описания API. Optional и по умолчанию false — если сервер
    /// его не пришлёт, ничего не сломается (просто отметка "уже просмотрено"
    /// не сработает как быстрая проверка, и приложение всё равно отправит
    /// markChapterViewed как раньше).
    let isViewed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pages
        case isViewed = "is_viewed"
    }
}

// MARK: - Комментарии (ПОДТВЕРЖДЕНО реальным перехватом)

extension Date {
    /// Относительное время по-русски, ОДНОЙ единицей — "5 дней назад",
    /// "7 часов назад", "2 месяца назад" и т.д., с правильным русским
    /// склонением (1 день/2 дня/5 дней). Раньше использовался системный
    /// Text(date, style: .relative) — он показывал время либо по-английски,
    /// либо КОМБИНИРОВАННО ("3 дня 17 часов назад"), что явно попросили
    /// убрать: нужна только ОДНА, самая крупная подходящая единица.
    var relativeRussianString: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        let minute = 60.0, hour = 3600.0, day = 86400.0, month = 2_592_000.0, year = 31_536_000.0

        func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
            let mod100 = n % 100
            if (11...14).contains(mod100) { return many }
            switch n % 10 {
            case 1: return one
            case 2...4: return few
            default: return many
            }
        }

        switch seconds {
        case ..<minute:
            return "только что"
        case ..<hour:
            let n = Int(seconds / minute)
            return "\(n) \(plural(n, "минуту", "минуты", "минут")) назад"
        case ..<day:
            let n = Int(seconds / hour)
            return "\(n) \(plural(n, "час", "часа", "часов")) назад"
        case ..<month:
            let n = Int(seconds / day)
            return "\(n) \(plural(n, "день", "дня", "дней")) назад"
        case ..<year:
            let n = Int(seconds / month)
            return "\(n) \(plural(n, "месяц", "месяца", "месяцев")) назад"
        default:
            let n = Int(seconds / year)
            return "\(n) \(plural(n, "год", "года", "лет")) назад"
        }
    }
}

/// Комментарий — форма ПОДТВЕРЖДЕНА реальными перехваченными запросами:
/// GET и POST /comments возвращают ОДНУ и ту же плоскую форму объекта,
/// вложенность ответов кодируется через commentLevel/parentComment/rootId, а
/// НЕ вложенным JSON. GET-ответ отдаёт корневые комментарии и ответы ДВУМЯ
/// РАЗНЫМИ массивами — "root" и "replies" (см. CommentsListResponse,
/// подтверждено перехватом из devtools сайта) — дерево строится на клиенте
/// из их объединения, см. Array<Comment>.groupedByParent().
struct Comment: Decodable, Identifiable, Hashable {
    let id: Int
    let rootId: Int?
    let parentComment: Int?
    let commentLevel: Int
    /// Сырой HTML с сервера (напр. "<p>текст</p>") — см. text ниже.
    let commentHTML: String
    /// Миллисекунды с эпохи — подтверждено (13-значное число: 1785142817000).
    let createdAtTS: Double?
    let author: Author?
    let votesUp: Int
    let votesDown: Int

    struct Author: Decodable, Hashable {
        let id: Int
        let username: String
        let avatarURL: String?

        private enum CodingKeys: String, CodingKey { case id, username, avatar }
        private enum AvatarKeys: String, CodingKey { case url }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(Int.self, forKey: .id)) ?? 0
            username = (try? c.decode(String.self, forKey: .username)) ?? "Аноним"
            if let avatarC = try? c.nestedContainer(keyedBy: AvatarKeys.self, forKey: .avatar) {
                avatarURL = try? avatarC.decodeIfPresent(String.self, forKey: .url)
            } else {
                avatarURL = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, user, votes
        case rootId = "root_id"
        case parentComment = "parent_comment"
        case commentLevel = "comment_level"
        case commentHTML = "comment"
        case createdAtTS = "created_at_ts"
    }
    private enum VotesKeys: String, CodingKey { case up, down }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        rootId = try? c.decodeIfPresent(Int.self, forKey: .rootId) ?? nil
        parentComment = try? c.decodeIfPresent(Int.self, forKey: .parentComment) ?? nil
        commentLevel = (try? c.decodeIfPresent(Int.self, forKey: .commentLevel)) ?? 0
        commentHTML = (try? c.decodeIfPresent(String.self, forKey: .commentHTML)) ?? ""
        createdAtTS = try? c.decodeIfPresent(Double.self, forKey: .createdAtTS) ?? nil
        author = try? c.decodeIfPresent(Author.self, forKey: .user) ?? nil
        if let votesC = try? c.nestedContainer(keyedBy: VotesKeys.self, forKey: .votes) {
            votesUp = (try? votesC.decodeIfPresent(Int.self, forKey: .up)) ?? 0
            votesDown = (try? votesC.decodeIfPresent(Int.self, forKey: .down)) ?? 0
        } else {
            votesUp = 0
            votesDown = 0
        }
    }

    /// Плюсики минус минусики — цвет в UI зависит от знака (см.
    /// MangaDetailView.commentScoreColor): >0 зелёный, <0 красный, 0 нейтральный.
    var score: Int { votesUp - votesDown }

    var date: Date? {
        guard let createdAtTS else { return nil }
        return Date(timeIntervalSince1970: createdAtTS / 1000)
    }

    /// HTML → читаемый плоский текст: сервер оборачивает комментарий в
    /// <p>...</p> (возможно, с <br> внутри для переносов) — простой безопасный
    /// стрип тегов, без NSAttributedString (полноценный rich-text не нужен).
    var text: String {
        var s = commentHTML
        for (tag, replacement) in [("</p><p>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("<br>", "\n")] {
            s = s.replacingOccurrences(of: tag, with: replacement)
        }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array where Element == Comment {
    /// Группирует плоский список по id родителя (0 — корневые, без родителя)
    /// — нужно для построения дерева ответов на клиенте (сервер отдаёт всё
    /// одним плоским списком, см. Comment). Внутри каждой группы — по
    /// возрастанию даты создания (старые сначала внутри одного треда, как в
    /// подтверждённом примере).
    ///
    /// НАЙДЕНО реальным перехватом (проверка пользователя): GET /comments с
    /// sort_by=id&sort_type=desc отдаёт страницу как плоский список БЕЗ
    /// гарантии, что родитель ответа попал на ту же страницу — например,
    /// пришёл comment_level:1 с parent_comment:303252695, а самого
    /// комментария 303252695 в этой же странице могло не быть (он старше и
    /// уехал на следующую страницу). Раньше группировка строго по
    /// c.parentComment ?? 0 такие "осиротевшие" ответы клала в bucket
    /// (несуществующего локально) родителя — они физически лежали в massив
    /// comments, но узел дерева для них никогда не строился (grouped[0]
    /// оставался пустым, если на странице вообще не было ни одного
    /// НАСТОЯЩЕГО корневого комментария) — отсюда баг "комментарии есть в
    /// ответе сервера, а в интерфейсе пусто". Фикс: родителем считается
    /// parentComment, ТОЛЬКО ЕСЛИ он реально присутствует среди уже
    /// загруженных комментариев — иначе комментарий считается "псевдокорнем"
    /// (bucket 0) и всё равно показывается, а не пропадает молча.
    func groupedByParent() -> [Int: [Comment]] {
        let loadedIDs = Set(map { $0.id })
        var map: [Int: [Comment]] = [:]
        for c in self {
            let effectiveParent: Int
            if let parent = c.parentComment, loadedIDs.contains(parent) {
                effectiveParent = parent
            } else {
                effectiveParent = 0
            }
            map[effectiveParent, default: []].append(c)
        }
        // Только ВЛОЖЕННЫЕ ответы (bucket != 0) сортируем по возрастанию даты —
        // так тред читается как обычная переписка сверху вниз, от старого
        // ответа к новому. КОРНЕВЫЕ комментарии (bucket 0) НЕ трогаем —
        // оставляем в ТОМ ЖЕ порядке, в котором они пришли в исходном
        // массиве, то есть в порядке, который уже выставил СЕРВЕР по
        // sort_type (Новые/Старые, см. MangaDetailViewModel.sortTypeParam);
        // "Популярные" пересортировывает поверх этого сам View (см.
        // MangaDetailView.commentsList).
        //
        // РЕАЛЬНЫЙ БАГ (нашёл пользователь: "внизу списка комментарии
        // новее, чем вверху"): раньше строгая ascending-сортировка
        // применялась ко ВСЕМ бакетам без исключения, включая корневой —
        // сервер честно присылал корневые комментарии по убыванию даты
        // (выбрана сортировка "Новые"), а этот код тут же переворачивал их
        // обратно на возрастание, из-за чего в интерфейсе сверху оказывались
        // САМЫЕ СТАРЫЕ корневые комментарии, а новые — только при прокрутке
        // вниз.
        for key in map.keys where key != 0 {
            map[key]?.sort { ($0.createdAtTS ?? 0) < ($1.createdAtTS ?? 0) }
        }
        return map
    }
}

/// Обёртка ответа GET /comments — РЕАЛЬНАЯ форма (перехвачена пользователем
/// через devtools сайта, а не через приложение — видна структура целиком, без
/// обрезки, в отличие от самого первого перехвата "comments.txt"):
/// `{"data":{"replies":[...], "root":[...]}, "meta":{"has_next_page":bool,
/// "page":Int,"per_page":Int}}`.
///
/// ЭТО ОПРОВЕРГАЕТ мою прежнюю, неподтверждённую гипотезу: "replies" — это
/// НЕ единый плоский список ВСЕХ комментариев (корневых и вложенных вместе),
/// а массив ТОЛЬКО вложенных ответов (comment_level >= 1); корневые
/// комментарии (comment_level: 0) лежат ОТДЕЛЬНО, в массиве "root". Раньше
/// код читал только "replies" — то есть настоящие корневые комментарии
/// ВООБЩЕ никогда не попадали в приложение, а на экране показывались только
/// "осиротевшие" вложенные ответы, притворяющиеся корнями (см.
/// Array.groupedByParent) — отсюда и баг "сортировка ничего не меняет":
/// смена sort_type меняла порядок на сервере, но клиент эти данные попросту
/// не получал, т.к. смотрел не в тот массив.
///
/// Заодно теперь используем НАСТОЯЩИЙ meta.has_next_page вместо прежней
/// эвристики "непустой список = наверное есть страница дальше" (см.
/// MangaNetworkService.fetchComments).
///
/// ВАЖНО: в отличие от большинства других decode-обёрток в этом файле, здесь
/// СТРУКТУРНЫЕ ошибки (нет ключа "data"/"replies"/"root", другая форма) НЕ
/// проглатываются через try? — пусть бросают настоящую ошибку, которая дойдёт
/// до commentsErrorState на экране, а не тихо превратятся в "0 комментариев".
/// LossyArray по-прежнему используется ВНУТРИ каждого массива — один "битый"
/// ОТДЕЛЬНЫЙ комментарий не должен ронять чтение всего списка, это другой случай.
struct CommentsListResponse: Decodable {
    /// Объединённые root + replies — дальше дерево строится одинаково для
    /// обоих через Array.groupedByParent (root уже имеет parentComment==nil,
    /// так что естественно попадает в bucket 0, без всякого спец-кода).
    let comments: [Comment]
    let hasNextPage: Bool

    private enum DataKeys: String, CodingKey { case data, meta }
    private enum RepliesKeys: String, CodingKey { case replies, root }
    private enum MetaKeys: String, CodingKey { case hasNextPage = "has_next_page" }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: DataKeys.self)
        let inner = try outer.nestedContainer(keyedBy: RepliesKeys.self, forKey: .data)
        let replies = try inner.decode(LossyArray<Comment>.self, forKey: .replies).elements
        let root = try inner.decode(LossyArray<Comment>.self, forKey: .root).elements
        comments = root + replies

        if let meta = try? outer.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta),
           let confirmed = try? meta.decode(Bool.self, forKey: .hasNextPage) {
            hasNextPage = confirmed
        } else {
            // Запасной вариант, если meta вдруг не пришла (не должно
            // случаться — подтверждено реальным перехватом) — как и раньше,
            // эвристика "непустой список = вероятно есть ещё".
            hasNextPage = !comments.isEmpty
        }
    }
}

/// Результат fetchPages — страницы + признак "уже просмотрена" (см.
/// ChapterPagesData.isViewed), используется для пропуска повторного
/// markChapterViewed при перечитывании уже отмеченной главы.
struct ChapterPagesResult {
    let pages: [PageItem]
    let isViewed: Bool
}

/// Одна страница главы. `url` — относительный путь, дополняется базовым URL сервера картинок.
struct PageItem: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: Int?
    let image: String?
    let url: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, slug, image, url, width, height
    }

    /// Относительный путь к изображению страницы.
    var relativePath: String? { url ?? image }

    static func == (lhs: PageItem, rhs: PageItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Уведомления (GET /notifications, GET /notifications/count)

/// Общий разбор дат вида "2026-07-26T13:19:36.000000Z" (ISO8601 с
/// микросекундами) — та же пара форматтеров, что уже используется в
/// HistoryEntry.parseDate, вынесена сюда, чтобы не дублировать её ещё раз
/// для NotificationItem.createdAt (см. ниже).
enum APIISODate {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
    }
}

/// `read_type` для GET /notifications. "unread"/"all" — ПОДТВЕРЖДЕНО реальными
/// перехватами (оба значения реально встречались в URL перехваченных
/// запросов сайта). "read" добавлен по симметрии с ними же (сервер сам
/// использует пару unread/all, "read" — третий, ещё не перехваченный, но
/// логичный вариант того же параметра) — если сервер его не примет, будет
/// видно в NetworkLogsView.
enum NotificationReadFilter: String, CaseIterable, Identifiable {
    case unread, read, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unread: return "Непрочитанные"
        case .read: return "Прочитанные"
        case .all: return "Все"
        }
    }
}

/// `sort_type` для GET /notifications — ПОДТВЕРЖДЕНО перехватом (значение
/// "desc" реально встречалось в URL; "asc" — по той же паре, что и у
/// /comments sort_type, см. MangaNetworkService.fetchComments).
enum NotificationSortOrder: String, CaseIterable, Identifiable {
    case desc, asc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desc: return "Сначала новые"
        case .asc: return "Сначала старые"
        }
    }
}

/// Автор события уведомления — форма ПОДТВЕРЖДЕНА реальным перехватом:
/// `"user":{"id","username","avatar":{"filename","url"}}` внутри
/// NotificationItem.data.
struct NotificationUser: Decodable, Hashable {
    let id: Int
    let username: String
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey { case id, username, avatar }
    private enum AvatarKeys: String, CodingKey { case url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? nil ?? ""
        if let avatarC = try? c.nestedContainer(keyedBy: AvatarKeys.self, forKey: .avatar) {
            let urlString = (try? avatarC.decodeIfPresent(String.self, forKey: .url)) ?? nil
            avatarURL = urlString.flatMap(URL.init(string:))
        } else {
            avatarURL = nil
        }
    }
}

/// Глава внутри уведомления — СВОЯ форма, отличная от ChapterItem/
/// HistoryChapterRef: та же пара volume/number-строк, но с человекочитаемым
/// "name" главы и без branches — ПОДТВЕРЖДЕНО реальным перехватом
/// (`"chapter":{"id","model","volume","number","name","branch_id","manga_id",
/// "expired_at"}`).
struct NotificationChapter: Decodable, Hashable {
    let id: Int?
    let volume: String?
    let number: String?
    let name: String?
}

/// Команда перевода — ПОДТВЕРЖДЕНО реальным перехватом: `"teams":[{"id",
/// "slug","slug_url","model":"team","name","cover":{...},"vk","discord"}]`
/// внутри NotificationItem.data. Массив, а не одиночный объект — у главы
/// может быть НЕСКОЛЬКО команд перевода сразу (подтверждено: во втором
/// перехваченном примере у одной главы две команды — "ImageBoard Team" и
/// "ONIMAI.RU"). Нужны только id/name — остальные поля (cover/vk/discord)
/// пока нигде не отображаются, не декодируем лишнее.
struct NotificationTeam: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String

    private enum CodingKeys: String, CodingKey { case id, name }
}

/// Содержимое уведомления — ProseMirror/TipTap доc, но ОТДЕЛЬНЫЙ парсер от
/// SummaryDoc/SummaryNode (см. выше): реальная форма здесь ПЛОСКАЯ —
/// "content" сразу перечисляет узлы text/hardBreak ОДНИМ уровнем, БЕЗ
/// обёртки в paragraph, как у MangaDetail.summary — подтверждено ВСЕМИ
/// тремя перехваченными файлами уведомлений одинаково. hardBreak → перевод
/// строки; marks (bold/underline на отдельных text-узлах) пока не
/// используются для форматирования — извлекаем только читаемый текст, чтобы
/// не гадать про точный AttributedString рендеринг.
struct NotificationContentDoc: Decodable {
    let content: [NotificationContentNode]?

    var plainText: String {
        (content ?? []).map(\.rendered).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NotificationContentNode: Decodable {
    let type: String?
    let text: String?

    var rendered: String {
        if type == "hardBreak" { return "\n" }
        return text ?? ""
    }
}

/// Один элемент ленты уведомлений — ПОДТВЕРЖДЕНО реальным перехватом (три
/// разных devtools-файла от пользователя, все примеры — category:"chapter"):
/// `{"id","type","category","data":{"user","chapter","media","teams",
/// "is_new"},"yaoi","content":{ProseMirror-доc},"created_at"}`.
///
/// ВАЖНО: статус "прочитано/не прочитано" У САМОГО ЭЛЕМЕНТА НЕ приходит —
/// ни в одном из трёх перехватов нет поля вроде is_read/read_at, форма ответа
/// ОДИНАКОВАЯ при read_type=unread и read_type=all. Значит фильтрация по
/// прочитанности — ПОЛНОСТЬЮ серверная, через read_type в запросе (см.
/// NotificationReadFilter/MangaNetworkService.fetchNotifications) — отдельного
/// булева поля на клиенте нет и быть не может, поэтому у самого элемента
/// нет и не может быть кнопки "отметить прочитанным": такой эндпоинт ни разу
/// не засветился ни в одном перехвате, гадать про него не стали.
///
/// "media"/"chapter" — Optional: категории, отличные от "chapter" (comments/
/// message/card/other — видны только в /notifications/count, но НИ РАЗУ не
/// перехвачены как реальные элементы списка), скорее всего, имеют другую
/// вложенную форму "data" — чтобы один такой "иной" элемент не ронял всю
/// LossyArray-загрузку списка, все поля здесь читаются best-effort (try?).
struct NotificationItem: Decodable, Identifiable, Hashable {
    let id: Int
    let type: String
    let category: String
    let user: NotificationUser?
    let media: MangaItem?
    let chapter: NotificationChapter?
    let teams: [NotificationTeam]
    let isNew: Bool?
    let content: NotificationContentDoc?
    let createdAt: Date

    /// Команды перевода через запятую — "Армия 100 богинь" / "ImageBoard
    /// Team, ONIMAI.RU" и т.п. (см. NotificationTeam). Пусто, если команд нет
    /// совсем (у категорий, отличных от "chapter", teams не подтверждён —
    /// декодируется best-effort и тогда останется пустым массивом).
    var teamNames: String { teams.map(\.name).joined(separator: ", ") }

    /// Текст для строки списка — из ProseMirror content, если распарсился;
    /// иначе best-effort заглушка по номеру/названию главы, чтобы строка не
    /// оставалась пустой.
    var displayText: String {
        if let text = content?.plainText, !text.isEmpty { return text }
        if let chapter {
            let number = [chapter.volume.map { "Том \($0)" }, chapter.number.map { "Глава \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
            return [number, chapter.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        }
        return "Новое уведомление"
    }

    static func == (lhs: NotificationItem, rhs: NotificationItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private enum CodingKeys: String, CodingKey {
        case id, type, category, data, content
        case createdAt = "created_at"
    }
    private enum DataKeys: String, CodingKey {
        case user, media, chapter, teams
        case isNew = "is_new"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil ?? "other"
        category = ((try? c.decodeIfPresent(String.self, forKey: .category)) ?? nil) ?? type
        content = (try? c.decodeIfPresent(NotificationContentDoc.self, forKey: .content)) ?? nil

        if let dataC = try? c.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            user = (try? dataC.decodeIfPresent(NotificationUser.self, forKey: .user)) ?? nil
            media = (try? dataC.decodeIfPresent(MangaItem.self, forKey: .media)) ?? nil
            chapter = (try? dataC.decodeIfPresent(NotificationChapter.self, forKey: .chapter)) ?? nil
            teams = (((try? dataC.decodeIfPresent(LossyArray<NotificationTeam>.self, forKey: .teams)) ?? nil)?.elements) ?? []
            isNew = (try? dataC.decodeIfPresent(Bool.self, forKey: .isNew)) ?? nil
        } else {
            user = nil; media = nil; chapter = nil; teams = []; isNew = nil
        }

        let rawDate = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) ?? ""
        createdAt = APIISODate.parse(rawDate) ?? Date()
    }
}

/// `GET /notifications/count` — ПОДТВЕРЖДЕНО реальным перехватом (три файла,
/// один запрос без query-параметров): счётчики по категориям (all/chapter/
/// chapter_player/episode/comments/message/card/other), отдельными блоками
/// для unread/read/all.
struct NotificationCounts: Decodable {
    let unread: NotificationCategoryCounts
    let read: NotificationCategoryCounts
    let all: NotificationCategoryCounts
}

struct NotificationCategoryCounts: Decodable {
    let all: Int
    let chapter: Int
    let chapterPlayer: Int
    let episode: Int
    let comments: Int
    let message: Int
    let card: Int
    let other: Int

    enum CodingKeys: String, CodingKey {
        case all, chapter, episode, comments, message, card, other
        case chapterPlayer = "chapter_player"
    }
}
