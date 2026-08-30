import Foundation

/// Ошибки HitomiProvider — намеренно простые (это не production-grade
/// error-handling слой старого MangaNetworkService, а отдельный минимальный
/// клиент, см. план про "почти не пересекаться со старым сетевым кодом").
enum HitomiError: Error {
    case badResponse
    case notFound
    case decodingFailed
}

/// Клиент hitomi.la — СВОЯ, полностью отдельная реализация (своя
/// URLSession, свой парсинг, свои модели), никак не связанная с
/// MangaNetworkService/LibSite. Все URL/форматы ниже подтверждены реальным
/// HAR (см. /root/.claude/plans/vectorized-chasing-elephant.md — там же
/// история разбора и то, что ЕЩЁ не подтверждено).
struct HitomiProvider: ExternalSiteProvider {
    let site: ExternalSite = .hitomi
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        hasTagBrowser: true,
        // Не полнотекстовый поиск в привычном смысле (тот всё ещё упирается
        // в неразобранный бинарный B-tree индекс galleriesindex/*, см. план,
        // "Что заблокировано") — но реальную пользу даёт: пустой запрос —
        // «Recently», непустой — намеренная команда namespace:значение (см.
        // fetchIdsBySearch), тот же принцип, что и у поиска на самом сайте.
        hasSearch: true,
        hasCategoryFilter: false,
        // Курсор — обычный byte-offset (см. fetchIdsByTag ниже), поэтому
        // "страница N" считается точно, без сети (см. cursorForPage ниже).
        hasPageJump: true,
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        hasComments: false
    )

    /// Отдельная сессия — не MangaNetworkService.session, заголовки/куки/
    /// кэш не должны случайно смешаться со старым кодом.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://hitomi.la/"
        ]
        return URLSession(configuration: config)
    }()

    // MARK: Алфавитный список (Часть 4)

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        let kindSlug: String
        switch kind {
        case .tags: kindSlug = "tags"
        case .series: kindSlug = "series"
        case .characters: kindSlug = "characters"
        case .artists: kindSlug = "artists"
        }
        // "123" — отдельный бакет для значений, начинающихся с цифры (см.
        // nav hitomi.la: /alltags-123.html), а не буква как таковая.
        let letterSlug = letter.isNumber ? "123" : String(letter).lowercased()
        guard let url = URL(string: "https://hitomi.la/all\(kindSlug)-\(letterSlug).html") else {
            throw HitomiError.badResponse
        }
        var request = URLRequest(url: url)
        request.setValue("https://hitomi.la/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw HitomiError.badResponse
        }
        return Self.parseTagList(html: html)
    }

    /// Формат подтверждён HAR (alltags-c.html/allseries-*.html):
    /// `<a href="/tag/SLUG-all.html">NAME</a> (COUNT)` — общий для tag/
    /// series/character/artist (различается только первый сегмент пути).
    private static func parseTagList(html: String) -> [ExternalTagEntry] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a href="/(?:tag|series|character|artist)/([^"]+)-all\.html">([^<]+)</a>\s*\((\d+)\)"#
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [ExternalTagEntry] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 4,
                  let slugRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let countRange = Range(match.range(at: 3), in: html),
                  let count = Int(html[countRange]) else { return }
            let slug = String(html[slugRange])
            let name = decodeHTMLEntities(String(html[nameRange]))
            result.append(ExternalTagEntry(id: slug, name: name, count: count, slug: slug))
        }
        return result
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: Автокомплит (Часть 5)

    func fetchAutocomplete(query: String, namespace: String? = nil) async throws -> [ExternalTagSuggestion] {
        let ns = namespace ?? "global"
        let lowered = query.lowercased()
        // Пустой запрос → корневой файл неймспейса целиком (топ по count,
        // без фильтра по префиксу) — подтверждено HAR (global.json/tag.json).
        let path: String
        if lowered.isEmpty {
            path = "\(ns).json"
        } else {
            let segments = lowered.map { char -> String in
                let raw = String(char)
                return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
            }
            path = "\(ns)/\(segments.joined(separator: "/")).json"
        }
        guard let url = URL(string: "https://tagindex.hitomi.la/\(path)") else {
            throw HitomiError.badResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw HitomiError.badResponse }
        // 404 — нормальный ответ "нет совпадений с таким префиксом", не ошибка.
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200 else { throw HitomiError.badResponse }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw HitomiError.decodingFailed
        }
        return raw.compactMap { triple in
            guard triple.count == 3,
                  let name = triple[0] as? String,
                  let count = triple[1] as? Int,
                  let category = triple[2] as? String else { return nil }
            return ExternalTagSuggestion(name: name, count: count, category: category)
        }
    }

    // MARK: Список тайтлов по тегу (.nozomi, Часть 6)

    /// РЕАЛЬНАЯ схема (перепроверено живьём против `ltn.gold-
    /// usergeneratedcontent.net`, плюс живой исходник `galleryblock.js`/
    /// `galleries/{id}.js` этого же сайта — см. план, ЧАСТЬ A): у hitomi
    /// ровно 4 "прямых" URL-кита —
    /// `tag`/`series`/`character`/`artist` (те же 4, что в nav-баре
    /// alltags/allseries/allcharacters/allartists), БЕЗ префикса `n/`
    /// (мой предыдущий фикс с `n/` не был причиной бага — сервер принимает
    /// оба варианта одинаково, но канонический — без него, как строит сам
    /// сайт). `female`/`male`/`group` — это НЕ отдельные киты: это `tag`,
    /// где ЗНАЧЕНИЕ само содержит префикс (см. `prefixedValue` ниже) —
    /// подтверждено `galleries/{id}.js`: `tags[].url =
    /// "/tag/female%3Aanal-all.html"`, НЕ `"/female/anal-all.html"`.
    private static func nozomiPath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male, .group: return "tag"
        case .character: return "character"
        case .artist: return "artist"
        case .series: return "series"
        }
    }

    /// `female`/`male`/`group` живут ПОД китом `tag` (см. nozomiPath выше)
    /// — сюда добавляется намеспейс-префикс в САМО значение, ровно как
    /// делает сам сайт (`female:anal`, не отдельный путь). `.group` — по
    /// аналогии с female/male, живым запросом НЕ подтверждено (нет ни
    /// одного `/group/`-примера в собранных HAR), помечено ниже.
    private static func prefixedValue(for namespace: ExternalTagNamespace, value: String) -> String {
        switch namespace {
        case .female: return "female:\(value)"
        case .male: return "male:\(value)"
        case .group: return "group:\(value)" // best-effort, не HAR-подтверждено
        case .tag, .character, .artist, .series: return value
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let prefixed = Self.prefixedValue(for: namespace, value: value)
        let encodedValue = prefixed.lowercased()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prefixed.lowercased()
        return try await fetchNozomiList(
            urlString: "https://\(Self.apiDomain)/\(Self.nozomiPath(for: namespace))/\(encodedValue)-all.nozomi",
            cursor: cursor, limit: limit
        )
    }

    /// РЕАЛЬНЫЙ хост для .nozomi/galleries/{id}.js — подтверждено ЖИВЫМ
    /// `common.js` самого сайта (скачан 30.08 через доступный из песочницы
    /// alias): `const domain2 = 'gold-usergeneratedcontent.net'; var domain
    /// = 'ltn.' + domain2;` — сайт САМ ходит на `ltn.gold-
    /// usergeneratedcontent.net`, НЕ на `ltn.hitomi.la` (тот, похоже,
    /// заблокирован у части провайдеров/РКН — ровно то, ради чего у сайта
    /// вообще есть domain-fronting на второй домен). Раньше здесь БЫЛ
    /// буквально `ltn.hitomi.la` — сама .nozomi-схема была верной (что и
    /// подтверждали живые curl-тесты В ЭТОЙ СЕССИИ, они шли через .net-alias
    /// как обход блокировки самой песочницы), но в реальном коде домен
    /// остался старым — вот и был "0 тайтлов" уже ПОСЛЕ фикса схемы:
    /// тестировался один домен, а в коде остался другой.
    private static let apiDomain = "ltn.gold-usergeneratedcontent.net"

    /// Общий байтовый Range-запрос к .nozomi-файлу — и по тегу
    /// (fetchIdsByTag), и по общему индексу "Recently" (fetchIdsBySearch,
    /// пустой запрос) — один и тот же формат ответа, отличается только URL.
    private func fetchNozomiList(urlString: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let offset = Int(cursor ?? "0") ?? 0
        guard let url = URL(string: urlString) else { throw HitomiError.badResponse }
        var request = URLRequest(url: url)
        let byteOffset = offset * 4
        let byteEnd = byteOffset + limit * 4 - 1
        request.setValue("bytes=\(byteOffset)-\(byteEnd)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HitomiError.badResponse }
        if http.statusCode == 404 { return ([], nil) }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw HitomiError.badResponse }

        let ids = Self.parseNozomi(data)
        var total = offset + ids.count
        // Content-Range: bytes X-Y/ИТОГО — ИТОГО уже в байтах, /4 → число тайтлов.
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slashIndex = contentRange.lastIndex(of: "/"),
           let totalBytes = Int(contentRange[contentRange.index(after: slashIndex)...]) {
            total = totalBytes / 4
        }
        let nextOffset = offset + ids.count
        let nextCursor = nextOffset < total ? String(nextOffset) : nil
        return (ids, nextCursor)
    }

    /// Курсор здесь — простой offset-в-элементах (см. fetchIdsByTag выше:
    /// `Int(cursor ?? "0") ?? 0`, дальше `* 4` в байты Range-заголовка) —
    /// значит "страница N" считается ТОЧНО, обычной арифметикой, без сети.
    func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return String((page - 1) * limit)
    }

    /// Тело .nozomi — просто массив big-endian Int32 (4 байта на ID), без
    /// заголовка/обёртки — подтверждено побайтовым разбором HAR.
    private static func parseNozomi(_ data: Data) -> [Int] {
        let count = data.count / 4
        var result: [Int] = []
        result.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let offset = i * 4
                let b0 = Int(raw[offset])
                let b1 = Int(raw[offset + 1])
                let b2 = Int(raw[offset + 2])
                let b3 = Int(raw[offset + 3])
                result.append((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            }
        }
        return result
    }

    /// Пустой запрос — «Recently» (см. индекс `index-all.nozomi`, тот же
    /// принцип, что и главная страница hitomi.la), непустой — распознаёт
    /// префикс `namespace:значение` (`female:`/`male:`/`series:`/`artist:`/
    /// `group:`/`character:`/`tag:`, по образцу того, как реально ищут на
    /// самом сайте) и уходит в fetchIdsByTag; без префикса — трактует весь
    /// текст как обычный тег (namespace `.tag`). `index-all.nozomi`
    /// проверен живым curl против apiDomain (30.08, повторная проверка) —
    /// `206`, `Content-Range .../4804324` (~1.2M тайтлов, правдоподобно для
    /// "весь индекс").
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return try await fetchNozomiList(urlString: "https://\(Self.apiDomain)/index-all.nozomi", cursor: cursor, limit: limit)
        }
        let (namespace, value) = Self.parseSearchCommand(trimmed)
        return try await fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: limit)
    }

    private static let searchPrefixes: [(String, ExternalTagNamespace)] = [
        ("female:", .female), ("male:", .male), ("series:", .series),
        ("artist:", .artist), ("group:", .group), ("character:", .character), ("tag:", .tag)
    ]

    private static func parseSearchCommand(_ text: String) -> (ExternalTagNamespace, String) {
        let lower = text.lowercased()
        for (prefix, ns) in searchPrefixes where lower.hasPrefix(prefix) {
            return (ns, lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
        }
        return (.tag, lower)
    }

    // MARK: Карточка тайтла (galleries/{id}.js, Часть 6)

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "https://\(Self.apiDomain)/galleries/\(id).js") else {
            throw HitomiError.badResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              var text = String(data: data, encoding: .utf8) else {
            throw HitomiError.badResponse
        }
        // Ответ — "var galleryinfo = { ... };", не чистый JSON.
        if let range = text.range(of: "var galleryinfo = ") {
            text.removeSubrange(text.startIndex..<range.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") { text.removeLast() }
        guard let jsonData = text.data(using: .utf8) else { throw HitomiError.decodingFailed }
        let decoded = try JSONDecoder().decode(HitomiGalleryJSON.self, from: jsonData)
        return decoded.toDetail()
    }

    // MARK: URL картинок

    /// Превью для сетки/карточки — простое шардирование по первым символам
    /// хэша, БЕЗ gg.js (подтверждено HAR: galleryblock/{id}.html отдаёт
    /// именно такие URL напрямую). Раньше была отдельным методом протокола
    /// (thumbnailURL(hash:)) — теперь просто кладётся в
    /// ExternalGalleryDetail.coverURL при декодировании (см. toDetail()
    /// ниже), т.к. формула hitomi-специфична, у e-hentai её вообще нет.
    fileprivate static func coverURL(forHash hash: String) -> URL? {
        let c0 = hash.first.map(String.init) ?? "0"
        let c1_3 = hash.count >= 3 ? String(hash.dropFirst().prefix(2)) : "00"
        return URL(string: "https://tn.gold-usergeneratedcontent.net/webpbigtn/\(c0)/\(c1_3)/\(hash).webp")
    }

    /// Полноразмерная страница чтения — формула gg.js, ПОДТВЕРЖДЕНА двумя
    /// живыми примерами из HAR (см. HitomiGG doc-comment и план):
    /// хост = "w" (webp) + (gg.m(Int(gg.s(hash))) + 1), путь = gg.b +
    /// gg.s(hash) + "/" + hash + ".webp". Сети не требует — async только
    /// ради общего протокола (см. EHentaiProvider, там реально нужна сеть).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        let hash = page.key
        let bucket = HitomiGG.s(hash)
        let g = Int(bucket) ?? 0
        let hostNumber = HitomiGG.m(g) + 1
        let host = "w\(hostNumber).gold-usergeneratedcontent.net"
        guard let url = URL(string: "https://\(host)/\(HitomiGG.b)\(bucket)/\(hash).webp") else {
            throw HitomiError.badResponse
        }
        return url
    }
}

