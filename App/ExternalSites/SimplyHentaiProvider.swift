import Foundation

/// Ошибки SimplyHentaiProvider.
enum SimplyHentaiError: Error {
    case badResponse
    /// fetchGalleryDetail(id:) вызван с id, который эта сессия ЕЩЁ ни разу
    /// не видела ни в одном листинге/выдаче (см. doc-comment типа насчёт
    /// slug-адресации) — без пары id→slug карточку открыть нельзя.
    case unknownSlug
}

/// Расширенные поля поиска — по прямой просьбе (31.08): у simply-hentai, в
/// отличие от imhentai, `/search/complex` реально принимает `query=` И
/// `filter[tags][N]=`/`filter[parodies][N]=`/`filter[characters][N]=`/
/// `filter[artists][N]=`/`filter[translators][N]=`/`filter[language][N]=`/
/// `filter[series_title][N]=` В ОДНОМ запросе (подтверждено HAR — реальная
/// цепочка из HAR буквально несёт все три сразу: `filter[series_title][0]=
/// Danganronpa&filter[tags][0]=Bondage&filter[tags][1]=Ahegao&filter[tags]
/// [2]=Anal&filter[artists][0]=matou&query=scat&page=1`). Общее поле поиска
/// экрана (committedQuery) продолжает работать как есть — эти поля лишь
/// ДОБАВЛЯЮТ отдельные `filter[...]=` параметры к тому же запросу, не
/// подменяют и не мешают ему (в отличие от imhentai, где общий текст
/// пришлось убрать вообще — здесь `/search/complex` один парсер на всё,
/// такой проблемы просто нет).
struct SimplyHentaiAdvancedQuery {
    var tags: [String] = []
    var parodies: [String] = []
    var characters: [String] = []
    var artists: [String] = []
    var translators: [String] = []
    var language: [String] = []
    var seriesTitle: String = ""

    var isEmpty: Bool {
        tags.isEmpty && parodies.isEmpty && characters.isEmpty && artists.isEmpty
            && translators.isEmpty && language.isEmpty
            && seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Разделитель — управляющий символ U+0001, который ни один пользователь
    /// не наберёт руками в строке поиска — НЕ синтаксис самого сайта (как
    /// `+tag:"..."` у imhentai), это ЧИСТО внутренний канал между
    /// ExternalSearchView/ExternalCombinedCatalogView.composedQuery и
    /// SimplyHentaiProvider.fetchIdsBySearch: протокол ExternalSiteProvider
    /// несёт запрос ОДНОЙ строкой (см. ExternalCatalogQuery.search), поэтому
    /// сюда "впаиваются" доп. поля, а провайдер их же и распаковывает
    /// обратно в отдельные `filter[...]=` параметры перед реальным запросом
    /// — наружу (в URL) эти управляющие символы никогда не попадают.
    fileprivate static let fieldDelimiter = "\u{1}"

    /// Кодирует себя поверх свободного текста в одну строку для
    /// ExternalCatalogQuery.search(query:) — см. fieldDelimiter doc-comment.
    func encoded(freeText: String) -> String {
        var parts = [freeText]
        func append(_ key: String, _ values: [String]) {
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                parts.append("\(Self.fieldDelimiter)\(key)=\(trimmed)")
            }
        }
        append("tags", tags)
        append("parodies", parodies)
        append("characters", characters)
        append("artists", artists)
        append("translators", translators)
        append("language", language)
        let trimmedSeries = seriesTitle.trimmingCharacters(in: .whitespaces)
        if !trimmedSeries.isEmpty {
            parts.append("\(Self.fieldDelimiter)series_title=\(trimmedSeries)")
        }
        return parts.joined()
    }
}

