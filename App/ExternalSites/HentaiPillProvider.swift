import Foundation

/// Ошибки HentaiPillProvider — та же намеренно простая схема, что у
/// остальных провайдеров этой папки.
enum HentaiPillError: Error {
    case badResponse
}

/// Клиент hentaipill.com — СВОЯ, полностью отдельная реализация. Все URL/
/// форматы ниже подтверждены реальным HAR пользователя (31.08,
/// `ProxyPin831_22_09_01.har`) И перепроверены живым curl из этой песочницы
/// (сайт, в отличие от imhentai, доступен НАПРЯМУЮ — ни Cloudflare-джва-
/// челленджа, ни доменного фронтинга, ни единого 403 на любой из проверенных
/// путей).
///
/// Устроен ПРОЩЕ всех остальных четырёх сайтов: у него в принципе НЕТ
/// отдельной "читалки" — карточка тайтла (`/gallery/g{id}`) СРАЗУ рендерит
/// ВСЕ страницы одним длинным `<img>`-списком (реальные ГОТОВЫЕ абсолютные
/// URL прямо в разметке, с width/height), а внизу неё же — блок "You may
/// also like" с похожими тайтлами. Ни формулы шардирования (hitomi/3hentai),
/// ни временных подписанных ссылок (e-hentai), ни отдельного chunk-запроса
/// на страницу — просто взять то, что уже лежит в HTML карточки.
///
/// ВАЖНО про CDN картинок (`b{N}.hentaipill.{com,me,...}`) — домен/TLD
/// РЕАЛЬНО плавает даже между двумя последовательными живыми запросами (HAR
/// пользователя показывал `.com`, живой curl в момент разбора — уже `.me`,
/// один и тот же internal picture id) — поэтому здесь НЕТ формулы host+id,
/// URL картинки берётся ЦЕЛИКОМ как есть из свежего HTML на момент запроса
/// карточки, никогда не кэшируется/не реконструируется отдельно (см.
/// parseDetail — `page.key` хранит уже готовый абсолютный URL).
struct HentaiPillProvider: ExternalSiteProvider {
    let site: ExternalSite = .hentaiPill
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // Полноценный алфавитный справочник — Tags(genre)/Parodies/
        // Characters/Artists, все 4 подтверждены HAR+живым curl (см.
        // fetchTagIndex). Group-раздела на сайте НЕТ ВООБЩЕ (ни пункта
        // меню, ни ссылок `/group/...` ни на одной странице) — честно [].
        hasTagBrowser: true,
        // НАСТОЯЩИЙ полнотекстовый поиск (`/search?q=`) — в отличие от
        // imhentai, здесь ОДИН парсер на весь сайт, обычный текст находит
        // именно то, что ищешь (подтверждено HAR: "genshin"/"anal" — оба
        // дали реальные релевантные карточки). Пустой запрос → `/search?q=`
        // отдаёт 404 (перепроверено живым curl) — поэтому пустой ввод здесь
        // подставляет главную ленту (`/`), см. fetchIdsBySearch.
        hasSearch: true,
        // Category (`/category/{doujin|manga|comic-hentai|cg-hentai}`) —
        // ОТДЕЛЬНЫЕ несовместимые между собой маршруты (не toggle-битмаска
        // поверх search/tag, как EHentaiCategory/ImhentaiCategory), и ни
        // одного примера в HAR, где категория комбинируется с `?q=`/тегом
        // — честно НЕ утверждаем такую комбинацию, поэтому UI-фильтра
        // здесь нет; сам тип тайтла всё равно виден в карточке (metadata.type).
        hasCategoryFilter: false,
        // Номер страницы — БУКВАЛЬНО путь (`/genre/{slug}/{page}`,
        // `/category/{slug}/{page}`) или query (`/search?q=...&page=N`) —
        // точный переход, перепроверено живым curl. ИСКЛЮЧЕНИЕ: главная
        // лента (`/`) и `/popular` visually НЕ показывают пагинацию и
        // `?page=2` там реально возвращает ТЕ ЖЕ ID, что и страница 1
        // (перепроверено живым curl построчным сравнением) — честно
        // трактуем это как единственную нерасширяемую страницу, см.
        // fetchIdsBySearch(query: "").
        hasPageJump: true,
        // Rising/Popular — ОТДЕЛЬНЫЕ фиксированные топ-N ленты (см.
        // capabilities.hasPageJump doc-comment — `?page=` на них не
        // работает), не сортировка поверх search/tag выдачи — на самих
        // страницах поиска/тега/категории вообще нет `.sorts`-блока в HAR.
        // Честно false, не выдумываем несуществующий UI сортировки.
        hasSortOptions: false,
        // На сайте РЕАЛЬНО есть Favorites/History (пункты меню, кнопка
        // "Add to my favorites" на карточке) — но, как и у остальных
        // внешних сайтов в этом клиенте, интеграция без входа в аккаунт,
        // поэтому здесь всё равно false (тот же принцип, см. doc-comment
        // ImhentaiProvider.capabilities).
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // Ни одного comment-related фрагмента разметки ни на одной
        // сохранённой карточке тайтла в HAR — честно false, не выдумываем.
        hasComments: false
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://hentaipill.com/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://hentaipill.com"