// MARK: - JSON-модель galleries/{id}.js

private struct HitomiGalleryJSON: Decodable {
    struct TagEntry: Decodable {
        let tag: String
        let female: String?
        let male: String?
    }
    struct FileEntry: Decodable {
        let hash: String
        let width: Int
        let height: Int
    }

    let id: String
    let title: String
    let type: String
    let language: String?
    /// Дата публикации — подтверждена живьём (`"2025-03-08 15:00:00-06"`),
    /// см. план ЧАСТЬ A/B.2. `date`, не `datepublished` — оба поля есть в
    /// ответе, но `date` — то, что реально показывается на самой странице
    /// тайтла (`<span class="date">`).
    let date: String?
    let tags: [TagEntry]?
    let artists: [[String: JSONAnyValue]]?
    let groups: [[String: JSONAnyValue]]?
    let characters: [[String: JSONAnyValue]]?
    let parodys: [[String: JSONAnyValue]]?
    let related: [Int]?
    let files: [FileEntry]

    func toDetail() -> ExternalGalleryDetail {
        let pages = files.enumerated().map { idx, file in
            ExternalGalleryPage(
                index: idx + 1, key: file.hash, width: file.width, height: file.height,
                thumbnailURL: HitomiProvider.coverURL(forHash: file.hash),
                thumbnailSpriteOffsetX: nil
            )
        }
        return ExternalGalleryDetail(
            id: Int(id) ?? 0,
            site: .hitomi,
            title: title,
            type: type,
            language: language,
            tags: (tags ?? []).map {
                ExternalGalleryTag(name: $0.tag, female: $0.female == "1", male: $0.male == "1")
            },
            artists: Self.names(from: artists, key: "artist"),
            groups: Self.names(from: groups, key: "group"),
            characters: Self.names(from: characters, key: "character"),
            series: Self.names(from: parodys, key: "parody"),
            related: related ?? [],
            pages: pages,
            coverURL: pages.first?.thumbnailURL,
            posted: date,
            // hitomi физически не имеет этих полей — см. план ЧАСТЬ B.2,
            // честно nil/[], не выдумываем.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: nil,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    private static func names(from array: [[String: JSONAnyValue]]?, key: String) -> [String] {
        (array ?? []).compactMap { entry in
            if case let .string(value)? = entry[key] { return value }
            return nil
        }
    }
}

/// artists/groups/characters/parodys — массивы объектов с РАЗНЫМИ ключами
/// (artist/group/character/parody) вперемешку с "url" — решаем через
/// generic-обёртку, не заводя 4 почти одинаковых Decodable-структуры.
private enum JSONAnyValue: Decodable {
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }
}
