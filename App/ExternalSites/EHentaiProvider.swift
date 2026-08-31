import Foundation

/// Ошибки EHentaiProvider — та же намеренно простая схема, что у HitomiError.
enum EHentaiError: Error {
    case badResponse
    case missingToken
}

/// Расширенные поля поиска — по прямой просьбе (01.09). У e-hentai, в
/// отличие от остальных сайтов, `namespace:value`-команда — это ПРЯМОЙ
/// синтаксис самого f_search (подтверждено HAR: `f_search=anal+anime+
/// series%3Agenshin` — обычный текст и тег-команда в одном запросе сразу,
/// см. EHentaiProvider.tagPrefix doc-comment) — поэтому `encoded()` здесь
/// НЕ нужен приватный разделитель-канал, как у SimplyHentaiAdvancedQuery:
/// результат — это уже готовый, реальный f_search-текст, который можно
/// слать как есть.
///
/// ЭКСКЛЮЗИВНАЯ схема, единая для всех сайтов с расширенными полями (см.
/// ExternalSearchView.resolvedQuery): если хотя бы одно поле здесь
/// заполнено (включая собственный search), общее поле поиска экрана для
/// e-hentai перестаёт участвовать — запрос строится ТОЛЬКО из этих полей.
///
/// Многословные значения ВНУТРИ f_search-команды (`parody:"kimi no na
/// wa$"` — так делают публичные гайды по сайту) HAR не подтверждает — по
/// аналогии с обычным словом заменяем пробел на `+` (та же формула, что и
/// в EHentaiProvider.formEncoded для остального f_search), это
/// ПРЕДПОЛОЖЕНИЕ по симметрии с подтверждённым путём `/tag/other:nudity+
/// only`, не отдельно подтверждено именно внутри f_search-команды.
struct EHentaiAdvancedQuery {
    var search: String = ""
    var tags: [String] = []
    var series: [String] = []
    var characters: [String] = []
    var artists: [String] = []
    var groups: [String] = []

