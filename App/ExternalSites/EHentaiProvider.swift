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

    // MARK: Список тайтлов по тегу

    /// Общий ExternalTagNamespace → префикс тега e-hentai. У e-hentai нет
    /// namespace'ов female/male в понятии "весь список по этому неймспейсу"
    /// (как у hitomi/.nozomi) — они здесь такие же namespaced-теги
    /// (`female:...`/`male:...`), просто на общей странице `/tag/`.
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

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let prefix = Self.tagPrefix(for: namespace)
        let encodedValue = value.lowercased()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value.lowercased()
        var urlString = "https://e-hentai.org/tag/\(prefix):\(encodedValue)"
        if let cursor { urlString += "?next=\(cursor)" }
        return try await fetchGalleryList(urlString: urlString)
    }

    /// Обычный полнотекстовый поиск по всему сайту (`?f_search=`) — то,
    /// чего у hitomi нет (см. HitomiProvider.fetchIdsBySearch — заглушка).
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
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
        guard let url = URL(string: "https://e-hentai.org/g/\(id)/\(token)/") else {
            throw EHentaiError.badResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw EHentaiError.badResponse
        }
        return Self.parseGalleryDetail(id: id, html: html)
    }

    private static func parseGalleryDetail(id: Int, html: String) -> ExternalGalleryDetail {
        let title = firstMatch(in: html, pattern: #"<h1 id="gn">([^<]*)</h1>"#).map(decodeHTMLEntities) ?? "Untitled"
        let type = firstMatch(in: html, pattern: #"<div id="gdc"><div class="cs [^"]+"[^>]*>([^<]+)</div>"#) ?? "Misc"
        let language = firstMatch(in: html, pattern: #"<td[^>]*>Language:</td><td[^>]*>([^<]+?)(?:\s*<span[^>]*>[^<]*</span>)?</td>"#).map(decodeHTMLEntities)
        let coverURL = firstMatch(in: html, pattern: #"(https://ehgt\.org/[^"'\s]+\.(?:jpg|jpeg|png|webp))"#).flatMap(URL.init(string:))

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

        var pages: [ExternalGalleryPage] = []
        if let regex = try? NSRegularExpression(pattern: #"href="https://e-hentai\.org/s/([0-9a-f]+)/\d+-(\d+)""#) {
            let range = NSRange(html.startIndex..., in: html)
            var seen = Set<Int>()
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 3,
                      let keyRange = Range(match.range(at: 1), in: html),
                      let indexRange = Range(match.range(at: 2), in: html),
                      let index = Int(html[indexRange]), !seen.contains(index) else { return }
                seen.insert(index)
                pages.append(ExternalGalleryPage(index: index, key: String(html[keyRange]), width: 0, height: 0))
            }
        }
        pages.sort { $0.index < $1.index }

        return ExternalGalleryDetail(
            id: id,
            title: title,
            type: type,
            language: language,
            tags: tags,
            artists: artists,
            groups: groups,
            characters: characters,
            series: series,
            // Похожие тайтлы на странице e-hentai — не отдельный список ID
            // (как related у hitomi), а карточки с собственными gid/token —
            // не подтверждено разбором, честно пусто (см. план "чего не хватает").
            related: [],
            pages: pages,
            coverURL: coverURL
        )
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
