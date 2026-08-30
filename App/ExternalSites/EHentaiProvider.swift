import Foundation

/// Ошибки EHentaiProvider — та же намеренно простая схема, что у HitomiError.
enum EHentaiError: Error {
    case badResponse
    case missingToken
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
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        hasComments: false
    )

    /// Отдельная сессия — своя, не пересекается ни с HitomiProvider.session,
    /// ни тем более с MangaNetworkService.
    nonisolated private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://e-hentai.org/"
        ]
        return URLSession(configuration: config)
    }()

    /// gid → token, накапливается по мере того как галереи встречаются в
    /// выдаче (тег/поиск) — карточка тайтла адресуется ОБЕИМИ частями
    /// (см. doc-comment типа), без токена fetchGalleryDetail не может
    /// построить канонический URL `/g/{gid}/{token}/`.
    private var tokenCache: [Int: String] = [:]

    // MARK: Алфавитный справочник — не подтверждён у e-hentai, честно пусто.

    func fetchTagIndex(kind: ExternalTagKind, letter: Character) async throws -> [ExternalTagEntry] {
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

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let prefix = Self.tagPrefix(for: namespace)
        let encodedValue = Self.formEncoded(value.lowercased())
        var urlString = "https://e-hentai.org/tag/\(prefix):\(encodedValue)"
        if let cursor { urlString += "?next=\(cursor)" }
        return try await fetchGalleryList(urlString: urlString)
    }

    /// Обычный полнотекстовый поиск по всему сайту (`?f_search=`) — то,
    /// чего у hitomi нет (см. HitomiProvider.fetchIdsBySearch — заглушка).
    /// Пользователь может ввести сюда И свободный текст, И `ns:value`-
    /// команду, хоть вперемешку (см. doc-comment tagPrefix) — здесь это
    /// не различается, просто честно прокидывается как есть.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let encodedQuery = Self.formEncoded(query)
        var urlString = "https://e-hentai.org/?f_search=\(encodedQuery)"
        if let cursor { urlString += "&next=\(cursor)" }
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
            coverURL: metadata.coverURL
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

        return GalleryMetadata(
            title: title, type: type, language: language, coverURL: coverURL,
            tags: tags, artists: artists, groups: groups, characters: characters, series: series,
            totalPages: totalPages
        )
    }

    /// Миниатюры страниц из ОДНОГО ответа (базового /g/{id}/{token}/ ИЛИ
    /// любого его ?p=N-довеска — разметка одинаковая, см. fetchGalleryDetail).
    private static func parsePages(from html: String) -> [ExternalGalleryPage] {
        guard let regex = try? NSRegularExpression(pattern: #"href="https://e-hentai\.org/s/([0-9a-f]+)/\d+-(\d+)""#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<Int>()
        var pages: [ExternalGalleryPage] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: html),
                  let indexRange = Range(match.range(at: 2), in: html),
                  let index = Int(html[indexRange]), !seen.contains(index) else { return }
            seen.insert(index)
            pages.append(ExternalGalleryPage(index: index, key: String(html[keyRange]), width: 0, height: 0))
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