    var isEmpty: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty
            && tags.isEmpty && series.isEmpty && characters.isEmpty && artists.isEmpty && groups.isEmpty
    }

    /// Вызывается ТОЛЬКО когда !isEmpty (см. ExternalSearchView.resolvedQuery)
    /// — собственный search заменяет общее поле экрана, а не складывается с ним.
    func encoded() -> String {
        var parts = [search.trimmingCharacters(in: .whitespaces)]
        func append(_ namespace: String, _ values: [String]) {
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                parts.append("\(namespace):\(trimmed.replacingOccurrences(of: " ", with: "+"))")
            }
        }
        append("other", tags)
        append("parody", series)
        append("character", characters)
        append("artist", artists)
        append("group", groups)
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Категории e-hentai (кнопки Doujinshi/Manga/Artist CG/... на главной
/// странице сайта — см. EHentaiCategoryPicker) и их `f_cats` bitmask.
/// Подтверждено HAR: `f_cats=1019` встречался в реальном запросе, и
/// 1019 = сумма ВСЕХ битов ниже КРОМЕ .manga (4) — т.е. семантика bitmask
/// это ИСКЛЮЧЕНИЕ (галочка = категория выключена из выдачи), не включение;
/// когда ничего не исключено, сайт вообще не шлёт f_cats (см.
/// EHentaiProvider.fetchIdsBySearch(excludedCategoryBits:) — 0 значит
/// "без параметра").
enum EHentaiCategory: CaseIterable, Identifiable {
    case doujinshi, manga, artistCG, gameCG, western, nonH, imageSet, cosplay, asianPorn, misc

    var id: Self { self }

    var bit: Int {
        switch self {
        case .doujinshi: return 2
        case .manga: return 4
        case .artistCG: return 8
        case .gameCG: return 16
        case .imageSet: return 32
        case .cosplay: return 64
        case .asianPorn: return 128
        case .nonH: return 256
        case .western: return 512
        case .misc: return 1
        }
    }

    var displayName: String {
        switch self {
        case .doujinshi: return "Doujinshi"
        case .manga: return "Manga"
        case .artistCG: return "Artist CG"
        case .gameCG: return "Game CG"
        case .western: return "Western"
        case .nonH: return "Non-H"
        case .imageSet: return "Image Set"
        case .cosplay: return "Cosplay"
        case .asianPorn: return "Asian Porn"
        case .misc: return "Misc"
        }
    }
}

/// Клиент e-hentai.org — СВОЯ, полностью отдельная реализация, никак не
/// связанная с MangaNetworkService/LibSite/HitomiProvider. Все URL/форматы
/// ниже подтверждены реальным HAR (см. план — "e-hentai" блок разбора).
///
/// `actor`, не `struct` (в отличие от HitomiProvider): нужен реальный
/// мутируемый стейт МЕЖДУ вызовами — кэш gid→token (см. tokenCache ниже),
/// без которого fetchGalleryDetail(id:) невозможен (у e-hentai галерея
/// адресуется ПАРОЙ (gid, token), не одним числом — токен узнаём только из
/// ссылок на странице выдачи/поиска, откуда и кэшируем). `actor` сериализует
/// конкурентный доступ к этому кэшу безопасно; `site`/`capabilities`
/// объявлены `nonisolated let`, чтобы читаться синхронно из SwiftUI-кода
/// (как у HitomiProvider), не требуя await на каждый чих.
actor EHentaiProvider: ExternalSiteProvider {
    nonisolated let site: ExternalSite = .ehentai
    nonisolated let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // Алфавитного справочника тегов у e-hentai нет (в отличие от
        // hitomi.la) — зато есть обычный полнотекстовый поиск, см. hasSearch.
        hasTagBrowser: false,
        hasSearch: true,
        hasCategoryFilter: true,
        // Приблизительный (не точный offset, см. cursorForPage) — но
        // реальный, подтверждён HAR (`range=`), см. paginationQueryItem.
        hasPageJump: true,
        // Ни в HAR, ни на самой странице поиска e-hentai нет видимого
        // пользовательского контрола сортировки выдачи (в отличие от
        // hitomi — см. HitomiProvider.SortOption) — честно false, не
        // выдумываем.
        hasSortOptions: false,
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        hasComments: false
    )

    /// Отдельная сессия — своя, не пересекается ни с HitomiProvider.session,
    /// ни тем более с MangaNetworkService. `Cookie: nw=1` — подтверждено
    /// живым HAR (30.08, ProxyPin830_18_35_43.har): страница тайтла
    /// `/g/{id}/{token}/` без этой куки отдаёт НЕ реальный контент, а
    /// промежуточную страницу "Content Warning" (для галерей, помеченных
    /// как "Offensive For Everyone" — у e-hentai таких прилично, любой
    /// поиск с scat/guro/т.п. категориями почти гарантированно на них
    /// натыкается) с двумя ссылками `?nw=session`/`?nw=always` ("Never Warn
    /// Me Again") — обе просто СТАВЯТ эту куку (`Set-Cookie: nw=1`) и
    /// редиректят обратно на ту же страницу, уже с реальной разметкой.
    /// Без неё parseMetadata/parsePages молча находят 0 совпадений на
    /// странице-предупреждении (там нет ни gdt1/gdt2, ни тегов, ни ссылок
    /// на страницы) — отсюда "не грузит тайтл"/пустая обложка-скелетон в
    /// сетке каталога/пустой превью-грид у ЛЮБОЙ помеченной так галереи.
    /// Ставим куку СРАЗУ на все запросы сессии — тот же эффект, что и один
    /// клик "Never Warn Me Again", просто заранее, без отдельного разбора
    /// warning-страницы и редиректа на каждую такую галерею.
    nonisolated private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://e-hentai.org/",
            "Cookie": "nw=1"
        ]
        return URLSession(configuration: config)
    }()

    /// gid → token, накапливается по мере того как галереи встречаются в
    /// выдаче (тег/поиск) — карточка тайтла адресуется ОБЕИМИ частями
    /// (см. doc-comment типа), без токена fetchGalleryDetail не может
    /// построить канонический URL `/g/{gid}/{token}/`.
    private var tokenCache: [Int: String] = [:]

    // MARK: Алфавитный справочник — не подтверждён у e-hentai, честно пусто.

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        []
    }

    /// Автокомплит e-hentai не подтверждён HAR — честно пусто (как и
    /// hasTagBrowser, см. capabilities).
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: Список тайтлов по тегу/поиску

    /// У e-hentai НЕТ отдельной "фичи поиска по тегам" — есть ОДНА строка
    /// поиска (f_search), а `namespace:value` — просто КОМАНДА внутри неё
    /// (подтверждено HAR: `f_search=anal+anime+series%3Agenshin` — обычный
    /// текст и тег-команда в одном и том же запросе одновременно). У
    /// `/tag/{ns}:{value}` — это просто то, что открывается по клику на
    /// готовую тег-ссылку в разметке (тоже подтверждено HAR, отдельно от
    /// f_search), удобный короткий путь для ОДНОГО тега без лишнего текста
    /// — оставлен отдельным методом протокола, а не свёрнут в
    /// fetchIdsBySearch, ТОЛЬКО потому что многословные значения тега
    /// (`nudity only`, `textless narrative`) подтверждены именно в этой
    /// форме (`+` вместо пробела прямо в пути); синтаксис кавычек для
    /// многословного тега ВНУТРИ f_search (`parody:"kimi no na wa$"` и
    /// т.п. — так делают публичные гайды по сайту) HAR не подтверждает,
    /// поэтому не рискуем угадывать его здесь.
    private static func tagPrefix(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag: return "other"
        case .female: return "female"
        case .male: return "male"
        case .character: return "character"
        case .artist: return "artist"
        case .group: return "group"
        case .series: return "parody"
        }
    }

    /// e-hentai кодирует пробел как `+` (форма `application/x-www-form-
    /// urlencoded`), НЕ `%20` — подтверждено HAR и в query (`f_search=anal
    /// +anime`), и прямо в пути (`/tag/other:nudity+only`). `.urlPathAllowed`/
    /// `.urlQueryAllowed` сами по себе дают `%20`, поэтому пробел заменяется
    /// на `+` вручную ДО percent-encoding остального (encoding сохраняет уже
    /// вставленный `+` как есть — он входит в `.urlQueryAllowed`).
    private static func formEncoded(_ text: String) -> String {
        let withPlus = text.replacingOccurrences(of: " ", with: "+")
        return withPlus.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? withPlus
    }

    /// Синтезирует прыжковый курсор (см. paginationQueryItem ниже) — просто
    /// заворачивает номер страницы как есть в будущий `range=`,
    /// приблизительно (нет точной формулы страница→range). `nonisolated` —
    /// протокол объявляет этот метод СИНХРОННЫМ (без async, как site/
    /// capabilities), а актор по умолчанию изолирует даже такие методы;
    /// чистое вычисление без обращения к tokenCache/session, изоляция не
    /// нужна — без этого сборка падает ("crosses into actor-isolated code").
    nonisolated func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return "page:\(page)"
    }

    /// Курсор — либо ОБЫЧНЫЙ, тот, что вернул прошлый вызов (id последнего
    /// тайтла текущей страницы, идёт в `&next=` — стандартная пагинация
    /// сайта), либо СПЕЦИАЛЬНЫЙ, синтезированный самим клиентом для прыжка
    /// на произвольную страницу (см. cursorForPage выше) — с префиксом
    /// `page:`, идёт в `&range=`. `range=N` подтверждён HAR (второй HAR
    /// про сортировку/переход): реально меняет позицию в выдаче (запрос с
    /// `range=68` вернул совсем другой диапазон id тайтлов, чем без него) —
    /// это и есть механизм кнопки "Jump/Seek" на самом сайте, просто
    /// подставляет введённое число прямо в этот параметр. ТОЧНАЯ формула
    /// перевода "номер страницы" → конкретное значение range не подтверждена
    /// (сайт явно не считает это как offset/limit) — трактуем как
    /// приблизительный переход, не гарантируем показ РОВНО той же страницы,
    /// что была бы при обычной постраничной пагинации с начала.
    private static func paginationQueryItem(for cursor: String) -> String {
        if cursor.hasPrefix("page:"), let page = Int(cursor.dropFirst(5)) {
            return "range=\(page)"
        }
        return "next=\(cursor)"
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let prefix = Self.tagPrefix(for: namespace)
        let encodedValue = Self.formEncoded(value.lowercased())
        var urlString = "https://e-hentai.org/tag/\(prefix):\(encodedValue)"
        if let cursor { urlString += "?" + Self.paginationQueryItem(for: cursor) }
        return try await fetchGalleryList(urlString: urlString)
    }

    /// Обычный полнотекстовый поиск по всему сайту (`?f_search=`) — то,
    /// чего у hitomi нет (см. HitomiProvider.fetchIdsBySearch — заглушка).
    /// Пользователь может ввести сюда И свободный текст, И `ns:value`-
    /// команду, хоть вперемешку (см. doc-comment tagPrefix) — здесь это
    /// не различается, просто честно прокидывается как есть.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, cursor: cursor, limit: limit)
    }

    /// Пустой запрос — просто главная страница (см. HAR: `GET https://
    /// e-hentai.org/` без единого параметра — та же самая "последние
    /// загруженные" лента, что видна в браузере) — по тому же принципу
    /// «Recently», что и у hitomi (см. HitomiProvider.fetchIdsBySearch).
    /// `excludedCategoryBits` — см. EHentaiCategory (bitmask ИСКЛЮЧАЕМЫХ
    /// категорий, подтверждено HAR). 0 — параметр `f_cats` вообще не
    /// добавляется в URL, ровно как на самом сайте, когда ни одна кнопка
    /// категории не выключена.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var params: [String] = []
        if !trimmed.isEmpty { params.append("f_search=\(Self.formEncoded(trimmed))") }
        if excludedCategoryBits != 0 { params.append("f_cats=\(excludedCategoryBits)") }
        if let cursor { params.append(Self.paginationQueryItem(for: cursor)) }
        let urlString = params.isEmpty ? "https://e-hentai.org/" : "https://e-hentai.org/?" + params.joined(separator: "&")
        return try await fetchGalleryList(urlString: urlString)
    }

    /// Общий разбор страницы выдачи (тег ИЛИ поиск — одна и та же разметка):
    /// вытаскивает пары (gid, token) из ссылок на карточки, кладёт в
    /// tokenCache (иначе fetchGalleryDetail не сможет собрать URL), и
    /// вытаскивает курсор следующей страницы из `&next=`-ссылки пагинации.
    private func fetchGalleryList(urlString: String) async throws -> (ids: [Int], nextCursor: String?) {
        guard let url = URL(string: urlString) else { throw EHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw EHentaiError.badResponse
        }

        var ids: [Int] = []
        if let regex = try? NSRegularExpression(pattern: #"href="https://e-hentai\.org/g/(\d+)/([0-9a-f]+)/""#) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 3,
                      let gidRange = Range(match.range(at: 1), in: html),
                      let tokenRange = Range(match.range(at: 2), in: html),
                      let gid = Int(html[gidRange]) else { return }
                let token = String(html[tokenRange])
                // Дубли: карточка в выдаче содержит несколько ссылок на один
                // и тот же gid (превью + заголовок) — берём первую, не
                // дублируем id в результирующем списке.
                if ids.last != gid { ids.append(gid) }
                tokenCache[gid] = token
            }
        }

        var nextCursor: String?
        if let regex = try? NSRegularExpression(pattern: #"[?&]next=(\d+)"#) {
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 2,
               let cursorRange = Range(match.range(at: 1), in: html) {
                nextCursor = String(html[cursorRange])
            }
        }
        return (ids, nextCursor)
    }

    // MARK: Карточка тайтла

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let token = tokenCache[id] else { throw EHentaiError.missingToken }
        let html = try await fetchHTML(urlString: "https://e-hentai.org/g/\(id)/\(token)/")
        let metadata = Self.parseMetadata(html: html)
        var pages = Self.parsePages(from: html)

        // Полоса миниатюр страниц отдаётся кусками ~20 штук за раз (см.
        // ?p=N внизу карточки) — базовый /g/{id}/{token}/ БЕЗ ?p= отдаёт
        // только первые ~20, подтверждено HAR (галерея на 67 страниц:
        // "Length: 67 pages" в метаданных, но только 20 ссылок /s/... в
        // самом ответе; ?p=1/?p=2/?p=3 добавляют следующие ~20 каждая).
        // Без этой дотяжки чтение молча обрывалось бы на 20-й странице у
        // любой достаточно длинной галереи.
        var pageIndex = 1
        while pages.count < metadata.totalPages, pageIndex < 64 {
            guard let moreHTML = try? await fetchHTML(urlString: "https://e-hentai.org/g/\(id)/\(token)/?p=\(pageIndex)") else { break }
            let morePages = Self.parsePages(from: moreHTML)
            guard !morePages.isEmpty else { break }
            let existingIndices = Set(pages.map(\.index))
            let newPages = morePages.filter { !existingIndices.contains($0.index) }
            guard !newPages.isEmpty else { break }
            pages.append(contentsOf: newPages)
            pageIndex += 1
        }
        pages.sort { $0.index < $1.index }

        return ExternalGalleryDetail(
            id: id,
            site: .ehentai,
            title: metadata.title,
            type: metadata.type,
            language: metadata.language,
            tags: metadata.tags,
            artists: metadata.artists,
            groups: metadata.groups,
            characters: metadata.characters,
            series: metadata.series,
            // Похожие тайтлы на странице e-hentai — не отдельный список ID
            // (как related у hitomi), а карточки с собственными gid/token —
            // не подтверждено разбором, честно пусто (см. план "чего не хватает").
            related: [],
            pages: pages,
            coverURL: metadata.coverURL,
            posted: metadata.posted,
            parentId: metadata.parentId,
            visible: metadata.visible,
            fileSize: metadata.fileSize,
            favoritedCount: metadata.favoritedCount,
            ratingAverage: metadata.ratingAverage,
            ratingCount: metadata.ratingCount,
            comments: metadata.comments
        )
    }

    private func fetchHTML(urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw EHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw EHentaiError.badResponse
        }
        return html
    }

    /// Всё, что не относится к списку страниц — то, ради чего нет смысла
    /// заново парсить тег/автора/обложку на КАЖДОМ ?p=N-довеске (см.
    /// fetchGalleryDetail): достаточно вызвать один раз на базовой странице.
    private struct GalleryMetadata {
        let title: String
        let type: String
        let language: String?
        let coverURL: URL?
        let tags: [ExternalGalleryTag]
        let artists: [String]
        let groups: [String]
        let characters: [String]
        let series: [String]
        /// Из `<td class="gdt1">Length:</td><td class="gdt2">67 pages</td>`
        /// — сколько СТРАНИЦ ТАЙТЛА всего (не то же самое, что число ?p=N
        /// довесок полосы миниатюр — она просто их источник).
        let totalPages: Int
        /// Ниже — поля из тех же `gdt1`/`gdt2` строк метатаблицы + виджета
        /// рейтинга (`#gdr`) + блока комментариев (`#cdiv`), подтверждены
        /// реальной разметкой (`eh_detail.html` из HAR этой сессии), см.
        /// план ЧАСТЬ B.2/B.5. У hitomi таких полей нет вообще — это чисто
        /// e-hentai-специфичный набор.
        let posted: String?
        let parentId: Int?
        let visible: String?
        let fileSize: String?
        let favoritedCount: String?
        let ratingAverage: Double?
        let ratingCount: Int?
        let comments: [ExternalComment]
    }

    private static func parseMetadata(html: String) -> GalleryMetadata {
        let title = firstMatch(in: html, pattern: #"<h1 id="gn">([^<]*)</h1>"#).map(decodeHTMLEntities) ?? "Untitled"
        let type = firstMatch(in: html, pattern: #"<div id="gdc"><div class="cs [^"]+"[^>]*>([^<]+)</div>"#) ?? "Misc"
        let language = firstMatch(in: html, pattern: #"<td[^>]*>Language:</td><td[^>]*>([^<]+?)(?:\s*<span[^>]*>[^<]*</span>)?</td>"#).map(decodeHTMLEntities)
        let coverURL = firstMatch(in: html, pattern: #"(https://ehgt\.org/[^"'\s]+\.(?:jpg|jpeg|png|webp))"#).flatMap(URL.init(string:))
        let totalPages = firstMatch(in: html, pattern: #"<td class="gdt2">(\d+) pages</td>"#).flatMap(Int.init) ?? 0

        var tags: [ExternalGalleryTag] = []
        var artists: [String] = []
        var groups: [String] = []
        var characters: [String] = []
        var series: [String] = []

        if let regex = try? NSRegularExpression(
            pattern: #"<td class="tc">([a-z]+):</td>\s*<td>(.*?)</td>\s*</tr>"#,
            options: [.dotMatchesLineSeparators]
        ) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 3,
                      let nsRange = Range(match.range(at: 1), in: html),
                      let bodyRange = Range(match.range(at: 2), in: html) else { return }
                let ns = String(html[nsRange])
                let body = String(html[bodyRange])
                let names = extractLinkTexts(from: body)
                switch ns {
                case "artist": artists.append(contentsOf: names)
                case "group": groups.append(contentsOf: names)
                case "character": characters.append(contentsOf: names)
                case "parody": series.append(contentsOf: names)
                case "female": tags.append(contentsOf: names.map { ExternalGalleryTag(name: $0, female: true, male: false) })
                case "male": tags.append(contentsOf: names.map { ExternalGalleryTag(name: $0, female: false, male: true) })
                default: tags.append(contentsOf: names.map { ExternalGalleryTag(name: $0, female: false, male: false) })
                }
            }
        }

        let posted = firstMatch(in: html, pattern: #"<td class="gdt1">Posted:</td><td class="gdt2">([^<]+)</td>"#).map { $0.trimmingCharacters(in: .whitespaces) }
        let parentId = firstMatch(in: html, pattern: #"<td class="gdt1">Parent:</td><td class="gdt2"><a href="https://e-hentai\.org/g/(\d+)/"#).flatMap(Int.init)
        let visible = firstMatch(in: html, pattern: #"<td class="gdt1">Visible:</td><td class="gdt2">([^<]+)</td>"#).map { $0.trimmingCharacters(in: .whitespaces) }
        let fileSize = firstMatch(in: html, pattern: #"<td class="gdt1">File Size:</td><td class="gdt2">([^<]+)</td>"#).map { $0.trimmingCharacters(in: .whitespaces) }
        let favoritedCount = firstMatch(in: html, pattern: #"<td class="gdt2" id="favcount">([^<]+)</td>"#).map { $0.trimmingCharacters(in: .whitespaces) }
        let ratingAverage = firstMatch(in: html, pattern: #"id="rating_label"[^>]*>Average: ([\d.]+)"#).flatMap(Double.init)
        let ratingCount = firstMatch(in: html, pattern: #"id="rating_count">(\d+)"#).flatMap(Int.init)

        return GalleryMetadata(
            title: title, type: type, language: language, coverURL: coverURL,
            tags: tags, artists: artists, groups: groups, characters: characters, series: series,
            totalPages: totalPages,
            posted: posted, parentId: parentId, visible: visible, fileSize: fileSize,
            favoritedCount: favoritedCount, ratingAverage: ratingAverage, ratingCount: ratingCount,
            comments: parseComments(from: html)
        )
    }

    /// `<a name="c{id}"></a>...<div class="c3">Posted on {дата} by: ...
    /// <a href=".../uploader/...">{автор}</a>...</div>...<div class="c6"
    /// id="comment_{id}">{текст}</div>` — подтверждено реальной разметкой
    /// (`eh_detail.html`, HAR этой сессии), см. план ЧАСТЬ B.5. `.*?`
    /// ленивые — останавливаются на ПЕРВОМ совпадении внутри блока именно
    /// этого комментария (по одному "by:"/`c6` на комментарий).
    private static func parseComments(from html: String) -> [ExternalComment] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a name="c(\d+)"></a>.*?<div class="c3">Posted on (.*?) by:.*?<a href="https://e-hentai\.org/uploader/[^"]*">([^<]+)</a>.*?<div class="c6"[^>]*>(.*?)</div>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [ExternalComment] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 5,
                  let idRange = Range(match.range(at: 1), in: html),
                  let id = Int(html[idRange]),
                  let dateRange = Range(match.range(at: 2), in: html),
                  let authorRange = Range(match.range(at: 3), in: html),
                  let textRange = Range(match.range(at: 4), in: html) else { return }
            let rawText = String(html[textRange]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            result.append(ExternalComment(
                id: id,
                author: decodeHTMLEntities(String(html[authorRange])),
                postedAt: String(html[dateRange]),
                text: decodeHTMLEntities(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return result
    }

    /// Миниатюры страниц из ОДНОГО ответа (базового /g/{id}/{token}/ ИЛИ
    /// любого его ?p=N-довеска — разметка одинаковая, см. fetchGalleryDetail).
    /// Заодно вытаскивает `thumbnailURL` — реальный CSS background-image
    /// URL полосы миниатюр (`<div style="...url(https://.../{id}-{n}.webp)...">`,
    /// (без кавычек внутри url(), подтверждено HAR), см. план ЧАСТЬ B.3.
    /// ВАЖНО: миниатюры e-hentai — НЕ отдельная картинка на страницу. Одна
    /// полоса (?p=N-довесок, ~20 страниц) отдаёт ОДИН общий "спрайт" +
    /// CSS `background-position`, вырезающий нужный тайл — подтверждено
    /// побайтово реальной разметкой:
    /// `<a href=".../s/{key}/{gid}-{n}"><div title="Page N: ..."
    /// style="width:200px;height:278px;background:transparent
    /// url(.../{gid}-{p}.webp) -200px 0 no-repeat"></div></a>` — 20
    /// СОСЕДНИХ страниц ссылаются на ОДИН И ТОТ ЖЕ url(...), офсет растёт
    /// на 200 (=ширина тайла) на каждую. Раньше офсет не учитывался вовсе
    /// — из-за этого превью-грид карточки тайтла показывал один и тот же
    /// (нецелевой, необрезанный) спрайт на КАЖДОЙ странице партии — то и
    /// была жалоба "одна картинка много раз + сетка кривая" (нецелевой
    /// широкий спрайт, натянутый на узкий тайл через scaledToFill,
    /// выглядит перекошенным). См. ExternalSpriteThumbnail
    /// (App/Views/ExternalSites/ExternalImage.swift) — там реальный кроп.
    /// width/height тайла (200×278 и т.п., варьируются по странице) заодно
    /// используются как width/height страницы — раньше здесь были 0/0
    /// ("размер неизвестен"), а это разумное приближение реальных пропорций
    /// (плейсхолдер в читалке/расчёт высоты при "по ширине" теперь чуть точнее).
    private static func parsePages(from html: String) -> [ExternalGalleryPage] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="https://e-hentai\.org/s/([0-9a-f]+)/\d+-(\d+)"><div[^>]*style="width:(\d+)px;height:(\d+)px;background:transparent url\(([^)]+)\)\s*(-?\d+)px"#
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<Int>()
        var pages: [ExternalGalleryPage] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 7,
                  let keyRange = Range(match.range(at: 1), in: html),
                  let indexRange = Range(match.range(at: 2), in: html),
                  let index = Int(html[indexRange]), !seen.contains(index),
                  let widthRange = Range(match.range(at: 3), in: html),
                  let heightRange = Range(match.range(at: 4), in: html),
                  let thumbRange = Range(match.range(at: 5), in: html),
                  let offsetRange = Range(match.range(at: 6), in: html) else { return }
            seen.insert(index)
            let tileWidth = Int(html[widthRange]) ?? 0
            let tileHeight = Int(html[heightRange]) ?? 0
            let offsetX = abs(Int(html[offsetRange]) ?? 0)
            pages.append(ExternalGalleryPage(
                index: index, key: String(html[keyRange]), width: tileWidth, height: tileHeight,
                thumbnailURL: URL(string: String(html[thumbRange])),
                thumbnailSpriteOffsetX: offsetX
            ))
        }
        return pages
    }

    /// `<td class="tc">ns:</td><td><a href=...>Name</a> <a ...>Name 2</a></td>`
    /// — вытащить тексты всех `<a>` внутри блока одного неймспейса.
    private static func extractLinkTexts(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<a[^>]*>([^<]+)</a>"#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [String] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 2,
                  let textRange = Range(match.range(at: 1), in: html) else { return }
            result.append(decodeHTMLEntities(String(html[textRange])))
        }
        return result
    }

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 2,
              let matchRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[matchRange])
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: URL страницы чтения

    /// РЕАЛЬНЫЙ сетевой запрос каждый раз (в отличие от hitomi's чистой
    /// формулы) — H@H-ссылка на картинку временная, с истекающим keystamp,
    /// её нельзя посчитать заранее и нельзя закэшировать надолго (см. план).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: "https://e-hentai.org/s/\(page.key)/\(galleryId)-\(page.index)") else {
            throw EHentaiError.badResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw EHentaiError.badResponse
        }
        guard let imageURLString = Self.firstMatch(in: html, pattern: #"id="img"\s+src="([^"]+)""#),
              let imageURL = URL(string: imageURLString) else {
            throw EHentaiError.badResponse
        }
        return imageURL
    }
}
