import Foundation

/// Ошибки ThreeHentaiProvider — та же намеренно простая схема, что у
/// HitomiError/EHentaiError.
enum ThreeHentaiError: Error {
    case badResponse
}

/// Клиент 3hentai.net — СВОЯ, полностью отдельная реализация, никак не
/// связанная с MangaNetworkService/LibSite/HitomiProvider/EHentaiProvider.
/// Все URL/форматы ниже подтверждены реальным HAR (`de8dcedb-
/// ProxyPin830_21_46_50.har`, 30.08 вечер) — свежий разбор конкретно под
/// эту интеграцию, живым `curl` (сайт, в отличие от hitomi.la, из этой
/// песочницы доступен напрямую, без domain-fronting трюков).
///
/// Сайт устроен ПРОЩЕ обоих предыдущих: обычный серверный HTML (никакого
/// JS-рендеринга выдачи, в отличие от hitomi.la, и никакой gg.js-формулы
/// для полноразмерных страниц, в отличие от hitomi же) — картинки чтения
/// вообще не требуют отдельного сетевого запроса (в отличие от e-hentai,
/// где ссылка на H@H-узел временная и добывается только живым запросом):
/// хост+внутренний ID картиночного CDN достаточно один раз вытащить из
/// обложки на странице тайтла (см. extractHost(from:)), дальше и миниатюра,
/// и полный размер строятся ЧИСТОЙ формулой (см. pageImageURL).
///
/// `ru.` — не domain-fronting (в отличие от `ltn.gold-usergeneratedcontent.
/// net` у hitomi), а просто языковая версия сайта (тот же контент, что и
/// на голом `3hentai.net`, подтверждено HAR — canonical-ссылки на страницах
/// сами указывают на `ru.3hentai.net`); используется тут только чтобы
/// интерфейсные строки самого HTML (которые в код не идут, только
/// структура/атрибуты) были на понятном языке при живой проверке.
struct ThreeHentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .threeHentai
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // Полноценный алфавитный справочник — tags/series/characters/
        // artists/groups, все 5 подтверждены HAR (letter-picker + список
        // `filter-elem`, тот же принцип разметки, что у hitomi.la, просто
        // другие CSS-классы), см. fetchTagIndex.
        hasTagBrowser: true,
        // НАСТОЯЩИЙ полнотекстовый поиск (`?q=`), в отличие от hitomi
        // (там честная заглушка-команда) — подтверждено HAR: свободный
        // текст, запятая как AND нескольких тегов (`q=anal,diaper` →
        // "Anal,diaper", 125 результатов — оба тега учтены сразу), команда
        // `tag:значение`. Прогрессия ("несколько слов подряд" — насколько
        // это AND vs OR/фраза целиком) живым HAR не подтверждена дальше
        // одного примера — честно не берёмся утверждать точную семантику
        // сверх того, что видно.
        hasSearch: true,
        // Подтверждена РОВНО одна категория живьём (`doujinshi`) — сайт
        // явно поддерживает и другие (Manga/Artist CG/... — обычная для
        // таких сайтов таксономия), но без реального списка категорий в
        // HAR честно не берёмся её выдумывать (см. отчёт пользователю) —
        // поэтому UI-фильтра по категориям здесь нет вообще, только сам
        // тип показывается в карточке тайтла (metadata.type).
        hasCategoryFilter: false,
        // Номер страницы — БУКВАЛЬНО кусок пути (`/category/doujinshi/2`,
        // `/tags/{slug}/2`, `/search?q=...&page=2`) — точный переход, тот
        // же принцип, что у hitomi (в отличие от e-hentai — там range=
        // приблизительный).
        hasPageJump: true,
        // Популярное: 24 часа/неделя/всё время — подтверждено HAR
        // (`?sort=popular-24h`/`popular-7d`/`popular`), см. SortOption.
        // Только на страницах выдачи (тег/категория/поиск) — на главной
        // ленте "Recently" сортировки НЕТ (нет `.sorts`-блока в HAR),
        // поэтому пустой запрос честно игнорирует sortKey (см.
        // fetchIdsBySearch).
        hasSortOptions: true,
        // На самом сайте аккаунт/избранное/история РЕАЛЬНО есть (подтверждено
        // HAR — `/user/panel`, `toggle-favorite`), но эта интеграция без
        // входа в аккаунт, поэтому здесь всё равно false — тот же принцип,
        // что и у EHentaiProvider (см. её doc-comment).
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // Ни одного comment-related фрагмента разметки ни на одной
        // сохранённой карточке тайтла в HAR — честно false, не выдумываем
        // (тот же принцип, что у hitomi).
        hasComments: false
    )

    /// Отдельная сессия — не пересекается ни с одним другим провайдером.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://ru.3hentai.net/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://ru.3hentai.net"

    // MARK: Алфавитный справочник (tags/series/characters/artists/groups)

    private static func tagKindPath(_ kind: ExternalTagKind) -> String {
        switch kind {
        case .tags: return "tags"
        case .series: return "series"
        case .characters: return "characters"
        case .artists: return "artists"
        case .groups: return "groups"
        }
    }

    /// "#" — отдельный бакет символов/цифр (подтверждено HAR:
    /// `?letter=%23`), ровно как "123" у hitomi — только там это часть
    /// пути, здесь query-параметр. `letter.isNumber` — тот же сигнал,
    /// который уже шлёт ExternalTagBrowserView вместо "#" (см.
    /// HitomiProvider.fetchTagIndex — тот же приём).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        let letterParam = letter.isNumber ? "#" : String(letter).lowercased()
        let encodedLetter = letterParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? letterParam
        let basePath = Self.tagKindPath(kind)
        var result: [ExternalTagEntry] = []
        var seenSlugs = Set<String>()
        // Занятые буквы (например "y" у artists/groups) реально паджинируются
        // (`?letter=y&page=2`, подтверждено HAR) — тянем все страницы
        // подряд, не только первую, иначе список выглядел бы обрезанным
        // без видимой причины. Разумный потолок (20 страниц = максимум
        // ~500 записей) — просто чтобы не уйти в бесконечный цикл при
        // непредвиденной разметке.
        var page = 1
        while page <= 20 {
            var urlString = "\(Self.baseURL)/\(basePath)?letter=\(encodedLetter)"
            if page > 1 { urlString += "&page=\(page)" }
            guard let url = URL(string: urlString) else { break }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch {
                break
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { break }
            let entries = Self.parseFilterElemList(html: html, basePath: basePath)
            var addedAny = false
            for entry in entries where !seenSlugs.contains(entry.slug) {
                seenSlugs.insert(entry.slug)
                result.append(entry)
                addedAny = true
            }
            guard addedAny, Self.hasNextPage(html: html) else { break }
            page += 1
        }
        return result
    }

    /// `<span class="filter-elem[ ...]"><a class="name"
    /// href="https://ru.3hentai.net/{basePath}/{slug}" data-qty="N">
    /// NAME</a></span>` — общий формат для tags/series/characters/artists/
    /// groups (подтверждено HAR на всех пяти), различается только
    /// `basePath` в самом href. `data-qty` — сокращённое число ("217k"),
    /// не всегда целое — берём как есть строкой в `count`, если не
    /// парсится как Int (см. parseCount ниже).
    private static func parseFilterElemList(html: String, basePath: String) -> [ExternalTagEntry] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a class="name" href="https://ru\.3hentai\.net/\#(NSRegularExpression.escapedPattern(for: basePath))/([^"]+)" data-qty="([^"]*)">\s*([^<]+?)\s*</a>"#
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [ExternalTagEntry] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 4,
                  let slugRange = Range(match.range(at: 1), in: html),
                  let qtyRange = Range(match.range(at: 2), in: html),
                  let nameRange = Range(match.range(at: 3), in: html) else { return }
            let slug = String(html[slugRange])
            let count = parseCount(String(html[qtyRange]))
            let name = decodeHTMLEntities(String(html[nameRange]))
            result.append(ExternalTagEntry(id: slug, name: name, count: count, slug: slug))
        }
        return result
    }

    /// "217k"/"87k"/"0" → приблизительное целое (сайт сокращает крупные
    /// числа буквой "k" = ×1000, "m" не встречалось в HAR, но на всякий
    /// случай тоже поддержано).
    private static func parseCount(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let plain = Int(trimmed) { return plain }
        guard let last = trimmed.last else { return 0 }
        let numberPart = trimmed.dropLast()
        guard let value = Double(numberPart) else { return 0 }
        switch last {
        case "k", "K": return Int(value * 1_000)
        case "m", "M": return Int(value * 1_000_000)
        default: return 0
        }
    }

    private static func hasNextPage(html: String) -> Bool {
        html.range(of: #"rel="next""#, options: .regularExpression) != nil
    }

    /// Автокомплит не подтверждён HAR — ни одного JSON/XHR-эндпоинта под
    /// поиск-по-мере-набора не встретилось (только сам HTML `/search?q=`
    /// целиком) — честно пусто, тот же принцип, что у EHentaiProvider.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: Сортировка

    /// Переиспользует СЛОВАРЬ hitomi (`HitomiProvider.SortOption`) — не
    /// потому что семантика идентична, а потому что общий UI сортировки
    /// (см. ExternalCatalogGridView.sortSelection/sortMenuButton) сейчас
    /// жёстко завязан именно на этот enum (единственный источник вариантов
    /// на весь экран, не per-провайдерный). У 3hentai реально ТОЛЬКО 3
    /// градации (24 часа/неделя/всё время, подтверждено HAR) — `.dateAdded`
    /// маппится в "без сортировки" (как и у hitomi), `.popularToday`/
    /// `.popularWeek` — в подтверждённые `popular-24h`/`popular-7d`, а
    /// `.popularMonth`/`.popularYear` (пункты меню, которых у 3hentai в
    /// принципе нет) — оба честно падают в `popular` (всё время), не в
    /// ошибку и не в игнор — ближайший по смыслу реально существующий
    /// вариант. См. отчёт пользователю — несовершенное соответствие,
    /// отдельный per-сайт UI сортировки в это не переделывался.
    private static func sortQueryValue(for sortKey: String?) -> String? {
        guard let option = sortKey.flatMap(HitomiProvider.SortOption.init(rawValue:)) else { return nil }
        switch option {
        case .dateAdded: return nil
        case .popularToday: return "popular-24h"
        case .popularWeek: return "popular-7d"
        case .popularMonth, .popularYear: return "popular"
        }
    }

    // MARK: Список тайтлов по тегу/категории

    private static func tagBasePath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        // female/male у 3hentai — НЕ отдельный namespace: пол уже "зашит"
        // в САМ slug (`big-breasts-female`/`big-breasts-male`, см.
        // ExternalTagBrowserView — entry.slug для .tags уже содержит этот
        // суффикс, ничего добавлять здесь не нужно, в отличие от hitomi).
        case .tag, .female, .male: return "tags"
        case .series: return "series"
        case .character: return "characters"
        case .artist: return "artists"
        case .group: return "groups"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let basePath = Self.tagBasePath(for: namespace)
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        var urlString = "\(Self.baseURL)/\(basePath)/\(encodedValue)"
        let page = Int(cursor ?? "1") ?? 1
        if page > 1 { urlString += "/\(page)" }
        if let sortValue = Self.sortQueryValue(for: sortKey) { urlString += "?sort=\(sortValue)" }
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Курсор — просто номер страницы (та же точная схема, что у hitomi,
    /// см. HitomiProvider.cursorForPage) — здесь страница напрямую в пути
    /// URL, а не байтовый offset, поэтому даже проще: строка = номер как
    /// есть, без арифметики.
    func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return String(page)
    }

    /// Пустой запрос — «Recently» (главная страница `/`, пагинация —
    /// `/{page}`, без сортировки — на самой ленте её нет, см. capabilities.
    /// hasSortOptions doc-comment). Непустой — обычный `?q=` (свободный
    /// текст ИЛИ `tag:значение`-команда, как на самом сайте, см.
    /// capabilities.hasSearch doc-comment).
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let page = Int(cursor ?? "1") ?? 1
        if trimmed.isEmpty {
            var urlString = Self.baseURL
            if page > 1 { urlString += "/\(page)" }
            return try await fetchGalleryList(urlString: urlString, currentPage: page)
        }
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        var params = ["q=\(encodedQuery)"]
        if page > 1 { params.append("page=\(page)") }
        if let sortValue = Self.sortQueryValue(for: sortKey) { params.append("sort=\(sortValue)") }
        let urlString = "\(Self.baseURL)/search?" + params.joined(separator: "&")
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Общий разбор страницы выдачи (главная/категория/тег/поиск — везде
    /// одна и та же разметка `.doujin-col`/`.cover`) — 25 элементов на
    /// страницу, число фиксировано сайтом (не `limit` из параметра — тот
    /// же компромисс, что у EHentaiProvider.fetchGalleryList).
    private func fetchGalleryList(urlString: String, currentPage: Int) async throws -> (ids: [Int], nextCursor: String?) {
        guard let url = URL(string: urlString) else { throw ThreeHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ThreeHentaiError.badResponse
        }
        let ids = Self.parseGalleryIds(html: html)
        let nextCursor = Self.hasNextPage(html: html) ? String(currentPage + 1) : nil
        return (ids, nextCursor)
    }

    private static func parseGalleryIds(html: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"href="https://ru\.3hentai\.net/d/(\d+)" class="cover""#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [Int] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: html),
                  let id = Int(html[idRange]) else { return }
            result.append(id)
        }
        return result
    }

    // MARK: Карточка тайтла

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "\(Self.baseURL)/d/\(id)") else { throw ThreeHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ThreeHentaiError.badResponse
        }
        return Self.parseDetail(html: html, id: id)
    }

    /// `https://{host}/d{internalId}/cover.jpg` — вытаскивает `{host}/
    /// d{internalId}` целиком (например "s1.3hentai.net/d2441052") —
    /// используется как есть и для миниатюр (`/{n}t.jpg`), и для
    /// полноразмерных страниц (`/{n}.jpg`, см. pageImageURL) — оба живут
    /// на ОДНОМ и том же хосте+ID, что и обложка, подтверждено HAR (host
    /// иногда `.net`, иногда `.xyz` — берём буквально то, что реально
    /// отдал сервер В ЭТОМ ответе, не хардкодим ни один вариант).
    private static func extractStorageKey(from html: String) -> String? {
        firstMatch(in: html, pattern: #"data-src="https://(s\d+\.3hentai\.(?:net|xyz)/d\d+)/cover\.jpg""#)
    }

    /// Заголовок раздела над блоком тегов/категории/языка (`Категории:`/
    /// `Серия:`/`Персонажи:`/`Теги:`) намеренно НЕ разбирается по этому
    /// тексту (была бы зависимость от русской локализации самого сайта,
    /// хрупко) — вместо этого маршрутизация по ПЕРВОМУ сегменту пути в
    /// href (`category`/`series`/`characters`/`artists`/`groups`/
    /// `language`/`tags`) — устойчиво к языку интерфейса и к тому, в каком
    /// именно `<div class="tag-container">` оказалась ссылка.
    private static func parseDetail(html: String, id: Int) -> ExternalGalleryDetail {
        // `.*?` (dotall) + вырезка вложенных тегов, НЕ `[^<]*` — часть
        // заголовков сайт оборачивает серединным куском в
        // `<span class="middle-title">...</span>` (подтверждено живым
        // curl 30.08 на этом же самом ID — HAR того же тайтла его почему-то
        // не содержал, а живой fetch содержит), `[^<]*` на такой разметке
        // не матчился бы вообще (обрывался на первом `<`), из-за чего
        // title тихо падал в "Untitled" на любом таком заголовке.
        let title = firstMatch(
            in: html, pattern: #"<h1 class="text-left font-weight-bold">(.*?)</h1>"#,
            options: [.dotMatchesLineSeparators]
        ).map { stripInnerTags($0) }.map(decodeHTMLEntities) ?? "Untitled"
        let posted = firstMatch(in: html, pattern: #"<time datetime="([^"]+)""#)

        var type = ""
        var series: [String] = []
        var characters: [String] = []
        var artists: [String] = []
        var groups: [String] = []
        var languageParts: [String] = []
        var tags: [ExternalGalleryTag] = []

        if let regex = try? NSRegularExpression(
            pattern: #"<a class="name" href="https://ru\.3hentai\.net/([a-z]+)/([^"]+)" data-qty="[^"]*">\s*([^<]+?)\s*</a>"#
        ) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 4,
                      let sectionRange = Range(match.range(at: 1), in: html),
                      let slugRange = Range(match.range(at: 2), in: html),
                      let nameRange = Range(match.range(at: 3), in: html) else { return }
                let section = String(html[sectionRange])
                let slug = String(html[slugRange])
                let name = decodeHTMLEntities(String(html[nameRange]))
                switch section {
                case "category":
                    if type.isEmpty { type = name }
                case "series": series.append(name)
                case "characters": characters.append(name)
                case "artists": artists.append(name)
                case "groups": groups.append(name)
                case "language": languageParts.append(name)
                case "tags":
                    // Пол — по СУФФИКСУ slug (`-female`/`-male`), не по
                    // display-тексту (тот содержит " (female)"/" (male)" в
                    // скобках, см. ниже strippedTagName) — надёжнее, slug
                    // всегда ASCII и без вариаций пробелов/регистра.
                    let female = slug.hasSuffix("-female")
                    let male = slug.hasSuffix("-male")
                    let cleanName = strippedTagName(name)
                    tags.append(ExternalGalleryTag(name: cleanName, female: female, male: male))
                default: break
                }
            }
        }

        // Полноразмерные/миниатюрные страницы — см. extractStorageKey
        // (host+внутренний ID) + максимальный номер страницы среди
        // `{n}t.jpg`-миниатюр полосы превью (нет отдельного "related"/
        // похожих галерей на этой же странице, которые могли бы дать
        // ложные высокие номера — см. doc-comment типа выше).
        var pages: [ExternalGalleryPage] = []
        if let storageKey = extractStorageKey(from: html) {
            var maxPage = 0
            if let regex = try? NSRegularExpression(pattern: #"/(\d+)t\.jpg""#) {
                let range = NSRange(html.startIndex..., in: html)
                regex.enumerateMatches(in: html, range: range) { match, _, _ in
                    guard let match, match.numberOfRanges == 2,
                          let numRange = Range(match.range(at: 1), in: html),
                          let n = Int(html[numRange]) else { return }
                    maxPage = max(maxPage, n)
                }
            }
            if maxPage > 0 {
                pages = (1...maxPage).map { n in
                    ExternalGalleryPage(
                        index: n, key: storageKey, width: 200, height: 282,
                        thumbnailURL: URL(string: "https://\(storageKey)/\(n)t.jpg"),
                        thumbnailSpriteOffsetX: nil
                    )
                }
            }
        }
        let coverURL = extractStorageKey(from: html).flatMap { URL(string: "https://\($0)/cover.jpg") }

        return ExternalGalleryDetail(
            id: id,
            site: .threeHentai,
            title: title,
            type: type,
            language: languageParts.isEmpty ? nil : languageParts.joined(separator: ", "),
            tags: tags,
            artists: artists,
            groups: groups,
            characters: characters,
            series: series,
            // Нет отдельного списка "похожих"/related ID на странице
            // тайтла (ни одного related-фрагмента разметки в HAR, в
            // отличие от hitomi) — честно пусто, как у e-hentai.
            related: [],
            pages: pages,
            coverURL: coverURL,
            posted: posted,
            // 3hentai физически не имеет этих полей (e-hentai-специфичные,
            // см. план ЧАСТЬ B.2) — честно nil/[], не выдумываем.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: nil,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    /// "big breasts (female)" → "big breasts" — display-текст сайта сам
    /// приписывает пол в скобках (см. `tag_display = tag.replace(...)`-
    /// аналог у hitomi, тот же принцип); female/male уже отдельно
    /// извлечены из slug (см. parseDetail), в `name` эта информация была
    /// бы избыточной (UI и так подписывает блок "Женское"/"Мужское", см.
    /// ExternalGalleryDetailView.aboutTab).
    private static func strippedTagName(_ name: String) -> String {
        guard let range = name.range(of: #"\s*\((?:female|male)\)\s*$"#, options: .regularExpression) else { return name }
        return String(name[name.startIndex..<range.lowerBound])
    }

    // MARK: URL картинок

    /// Чистая формула (host+internalId уже в `page.key`, см.
    /// extractStorageKey) — без сети, как у hitomi (в отличие от
    /// e-hentai — там реальный запрос на каждую страницу), просто
    /// обёрнута в async ради общего протокола.
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: "https://\(page.key)/\(page.index).jpg") else {
            throw ThreeHentaiError.badResponse
        }
        return url
    }

    // MARK: Утилиты

    private static func firstMatch(in html: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 2,
              let matchRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[matchRange])
    }

    /// Вырезает вложенные HTML-теги (например `<span class="middle-title">
    /// ...</span>` внутри заголовка, см. parseDetail) — оставляет только
    /// текстовое содержимое, тот же приём, что у EHentaiProvider.
    /// parseComments для текста комментария.
    private static func stripInnerTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