    // MARK: Алфавитный справочник (Tags/Parodies/Characters/Artists)

    private static func tagKindPath(_ kind: ExternalTagKind) -> String? {
        switch kind {
        case .tags: return "genre"
        case .series: return "parody"
        case .characters: return "character"
        case .artists: return "artist"
        // Групп на сайте нет вообще — честно nil, а не выдуманный путь.
        case .groups: return nil
        }
    }

    /// В отличие от hitomi/3hentai/imhentai, здесь список НЕ разбит на
    /// буквы на сервере — ОДИН запрос (`/genre`, `/parody`, `/character`,
    /// `/artist`) отдаёт всё сразу (подтверждено живым curl: `/genre` —
    /// 1526 тегов на одной странице, `/parody` — 3424, БЕЗ пагинации).
    /// `Characters`/`Artists` — сайт САМ ограничивает выдачу первыми ~5000
    /// (17110/24258 заявлено в заголовке "N elements", реально в разметке
    /// только 5002 ссылки, дальше пагинации/ограничения по буквам тоже
    /// нет) — честно неполный список у этих двух разделов, не наша
    /// недоработка, а собственный потолок сайта. letter — фильтруем
    /// ЛОКАЛЬНО из уже скачанного полного списка (namespace.isNumber →
    /// бакет цифр, тот же сигнал, что и у остальных провайдеров).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        guard let basePath = Self.tagKindPath(kind), let url = URL(string: "\(Self.baseURL)/\(basePath)") else { return [] }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            return []
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }
        let all = Self.parseTagList(html: html, basePath: basePath)
        if letter.isNumber {
            return all.filter { $0.slug.first?.isNumber == true }
        }
        let letterString = String(letter).lowercased()
        return all.filter { $0.slug.first.map { String($0) } == letterString }
    }

    /// `<a href="https://hentaipill.com/{basePath}/{slug}">{name}<span>
    /// ({count})</span>` — один и тот же формат на всех четырёх разделах
    /// (genre/parody/character/artist), подтверждено HAR+живым curl.
    /// Отображаемое имя тега genre МОЖЕТ нести суффикс " (female)"/
    /// " (male)" (например "big breasts (female)") — здесь он НЕ срезается
    /// (в отличие от карточки тайтла, см. stripGenderSuffix) — это
    /// самостоятельный пункт алфавитного справочника, ровно как он есть на
    /// сайте, срезка нужна только там, где female/male — отдельный булев
    /// признак (ExternalGalleryTag).
    private static func parseTagList(html: String, basePath: String) -> [ExternalTagEntry] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="https://hentaipill\.com/\#(NSRegularExpression.escapedPattern(for: basePath))/([^"]+)">([^<]+)<span>\((\d+)\)</span>"#
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [ExternalTagEntry] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 4,
                  let slugRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let countRange = Range(match.range(at: 3), in: html),
                  let count = Int(html[countRange]) else { return }
            let slug = String(html[slugRange])
            guard !seen.contains(slug) else { return }
            seen.insert(slug)
            let name = decodeHTMLEntities(String(html[nameRange]))
            result.append(ExternalTagEntry(id: slug, name: name, count: count, slug: slug))
        }
        return result
    }

    /// РЕАЛЬНЫЙ AJAX-эндпоинт `/tag-search-ajax/{tags|characters|parodies}`
    /// подтверждён HAR (POST `query=.../_token=...` → живые совпадения,
    /// подстрокой, не только по префиксу). Но живой curl-тест (31.08:
    /// честный GET → cookie jar → `_token` из скрытого поля HTML → POST с
    /// теми же cookies) всё равно дал "CSRF token mismatch" — токен,
    /// вшитый в ЭТОТ конкретный ответ на GET, судя по всему, не совпадает
    /// с тем, что сервер ожидает для СОХРАНЁННОЙ сессионной куки (два
    /// разных момента инициализации PHP-сессии, разобраться в этом дальше
    /// можно только реальным браузером/DevTools, не curl). Не отправляем
    /// в прод полурабочий код, который будет молча 419-ить на каждый
    /// ввод — честно возвращаем []. fetchTagIndex (полный список одним
    /// запросом, без единой cookie) уже покрывает основной сценарий
    /// подсказок при наборе тега.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: Список тайтлов по тегу/серии/персонажу/автору

    private static func tagBasePath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male: return "genre"
        case .series: return "parody"
        case .character: return "character"
        case .artist: return "artist"
        // Групп на сайте нет — ExternalGalleryDetail.groups здесь ВСЕГДА
        // [] (см. parseDetail), поэтому чип с этим namespace никогда не
        // появится в UI и сюда не попадёт — безопасный фолбэк на "genre".
        case .group: return "genre"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `value` — либо готовый slug (из ExternalTagBrowserView/entry.slug —
    /// уже включает "-female"/"-male" суффикс сам по себе, если он там
    /// нужен), либо чистое отображаемое имя из чипа карточки тайтла
    /// (ExternalGalleryDetailView, namespace .female/.male — тогда суффикс
    /// нужно добавить, см. withGenderSuffix). Формула slugify/суффикса —
    /// та же, что и у 3hentai/imhentai (тот же реальный формат сайта,
    /// подтверждено парами имя→slug из HAR: "dulce-q | q" →
    /// "dulce-q-q", "pokemon | pocket monsters" → "pokemon-pocket-monsters").
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let basePath = Self.tagBasePath(for: namespace)
        let slug = Self.withGenderSuffix(Self.slugify(value), namespace: namespace)
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let page = Int(cursor ?? "1") ?? 1
        var urlString = "\(Self.baseURL)/\(basePath)/\(encodedSlug)"
        if page > 1 { urlString += "/\(page)" }
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
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

    private static func withGenderSuffix(_ slug: String, namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .female where !slug.hasSuffix("-female"): return slug + "-female"
        case .male where !slug.hasSuffix("-male"): return slug + "-male"
        default: return slug
        }
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

    /// Пустой запрос → главная лента `/` — НЕ реально пагинируемая (см.
    /// capabilities.hasPageJump doc-comment, перепроверено живым curl:
    /// `/?page=2` отдаёт ТЕ ЖЕ ID, что и `/`), поэтому здесь честно ВСЕГДА
    /// nextCursor: nil, а запрос дальше первой страницы просто не уходит.
    /// Непустой → `/search?q=...` (перепроверено живым curl: `/search?q=`
    /// пустым — 404, поэтому пустая ветка обязана остаться отдельной).
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let page = Int(cursor ?? "1") ?? 1
        if trimmed.isEmpty {
            guard page == 1 else { return ([], nil) }
            return try await fetchGalleryList(urlString: Self.baseURL, currentPage: 1, allowsNextPage: false)
        }
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        var urlString = "\(Self.baseURL)/search?q=\(encodedQuery)"
        if page > 1 { urlString += "&page=\(page)" }
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Общий разбор страницы выдачи (главная/категория/тег/поиск — везде
    /// одна и та же карточка `<a href=".../gallery/g{id}">...`).
    /// `allowsNextPage: false` — см. fetchIdsBySearch(query: "") doc-comment.
    private func fetchGalleryList(urlString: String, currentPage: Int, allowsNextPage: Bool = true) async throws -> (ids: [Int], nextCursor: String?) {
        guard let url = URL(string: urlString) else { throw HentaiPillError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw HentaiPillError.badResponse
        }
        let ids = Self.parseGalleryIds(html: html)
        let nextCursor = (allowsNextPage && Self.hasNextPage(html: html)) ? String(currentPage + 1) : nil
        return (ids, nextCursor)
    }

    private static func parseGalleryIds(html: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"href="https://hentaipill\.com/gallery/g(\d+)""#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [Int] = []
        var seen = Set<Int>()
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: html),
                  let id = Int(html[idRange]), !seen.contains(id) else { return }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    /// `rel="next"` на кнопке «»» пагинации — подтверждено HAR+живым curl
    /// на category/genre/parody/character/artist/search; ОТСУТСТВУЕТ на
    /// `/`/`/popular` (у них пагинации нет вообще, см. allowsNextPage).
    private static func hasNextPage(html: String) -> Bool {
        html.range(of: #"rel="next""#, options: .regularExpression) != nil
    }

    // MARK: Карточка тайтла

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "\(Self.baseURL)/gallery/g\(id)") else { throw HentaiPillError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw HentaiPillError.badResponse
        }
        return Self.parseDetail(html: html, id: id)
    }

    /// Заголовки блоков метаданных (Parodies:/Characters:/Tags:/Languages:)
    /// НЕ разбираются по тексту — маршрутизация по ПЕРВОМУ сегменту href
    /// (genre/parody/character/artist/language), тот же устойчивый к
    /// локализации приём, что у ImhentaiProvider/ThreeHentaiProvider.
    private static func parseDetail(html: String, id: Int) -> ExternalGalleryDetail {
        let title = firstMatch(in: html, pattern: #"<h1>(.*?)</h1>"#, options: [.dotMatchesLineSeparators])
            .map(stripInnerTags).map(decodeHTMLEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"

        // "2026-08-31 03:08" — сразу за иконкой-часами в шапке, до ссылки
        // на категорию (подтверждено HAR — см. doc-comment типа).
        let posted = firstMatch(
            in: html,
            pattern: #"reading-page-header-data">\s*<span>[\s\S]*?</svg>([^<]+)</span>"#
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let type = firstMatch(in: html, pattern: #"href="https://hentaipill\.com/category/[^"]+">([^<]+)</a>"#)
            .map(decodeHTMLEntities) ?? ""

        // Разбор тегов/пародий/персонажей/языка — ТОЛЬКО в области ДО начала
        // самих страниц чтения, иначе следом идущий блок "You may also like"
        // (свой собственный tag-list с чужими похожими тайтлами, если бы он
        // оказался ДО reading-pages-content — не тот случай здесь, но
        // граница всё равно нужна) замешался бы в метаданные ЭТОГО тайтла.
        let metaEnd = html.range(of: "reading-pages-content")?.lowerBound ?? html.endIndex
        let metaHTML = String(html[html.startIndex..<metaEnd])

        var series: [String] = []
        var characters: [String] = []
        var artists: [String] = []
        var languageParts: [String] = []
        var tags: [ExternalGalleryTag] = []

        if let regex = try? NSRegularExpression(
            pattern: #"href="https://hentaipill\.com/(genre|parody|character|artist|language)/[^"]+">([^<]+)</a>"#
        ) {
            let range = NSRange(metaHTML.startIndex..., in: metaHTML)
            regex.enumerateMatches(in: metaHTML, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 3,
                      let sectionRange = Range(match.range(at: 1), in: metaHTML),
                      let nameRange = Range(match.range(at: 2), in: metaHTML) else { return }
                let section = String(metaHTML[sectionRange])
                let rawName = decodeHTMLEntities(String(metaHTML[nameRange]))
                switch section {
                case "parody": series.append(rawName)
                case "character": characters.append(rawName)
                case "artist": artists.append(rawName)
                case "language": languageParts.append(rawName)
                case "genre":
                    let stripped = stripGenderSuffix(rawName)
                    tags.append(ExternalGalleryTag(name: stripped.name, female: stripped.female, male: stripped.male))
                default: break
                }
            }
        }

        // Картинки — уже ГОТОВЫЕ абсолютные URL прямо в разметке (см.
        // doc-comment типа) — никакой формулы/CDN-шардирования не нужно, в
        // отличие от hitomi/e-hentai/3hentai/imhentai. width/height — тоже
        // прямо в атрибутах, полезно читалке для расчёта раскладки заранее.
        var pages: [ExternalGalleryPage] = []
        if let regex = try? NSRegularExpression(
            pattern: #"<img class="lazy reading-pages-single-page" data-src="([^"]+)" width="(\d+)" height="(\d+)""#
        ) {
            let range = NSRange(html.startIndex..., in: html)
            var index = 0
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 4,
                      let urlRange = Range(match.range(at: 1), in: html),
                      let wRange = Range(match.range(at: 2), in: html),
                      let hRange = Range(match.range(at: 3), in: html),
                      let width = Int(html[wRange]), let height = Int(html[hRange]) else { return }
                index += 1
                pages.append(ExternalGalleryPage(
                    index: index, key: String(html[urlRange]), width: width, height: height,
                    thumbnailURL: nil, thumbnailSpriteOffsetX: nil
                ))
            }
        }

        // `cover: "https://b1.hentaipill.me/picture/{id}-thumb.jpg"` — JS-
        // переменная в начале страницы, тот же CDN-хост, что и у страниц
        // чтения (см. doc-comment типа насчёт плавающего домена/TLD).
        let coverURL = firstMatch(in: html, pattern: #"cover:\s*"([^"]+)""#).flatMap { URL(string: $0) }

        // "You may also like" — та же карточная разметка, что у обычной
        // сетки (см. parseGalleryIds), просто в своём блоке в конце
        // страницы — берём всё, что нашлось ПОСЛЕ метки, без искусственного
        // потолка (сам блок на сайте и так ограничен разумным числом карточек).
        var related: [Int] = []
        if let markerRange = html.range(of: "You may also like") {
            related = parseGalleryIds(html: String(html[markerRange.upperBound...]))
        }

        return ExternalGalleryDetail(
            id: id,
            site: .hentaiPill,
            title: title,
            type: type,
            language: languageParts.isEmpty ? nil : languageParts.joined(separator: ", "),
            tags: tags,
            artists: artists,
            // Групп на сайте нет вообще — честно пусто, не выдумываем.
            groups: [],
            characters: characters,
            series: series,
            related: related,
            pages: pages,
            coverURL: coverURL,
            posted: posted,
            // e-hentai-специфичные поля (Parent/Visible/File Size/Rating) —
            // у hentaipill не подтверждены, честно nil, не выдумываем.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: nil,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    /// "big breasts (female)" → ("big breasts", true, false); "sole female"
    /// → ("sole female", false, false) — суффикс срезается ТОЛЬКО когда это
    /// уточнение в скобках, не когда "female"/"male" — часть САМОГО имени
    /// тега без скобок (это разные, реально существующие теги сайта, см.
    /// /genre полный список — "sole female"/"sole male" там отдельные
    /// пункты, не female/male-варианты чего-то ещё).
    private static func stripGenderSuffix(_ name: String) -> (name: String, female: Bool, male: Bool) {
        if let range = name.range(of: #"\s*\(female\)\s*$"#, options: .regularExpression) {
            return (String(name[name.startIndex..<range.lowerBound]), true, false)
        }
        if let range = name.range(of: #"\s*\(male\)\s*$"#, options: .regularExpression) {
            return (String(name[name.startIndex..<range.lowerBound]), false, true)
        }
        return (name, false, false)
    }

    // MARK: URL картинок

    /// Без сети — `page.key` уже несёт ГОТОВЫЙ абсолютный URL, взятый прямо
    /// из HTML карточки на момент fetchGalleryDetail (см. её doc-comment
    /// насчёт плавающего CDN-домена/TLD — намеренно не пересчитывается
    /// здесь заново).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: page.key) else { throw HentaiPillError.badResponse }
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