/// Клиент simply-hentai.com — СВОЯ, полностью отдельная реализация. Все
/// эндпоинты ниже подтверждены реальным HAR пользователя (31.08 вечер,
/// `ProxyPin8-31_22_33_54.har`) — живым curl НЕ перепроверено: `api-v3.
/// simply-hentai.com` из этой песочницы отвечает Cloudflare-джва-
/// челленджем ("Just a moment...", 403) на любой путь, ровно та же
/// картина, что и у ImhentaiProvider (см. её doc-comment насчёт разницы
/// между чистым `URLSession` и настоящим браузером — тот же принцип
/// применим и здесь, отдельно не повторяем).
///
/// В отличие от всех остальных четырёх сайтов, здесь НАСТОЯЩИЙ версионный
/// JSON REST API (`/v3/...`, Next.js-фронтенд на www поверх него), а не
/// HTML-страницы под разбор регулярками — структура ответов взята из
/// декодированных Codable-моделей ниже, один в один под реальные поля из
/// HAR.
///
/// ВАЖНО про адресацию: у альбома есть И числовой `id`, И `slug`, но
/// `/v3/manga/{slug}` (карточка) и `/v3/manga/{slug}/pages` (страницы)
/// адресуются ТОЛЬКО по slug — НИ ОДНОГО запроса по числовому id в HAR не
/// встретилось, живьём не перепроверено, поэтому честно не рискуем
/// предполагать, что `/v3/manga/{id}` тоже сработает. `fetchIdsByTag`/
/// `fetchIdsBySearch` по контракту протокола обязаны возвращать `[Int]`
/// (см. ExternalSiteProvider) — поэтому SimplyHentaiSlugCache запоминает
/// пару id→slug при КАЖДОМ разборе альбома из любого ответа (листинг/
/// поиск/тег/похожие), и fetchGalleryDetail(id:) берёт slug оттуда.
/// Работает надёжно, если карточка открывается из листинга/похожих (как
/// оно всегда и происходит в этом приложении) — единственный случай,
/// когда это не сработает, это id, полученный ИЗВНЕ приложения (сюда
/// такое не поступает).
struct SimplyHentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .simplyHentai
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // Алфавитный справочник — Tags/Parodies/Characters подтверждены
        // HAR (`/v3/tags?type={tags|parodies|characters}&letter=...`,
        // буквы `a`...`z` реально перебирались). Artists/Translators —
        // сайт ЗНАЕТ такие сущности (поля `artists`/`translators` в
        // карточке альбома, и `filter[artists][]`/`filter[translators][]`
        // в /search/complex подтверждены), но алфавитного списка под них
        // ни разу не запрошено — честно [] в fetchTagIndex, не выдумываем
        // несуществующий в HAR letter-запрос.
        hasTagBrowser: true,
        // /v3/search/complex?query=... — подтверждено HAR (обычный текст,
        // реальные релевантные результаты на "scat"/"genshin"-подобные
        // запросы). Отдельно подтверждён и мульти-фильтр (filter[tags][]/
        // filter[parodies][]/filter[characters][]/filter[artists][]/
        // filter[translators][]/filter[language][]/filter[series_title][]
        // — все встретились в HAR как реальные комбинации ВМЕСТЕ с query=,
        // см. SimplyHentaiAdvancedQuery/SimplyHentaiAdvancedFieldsPicker).
        hasSearch: true,
        // Нет EHentaiCategory-подобного bitmask-переключателя категорий —
        // но флаг переиспользован (тот же приём, что и у imhentai) как
        // общий гейт "есть лист «Фильтры»" в ExternalSearchView/
        // ExternalCombinedCatalogView: здесь он открывает
        // SimplyHentaiAdvancedFieldsPicker (Tags/Parodies/Characters/
        // Artists/Translators/Language/Series title), а не категории.
        hasCategoryFilter: true,
        // Пагинация — ЧЕСТНАЯ, с сервера: `pagination.current/next/pages/
        // count` в каждом ответе (не наше предположение по наличию кнопки
        // "next", как у HTML-сайтов) — подтверждено на /tags, /tag/{slug},
        // /search/complex, /mangas.
        hasPageJump: true,
        // Ни на /search/complex, ни на /tag/{slug} НИ РАЗУ не встретился
        // параметр `sort=` в HAR (только у отдельных, несвязанных с
        // поиском/тегом эндпоинтов — /mangas?sort=spotlight,
        // /tags?sort=popularity — это сортировка САМОГО списка тегов, не
        // выдачи альбомов) — честно false, не выдумываем несуществующую
        // комбинацию.
        hasSortOptions: false,
        // Как и у остальных внешних сайтов в этом клиенте — без входа в
        // аккаунт (см. doc-comment ImhentaiProvider.capabilities).
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // `comment_count` — просто число прямо на альбоме, ни одного
        // отдельного эндпоинта со СПИСКОМ комментариев в HAR не
        // встретилось — честно false, не выдумываем.
        hasComments: false
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://www.simply-hentai.com",
            "Referer": "https://www.simply-hentai.com/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://api-v3.simply-hentai.com/v3"

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: Кэш id→slug (см. doc-comment типа)

    private actor SlugCache {
        static let shared = SlugCache()
        private var map: [Int: String] = [:]
        func store(id: Int, slug: String) { map[id] = slug }
        func slug(for id: Int) -> String? { map[id] }
    }

    // MARK: Codable-модели — один в один под реальные ответы `/v3/...` из HAR.

    private struct SizesDTO: Decodable {
        let full: String
        let thumb: String?
        let smallThumb: String?
        let giantThumb: String?
    }

    private struct PageDTO: Decodable {
        let id: Int
        let pageNum: Int?
        let sizes: SizesDTO
    }

    private struct LanguageDTO: Decodable {
        let name: String
        let slug: String?
        let flagCode: String?
    }

    /// Один элемент Tags/Parodies/Characters/Artists/Series-тега — та же
    /// форма, что и вложенные `tags`/`parodies`/`characters`/`artists`/
    /// `series` в карточке альбома, см. TagRefDTO.
    private struct TagRefDTO: Decodable {
        let id: Int
        let slug: String
        let title: String
        let letter: String?
        let objectCount: Int?
        let type: String?
    }

    private struct InteractionsDTO: Decodable {
        let upvotes: Int?
        let downvotes: Int?
        let favorites: Int?
    }

    /// Общая модель альбома — используется и в листингах (там `related`/
    /// `pages`/полный `tags` обычно отсутствуют, просто nil), и в детальном
    /// ответе `/v3/manga/{slug}` (там уже всё заполнено, кроме `pages` —
    /// та живёт в ОТДЕЛЬНОМ ответе `/v3/manga/{slug}/pages`, см.
    /// fetchGalleryDetail).
    private struct AlbumDTO: Decodable {
        let id: Int
        let slug: String
        let title: String
        let description: String?
        let imageCount: Int?
        let commentCount: Int?
        let language: LanguageDTO?
        let preview: PageDTO?
        let series: TagRefDTO?
        let tags: [TagRefDTO]?
        let parodies: [TagRefDTO]?
        let characters: [TagRefDTO]?
        let artists: [TagRefDTO]?
        // На сайте нет отдельного понятия "групп" (сканлейт-групп) — есть
        // переводчики (translators), см. doc-comment ExternalGalleryDetail
        // насчёт того, куда они кладутся в общей модели приложения.
        let translators: [TagRefDTO]?
        let related: [AlbumDTO]?
        let createdAt: String?
        let interactions: InteractionsDTO?
    }

    private struct SearchResultItemDTO: Decodable {
        let object: AlbumDTO
    }

    private struct PaginationDTO: Decodable {
        let current: Int?
        let next: Int?
    }

    private struct ListResponseDTO<T: Decodable>: Decodable {
        let data: [T]
        let pagination: PaginationDTO?
    }

    private struct DetailResponseDTO<T: Decodable>: Decodable {
        let data: T
    }

    private struct TagDetailDataDTO: Decodable {
        let albums: [AlbumDTO]
    }

    private struct TagDetailResponseDTO: Decodable {
        let data: TagDetailDataDTO
        let pagination: PaginationDTO?
    }

    private struct PagesDataDTO: Decodable {
        let pages: [PageDTO]
    }

    // MARK: Алфавитный справочник (Tags/Parodies/Characters)

    private static func tagsListType(for kind: ExternalTagKind) -> String? {
        switch kind {
        case .tags: return "tags"
        case .series: return "parodies"
        case .characters: return "characters"
        // Не подтверждено HAR — сайт ни разу не запросил алфавитный
        // список артистов/переводчиков, см. capabilities.hasTagBrowser
        // doc-comment.
        case .artists: return nil
        case .groups: return nil
        }
    }

    /// Буква — только a...z (подтверждено HAR); отдельного бакета для
    /// цифр/символов не встретилось ни разу — честно [] на letter.isNumber,
    /// не гадаем сигнал. Пагинация — реальная, с сервера
    /// (`pagination.next`), не догадка по наличию контента.
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        guard !letter.isNumber, let typeValue = Self.tagsListType(for: kind) else { return [] }
        let letterParam = String(letter).lowercased()
        var result: [ExternalTagEntry] = []
        var page = 1
        while page <= 30 {
            let urlString = "\(Self.baseURL)/tags?type=\(typeValue)&letter=\(letterParam)&page=\(page)"
            guard let url = URL(string: urlString) else { break }
            let decoded: ListResponseDTO<TagRefDTO>
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { break }
                decoded = try Self.decoder.decode(ListResponseDTO<TagRefDTO>.self, from: data)
            } catch {
                break
            }
            for tag in decoded.data {
                result.append(ExternalTagEntry(id: tag.slug, name: tag.title, count: tag.objectCount ?? 0, slug: tag.slug))
            }
            guard let next = decoded.pagination?.next, next > page else { break }
            page = next
        }
        return result
    }

    /// Автокомплит — РЕАЛЬНЫЙ, подтверждён HAR (`/v3/search/autocomplete?
    /// q=scat` → живой массив релевантных строк-подсказок). Отдаёт просто
    /// текст (заголовки/теги вперемешку), без числа тайтлов/категории —
    /// честно `count: 0`/`category: "search"`, не выдумываем то, чего сайт
    /// не прислал.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.baseURL)/search/autocomplete?q=\(encoded)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let suggestions = try Self.decoder.decode([String].self, from: data)
            return suggestions.map { ExternalTagSuggestion(name: $0, count: 0, category: "search") }
        } catch {
            return []
        }
    }

    // MARK: Список тайтлов по тегу/пародии/персонажу/автору

    /// `type=tag` подтверждён HAR живьём (`/v3/tag/females-only?type=tag`).
    /// `parody`/`character`/`artist`/`translator` — ПО СИММЕТРИИ с тем же
    /// самым эндпоинтом (та же форма URL, тот же параметр `type`, что и у
    /// `/v3/tags?type={tags|parodies|characters}` листинга) — не
    /// перепроверено отдельно живым запросом под каждый вариант.
    private static func tagDetailType(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male: return "tag"
        case .series: return "parody"
        case .character: return "character"
        case .artist: return "artist"
        case .group: return "translator"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `value` — либо готовый slug (из ExternalTagBrowserView/entry.slug —
    /// используется КАК ЕСТЬ, надёжно), либо чистое отображаемое имя из
    /// чипа карточки тайтла (ExternalGalleryDetailView) — тогда слагифицируем
    /// сами по общей формуле (см. slugify). ВАЖНО: у части тегов сайта
    /// slug несёт непредсказуемый числовой префикс-дизамбигуатор (реальный
    /// пример из HAR: тег "Ahegao" → slug "1-ahegao", не просто "ahegao") —
    /// это НЕ восстановить из одного отображаемого имени. Тот же класс
    /// несовершенства, что уже принят у остальных провайдеров для чип-тапа
    /// (см. doc-comment ThreeHentaiProvider.slugify) — переход из
    /// алфавитного справочника (там slug настоящий) всегда надёжен, переход
    /// по чипу карточки — лучшее возможное приближение, изредка промахнётся.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let type = Self.tagDetailType(for: namespace)
        let slug = Self.slugify(value)
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let page = Int(cursor ?? "1") ?? 1
        let urlString = "\(Self.baseURL)/tag/\(encodedSlug)?type=\(type)&page=\(page)"
        guard let url = URL(string: urlString) else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        let decoded = try Self.decoder.decode(TagDetailResponseDTO.self, from: data)
        var ids: [Int] = []
        for album in decoded.data.albums {
            await SlugCache.shared.store(id: album.id, slug: album.slug)
            ids.append(album.id)
        }
        return (ids, decoded.pagination?.next.map(String.init))
    }

    private static func slugify(_ text: String) -> String {
        var slug = ""
        var lastWasSeparator = true
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return String(page)
    }

    // MARK: Поиск

    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `query` может нести встроенные `filter[...]`-токены поверх
    /// свободного текста (см. SimplyHentaiAdvancedQuery.encoded/
    /// fieldDelimiter doc-comment — ExternalSearchView/
    /// ExternalCombinedCatalogView впаивают их туда) — здесь распаковываются
    /// обратно в реальные `filter[key][N]=value` параметры `/search/complex`.
    /// Полностью пустой запрос (ни текста, ни фильтров) → `/v3/mangas?
    /// sort=spotlight` (единственная подтверждённая HAR "лента по умолчанию";
    /// сайт честно её пагинирует — 415 страниц в ответе, реальная
    /// пагинация, не заглушка одной страницей, как у HentaiPill). Иначе →
    /// `/v3/search/complex?query=...&filter[...]=...` — сама комбинация
    /// query+filter подтверждена HAR (см. doc-comment SimplyHentaiAdvancedQuery
    /// с точной цепочкой параметров из живого запроса пользователя).
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let (freeText, filters) = Self.decodeQuery(query)
        let trimmedFreeText = freeText.trimmingCharacters(in: .whitespaces)
        let page = Int(cursor ?? "1") ?? 1
        let isSpotlight = trimmedFreeText.isEmpty && filters.isEmpty
        let urlString: String
        if isSpotlight {
            urlString = "\(Self.baseURL)/mangas?sort=spotlight&page=\(page)"
        } else {
            var items: [String] = []
            if !trimmedFreeText.isEmpty {
                let encoded = trimmedFreeText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedFreeText
                items.append("query=\(encoded)")
            }
            for (key, values) in filters {
                for (index, value) in values.enumerated() {
                    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                    items.append("filter[\(key)][\(index)]=\(encodedValue)")
                }
            }
            items.append("page=\(page)")
            urlString = "\(Self.baseURL)/search/complex?" + items.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        var ids: [Int] = []
        let nextCursor: String?
        if isSpotlight {
            let decoded = try Self.decoder.decode(ListResponseDTO<AlbumDTO>.self, from: data)
            for album in decoded.data {
                await SlugCache.shared.store(id: album.id, slug: album.slug)
                ids.append(album.id)
            }
            nextCursor = decoded.pagination?.next.map(String.init)
        } else {
            let decoded = try Self.decoder.decode(ListResponseDTO<SearchResultItemDTO>.self, from: data)
            for item in decoded.data {
                await SlugCache.shared.store(id: item.object.id, slug: item.object.slug)
                ids.append(item.object.id)
            }
            nextCursor = decoded.pagination?.next.map(String.init)
        }
        return (ids, nextCursor)
    }

    /// Распаковывает embedded-токены SimplyHentaiAdvancedQuery.encoded(freeText:)
    /// обратно в (свободный текст, [ключ фильтра: значения]) — см. её
    /// fieldDelimiter doc-comment. Порядок ключей словаря непредсказуем —
    /// это ОК, `/search/complex` не документирует порядок filter-полей,
    /// каждый ключ идёт своим отдельным набором `[N]`-индексов.
    private static func decodeQuery(_ raw: String) -> (freeText: String, filters: [String: [String]]) {
        let pieces = raw.components(separatedBy: SimplyHentaiAdvancedQuery.fieldDelimiter)
        let freeText = pieces.first ?? ""
        var filters: [String: [String]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<eq])
            let value = String(piece[piece.index(after: eq)...])
            guard !value.isEmpty else { continue }
            filters[key, default: []].append(value)
        }
        return (freeText, filters)
    }

    // MARK: Карточка тайтла

    /// Два отдельных запроса — `/v3/manga/{slug}` (метаданные + превью
    /// первых страниц + похожие) и `/v3/manga/{slug}/pages` (ПОЛНЫЙ список
    /// страниц, подтверждено HAR: у detail-ответа `images` — только 12 из
    /// заявленных 173, полный список — только в отдельном /pages) — гоняем
    /// параллельно (async let), не последовательно.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let slug = await SlugCache.shared.slug(for: id) else { throw SimplyHentaiError.unknownSlug }
        async let detailTask = Self.fetchAlbum(slug: slug, session: session)
        async let pagesTask = Self.fetchPages(slug: slug, session: session)
        let (detail, pages) = try await (detailTask, pagesTask)
        for rel in detail.related ?? [] {
            await SlugCache.shared.store(id: rel.id, slug: rel.slug)
        }
        return Self.buildGalleryDetail(id: id, detail: detail, pages: pages)
    }

    private static func fetchAlbum(slug: String, session: URLSession) async throws -> AlbumDTO {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "\(baseURL)/manga/\(encoded)") else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        return try decoder.decode(DetailResponseDTO<AlbumDTO>.self, from: data).data
    }

    private static func fetchPages(slug: String, session: URLSession) async throws -> [PageDTO] {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "\(baseURL)/manga/\(encoded)/pages") else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        return try decoder.decode(DetailResponseDTO<PagesDataDTO>.self, from: data).data.pages
    }

    /// `width`/`height` — сайт их для страниц НЕ отдаёт (в отличие от
    /// HentaiPill) — честно 0 (см. doc-comment ExternalGalleryPage — это
    /// штатное значение "не знаем заранее"). `key` — сразу готовый
    /// абсолютный URL полноразмерной картинки (`sizes.full`), без всякой
    /// формулы/CDN-шардирования, см. pageImageURL.
    private static func buildGalleryDetail(id: Int, detail: AlbumDTO, pages: [PageDTO]) -> ExternalGalleryDetail {
        let tags = (detail.tags ?? []).map { ExternalGalleryTag(name: $0.title, female: false, male: false) }
        let pageModels = pages.enumerated().map { offset, page in
            ExternalGalleryPage(
                index: offset + 1,
                key: page.sizes.full,
                width: 0, height: 0,
                thumbnailURL: URL(string: page.sizes.thumb ?? page.sizes.full),
                thumbnailSpriteOffsetX: nil
            )
        }
        return ExternalGalleryDetail(
            id: id,
            site: .simplyHentai,
            title: detail.title,
            // На сайте нет подтверждённого понятия "категория тайтла"
            // (Manga/Doujinshi/...) — `type` в JSON всегда буквально
            // "Album", не полезная категория — честно пусто, не выдумываем.
            type: "",
            language: detail.language?.name,
            tags: tags,
            artists: (detail.artists ?? []).map(\.title),
            // Переводчики (translators) — ближайший смысловой аналог
            // "групп" в общей модели приложения (см. doc-comment AlbumDTO.
            // translators), сайт своего понятия "группа" не имеет.
            groups: (detail.translators ?? []).map(\.title),
            characters: (detail.characters ?? []).map(\.title),
            series: (detail.parodies ?? []).map(\.title),
            related: (detail.related ?? []).map(\.id),
            pages: pageModels,
            coverURL: (detail.preview?.sizes.full).flatMap(URL.init(string:)),
            posted: detail.createdAt,
            parentId: nil, visible: nil, fileSize: nil,
            favoritedCount: detail.interactions?.favorites.map(String.init),
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    // MARK: URL картинок

    /// Без сети — `page.key` уже несёт готовый абсолютный URL `sizes.full`
    /// прямо из ответа `/manga/{slug}/pages` (см. buildGalleryDetail).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: page.key) else { throw SimplyHentaiError.badResponse }
        return url
    }
}
