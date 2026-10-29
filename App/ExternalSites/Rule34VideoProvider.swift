import Foundation

enum Rule34VideoError: LocalizedError {
    case response(Int), invalidPage, unsupportedMedia, rateLimited(TimeInterval)
    var retryAfter: TimeInterval? { if case .rateLimited(let delay) = self { return delay }; return nil }
    var errorDescription: String? {
        switch self {
        case .response(let code): return "Rule34Video: ошибка загрузки (\(code))."
        case .invalidPage: return "Не удалось прочитать ответ Rule34Video."
        case .unsupportedMedia: return "Rule34Video не вернул ссылку на видео."
        case .rateLimited: return "Rule34Video ограничил запросы. Загрузка продолжится после паузы."
        }
    }
}

/// KVS catalog blocks, entity suggestions and player configuration from the captured site contract.
struct Rule34VideoProvider: ExternalSiteProvider {
    let site: ExternalSite = .rule34Video
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true, hasTagBrowser: false, hasSearch: true, hasCategoryFilter: true,
        hasPageJump: true, hasSortOptions: false, hasBookmarks: false, hasHistory: false,
        hasNotifications: false, hasComments: false, typicalPageSize: 23
    )
    static let baseURL = URL(string: "https://rule34video.com/")!
    static let headers = ["Referer": "https://rule34video.com/", "User-Agent": Rule34Provider.mediaHeaders["User-Agent"]!]
    private static let transport = Rule34VideoTransport()
    private static let cache = Rule34VideoCache()

    /// Cookie presence is not authentication; the captured account endpoint confirms it.
    static func validateSession(cookies: [HTTPCookie]) async throws -> [HTTPCookie] {
        var components = URLComponents(url: baseURL.appendingPathComponent("tag_wiki.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "action", value: "me")]
        let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        let response = try await transport.loadResponse(components.url!, cookieOverride: header)
        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              object["status"] as? String == "ok", let me = object["me"] as? [String: Any],
              let loggedIn = me["logged_in"] as? Bool else { throw Rule34VideoError.invalidPage }
        guard loggedIn else { throw Rule34VideoAuthError.notLoggedIn }
        let refreshed = await Rule34VideoAuthStore.merging(cookies, with: response.cookies)
        guard await Rule34VideoAuthStore.hasSessionCookies(refreshed) else { throw Rule34VideoAuthError.notLoggedIn }
        return refreshed
    }

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] { [] }

    static func suggestions(_ text: String, kind: Rule34VideoEntity.Kind) async throws -> [Rule34VideoEntity] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if let values = await cache.suggestions(query, kind: kind) { return values }
        let endpoint: String
        switch kind { case .tag: endpoint = "tags_json.php"; case .category: endpoint = "categories_json.php"; case .artist: endpoint = "models_json.php" }
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "q", value: query), .init(name: "advanced_search", value: "true")]
        if kind == .tag { components.queryItems?.append(.init(name: "id", value: "true")) }
        let data = try await transport.load(components.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Rule34VideoError.invalidPage }
        // The service represents an empty list as either [] or an empty string.
        let items = object["items"] as? [[String: Any]] ?? []
        let values: [Rule34VideoEntity] = items.compactMap { item in
            guard let key = Int(String(describing: item["id"] ?? "")), key > 0,
                  let name = item["title"] as? String, !name.isEmpty else { return nil }
            return Rule34VideoEntity(key: key, kind: kind, name: HTML.text(name),
                slug: item["dir"] as? String ?? "", count: Int(String(describing: item["total"] ?? "")) ?? 0)
        }
        await cache.saveSuggestions(values, query: query, kind: kind)
        return values
    }

    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        let kind: Rule34VideoEntity.Kind = namespace == "artist" ? .artist : (namespace == "category" ? .category : .tag)
        return try await Self.suggestions(query, kind: kind).map {
            ExternalTagSuggestion(name: $0.name, count: $0.count, category: kind.rawValue)
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let kind: Rule34VideoEntity.Kind = namespace == .artist ? .artist : (namespace == .series ? .category : .tag)
        let results = try await Self.suggestions(value, kind: kind)
        let normalized = Self.normalized(value)
        // Partial suggestions must not silently change a requested interest into another tag.
        guard let entity = results.first(where: { Self.normalized($0.name) == normalized || Self.normalized($0.slug) == normalized }) else {
            return try await fetchIdsBySearch(query: value, cursor: cursor, limit: limit)
        }
        var query = Rule34VideoQuery(); query.entities = [entity]
        return try await fetchIdsBySearch(query: query.encoded(search: ""), cursor: cursor, limit: limit)
    }

    /// Recommendation combinations retain separate tag identities rather than becoming a phrase search.
    static func combination(_ values: [String]) -> String {
        "r34v-tags:" + ((try? JSONEncoder().encode(values))?.base64EncodedString() ?? "")
    }

    func fetchIdsBySearch(query text: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        var query = Rule34VideoQuery.decode(text)
        if text.hasPrefix("r34v-tags:"), let data = Data(base64Encoded: String(text.dropFirst(10))),
           let tags = try? JSONDecoder().decode([String].self, from: data) {
            query = Rule34VideoQuery()
            for tag in tags {
                let values = try await Self.suggestions(tag, kind: .tag)
                if let match = values.first(where: { Self.normalized($0.name) == Self.normalized(tag) }) {
                    if !query.entities.contains(where: { $0.id == match.id }) { query.entities.append(match) }
                }
            }
            guard query.entities.count == Set(tags.map(Self.normalized)).count else { return ([], nil) }
        }
        let page = max(1, cursor.flatMap { PageCursor.decode($0)?.page ?? Int($0) } ?? 1)
        let previous = cursor.flatMap(PageCursor.decode)
        let isSearch = !query.searchText.isEmpty
        let path = isSearch ? "/search/\(Self.searchSlug(query.searchText))/" : "/"
        let block = previous?.block ?? (isSearch ? "custom_list_videos_videos_list_search" : "custom_list_videos_most_recent_videos")
        let pageVariable = previous?.variable ?? (isSearch ? "from_videos" : "from")
        var components = URLComponents(string: "https://rule34video.com" + path)!
        if page > 1 || query.filterCount > 0 {
            components.queryItems = query.parameters(page: page, block: block, pageVariable: pageVariable)
        }
        let data = try await Self.transport.load(components.url!)
        guard let html = String(data: data, encoding: .utf8) else { throw Rule34VideoError.invalidPage }
        let listing = try Self.parseListing(html, requestedPage: page, block: block, variable: pageVariable)
        await Self.cache.saveListing(listing.previews, keys: listing.keys, total: listing.total)
        return (listing.previews.map(\.id), listing.next?.encoded())
    }

    func cursorForPage(_ page: Int, limit: Int) -> String? { page <= 1 ? nil : String(page) }
    func lastKnownEstimatedTotal() async -> Int? { await Self.cache.total }
    func resolveKey(for id: Int) async -> String? { await Self.cache.key(id) }
    func primeResolveKey(_ key: String, for id: Int) async {
        guard let url = URL(string: key), Self.isVideoPage(url, id: id) else { return }
        await Self.cache.saveKey(key, id: id)
    }

    func fetchCatalogPreview(id: Int) async throws -> ExternalGalleryDetail {
        if let preview = await Self.cache.preview(id) { return preview }
        return try await fetchGalleryDetail(id: id)
    }

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        let revision = await Rule34VideoAuthStore.shared.revision
        return try await Self.cache.detail(id, session: revision) {
            // Popup resolution works from the stable numeric ID, including saved history after relaunch.
            var components = URLComponents(url: Self.baseURL.appendingPathComponent("popup-video/\(id)/"), resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "popup_id", value: "2")]
            let data = try await Self.transport.load(components.url!)
            guard let html = String(data: data, encoding: .utf8) else { throw Rule34VideoError.invalidPage }
            var detail = try Self.parseDetail(html, id: id)
            if let video = detail.video {
                let credentials = await Rule34VideoAuthStore.shared.credentials(for: video.url)
                guard credentials.revision == revision else { throw CancellationError() }
                var headers = video.headers
                if let cookie = credentials.header { headers["Cookie"] = cookie }
                detail.video = ExternalVideo(url: video.url, posterURL: video.posterURL, headers: headers)
            }
            return detail
        }
    }

    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL { throw Rule34VideoError.unsupportedMedia }

    private struct PageCursor: Codable {
        let page: Int
        let block: String
        let variable: String
        func encoded() -> String { (try? JSONEncoder().encode(self))?.base64EncodedString() ?? "" }
        static func decode(_ value: String) -> Self? {
            guard let data = Data(base64Encoded: value) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
    }

    private struct Listing {
        var previews: [ExternalGalleryDetail] = []
        var keys: [Int: String] = [:]
        var total: Int?
        var next: PageCursor?
    }

    private static func parseListing(_ html: String, requestedPage: Int, block: String, variable: String) throws -> Listing {
        let container = HTML.captures(#"(<[^>]+\bdata-rd-list\s*=[^>]+>)"#, html).first.map(HTML.attributes)
        let currentBlock = container?["data-rd-list"] ?? block
        let pageVariable = container?["data-from-var"] ?? variable
        var result = Listing()
        result.total = container?["data-total"].flatMap(Int.init)
        // Mobile cards omit the desktop popup class. Their video URL and image
        // define a catalog entry independently of the site's interaction scripts.
        let cards = HTML.captures(#"(<a\b[^>]*>[\s\S]*?</a>)"#, html)
        var seen = Set<Int>()
        for card in cards {
            guard let opening = HTML.captures(#"(<a\b[^>]*>)"#, card).first,
                  let href = HTML.attributes(opening)["href"], let url = HTML.url(href),
                  let id = videoID(url),
                  let image = HTML.captures(#"(<img\b[^>]*>)"#, card).first,
                  seen.insert(id).inserted else { continue }
            let attrs = HTML.attributes(image)
            let cover = (attrs["data-src"] ?? attrs["src"]).flatMap(HTML.url)
            let title = attrs["alt"] ?? HTML.attributes(opening)["title"] ?? "Rule34Video · #\(id)"
            result.keys[id] = url.absoluteString
            result.previews.append(makeDetail(id: id, title: title, cover: cover))
        }
        guard container != nil || html.contains(currentBlock) else { throw Rule34VideoError.invalidPage }
        let totalPages = container?["data-pages"].flatMap(Int.init)
        if result.previews.isEmpty, (result.total ?? 0) > 0, totalPages.map({ requestedPage <= $0 }) ?? true {
            throw Rule34VideoError.invalidPage
        }
        // Read the actual pagination contract, preserving the search-specific variable and block.
        let pages = HTML.captures(#"(<a\b[^>]*\bdata-parameters=[^>]+>)"#, html).compactMap { anchor -> Int? in
            let attrs = HTML.attributes(anchor)
            guard attrs["data-block-id"] == currentBlock, let parameters = attrs["data-parameters"] else { return nil }
            return HTML.captures("(?:^|;)" + NSRegularExpression.escapedPattern(for: pageVariable) + #":(\d+)"#, parameters).first.flatMap(Int.init)
        }
        if !result.previews.isEmpty, let next = pages.filter({ $0 > requestedPage }).min() {
            result.next = PageCursor(page: next, block: currentBlock, variable: pageVariable)
        } else if !result.previews.isEmpty, let totalPages = container?["data-pages"].flatMap(Int.init), requestedPage < totalPages {
            result.next = PageCursor(page: requestedPage + 1, block: currentBlock, variable: pageVariable)
        }
        return result
    }

    private static func parseDetail(_ html: String, id: Int) throws -> ExternalGalleryDetail {
        guard let config = HTML.captures(#"\bflashvars\s*=\s*\{([\s\S]*?)\}\s*;"#, html).first else { throw Rule34VideoError.unsupportedMedia }
        let values = HTML.javascriptStrings(config)
        guard values["video_id"].flatMap(Int.init) == id else { throw Rule34VideoError.invalidPage }
        let keys = ["video_url", "video_alt_url", "video_alt_url2", "video_alt_url3", "video_alt_url4"]
        let sources: [(URL, Int)] = keys.compactMap { key in
            guard let raw = values[key], let url = HTML.url(raw), url.host == "rule34video.com",
                  url.path.hasPrefix("/get_file/"), url.path.lowercased().contains(".mp4") else { return nil }
            let label = values[key + "_text"]?.lowercased() ?? ""
            let height = label.contains("4k") ? 2160 : Int(label.filter(\.isNumber)) ?? 0
            return (url, height)
        }
        // Prefer 1080p to avoid automatically downloading 4K on a phone. Keep the signed URL intact.
        guard let source = sources.filter({ $0.1 <= 1080 }).max(by: { $0.1 < $1.1 }) ?? sources.min(by: { $0.1 < $1.1 }) else {
            throw Rule34VideoError.unsupportedMedia
        }
        let cover = values["preview_url"].flatMap(HTML.url)
        let tags = (values["video_tags"] ?? "").split(separator: ",").map { HTML.text(String($0)) }.filter { !$0.isEmpty }
        let artists = (values["video_models"] ?? "").split(separator: ",").map { HTML.text(String($0)) }.filter { !$0.isEmpty }
        let categories = (values["video_categories"] ?? "").split(separator: ",").map { HTML.text(String($0)) }.filter { !$0.isEmpty }
        var detail = makeDetail(id: id, title: values["video_title"] ?? "Rule34Video · #\(id)", cover: cover,
            tags: tags, artists: artists, series: categories)
        detail.video = ExternalVideo(url: source.0, posterURL: cover, headers: headers)
        return detail
    }

    private static func makeDetail(id: Int, title: String, cover: URL?, tags: [String] = [], artists: [String] = [], series: [String] = []) -> ExternalGalleryDetail {
        ExternalGalleryDetail(id: id, site: .rule34Video, title: HTML.text(title), type: "video", language: nil,
            tags: tags.map { .init(name: $0, female: false, male: false) }, artists: artists, groups: [], characters: [], series: series,
            related: [], pages: [], coverURL: cover, posted: nil, parentId: nil, visible: nil, fileSize: nil,
            favoritedCount: nil, ratingAverage: nil, ratingCount: nil, comments: [])
    }

    private static func videoID(_ url: URL) -> Int? {
        guard url.host == "rule34video.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "video" else { return nil }
        return Int(parts[1])
    }
    private static func isVideoPage(_ url: URL, id: Int) -> Bool { url.scheme == "https" && videoID(url) == id }
    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors searchQuerySlug from the captured site script, including double-encoded special characters.
    private static func searchSlug(_ text: String) -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let escaped = input.replacingOccurrences(of: "-", with: "[dash]")
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression).replacingOccurrences(of: "?", with: "")
        let specials = Set("%&+#/")
        let inner = escaped.map { specials.contains($0) ? String($0).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! : String($0) }.joined()
            .replacingOccurrences(of: "[dash]", with: "--")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return inner.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private enum HTML {
        static func captures(_ pattern: String, _ input: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
                Range($0.range(at: 1), in: input).map { String(input[$0]) }
            }
        }
        static func attributes(_ input: String) -> [String: String] {
            guard let regex = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [:] }
            var result: [String: String] = [:]
            for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                guard let key = Range(match.range(at: 1), in: input),
                      let value = Range(match.range(at: 2), in: input) ?? Range(match.range(at: 3), in: input) else { continue }
                result[String(input[key]).lowercased()] = entities(String(input[value]))
            }
            return result
        }
        static func javascriptStrings(_ input: String) -> [String: String] {
            guard let regex = try? NSRegularExpression(pattern: #"\b(\w+)\s*:\s*'((?:\\.|[^'\\])*)'"#) else { return [:] }
            var result: [String: String] = [:]
            for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
                guard let key = Range(match.range(at: 1), in: input), let value = Range(match.range(at: 2), in: input) else { continue }
                result[String(input[key])] = unescape(String(input[value]))
            }
            return result
        }
        private static func unescape(_ value: String) -> String {
            // Decode quoted JS strings as data. No evaluation of site scripts is performed.
            var output = ""; var iterator = value.makeIterator()
            while let character = iterator.next() {
                guard character == "\\", let escaped = iterator.next() else { output.append(character); continue }
                switch escaped {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "u", "x":
                    var digits = ""
                    for _ in 0..<(escaped == "u" ? 4 : 2) { if let digit = iterator.next() { digits.append(digit) } }
                    if let number = UInt32(digits, radix: 16), let scalar = UnicodeScalar(number) { output.unicodeScalars.append(scalar) }
                default: output.append(escaped)
                }
            }
            return output
        }
        static func entities(_ value: String) -> String {
            var result = value
            if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) {
                for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                    guard let key = Range(match.range(at: 1), in: result), let range = Range(match.range, in: result) else { continue }
                    let raw = String(result[key]); let hex = raw.hasPrefix("x")
                    if let number = UInt32(hex ? String(raw.dropFirst()) : raw, radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) {
                        result.replaceSubrange(range, with: String(scalar))
                    }
                }
            }
            for (key, value) in [("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
                result = result.replacingOccurrences(of: key, with: value)
            }
            return result
        }
        static func text(_ value: String) -> String {
            entities(value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        static func url(_ raw: String) -> URL? {
            guard let url = URL(string: entities(raw), relativeTo: Rule34VideoProvider.baseURL)?.absoluteURL,
                  url.scheme == "https", url.host != nil else { return nil }
            return url
        }
    }
}

private actor Rule34VideoCache {
    private var previews: [Int: ExternalGalleryDetail] = [:]
    private var details: [Int: (Date, ExternalGalleryDetail)] = [:]
    private var pending: [Int: Task<ExternalGalleryDetail, Error>] = [:]
    private var sessionRevision: UUID?
    private var keys: [Int: String] = [:]
    private var suggestionCache: [String: (Date, [Rule34VideoEntity])] = [:]
    private(set) var total: Int?

    func suggestions(_ query: String, kind: Rule34VideoEntity.Kind) -> [Rule34VideoEntity]? {
        guard let value = suggestionCache[kind.rawValue + ":" + query.lowercased()], Date().timeIntervalSince(value.0) < 600 else { return nil }
        return value.1
    }
    func saveSuggestions(_ values: [Rule34VideoEntity], query: String, kind: Rule34VideoEntity.Kind) {
        if suggestionCache.count >= 128 { suggestionCache.removeValue(forKey: suggestionCache.min(by: { $0.value.0 < $1.value.0 })!.key) }
        suggestionCache[kind.rawValue + ":" + query.lowercased()] = (Date(), values)
    }
    func key(_ id: Int) -> String? { keys[id] }
    func saveKey(_ value: String, id: Int) { keys[id] = value }
    func preview(_ id: Int) -> ExternalGalleryDetail? { previews[id] }
    func saveListing(_ values: [ExternalGalleryDetail], keys newKeys: [Int: String], total: Int?) {
        self.total = total
        for value in values { previews[value.id] = value }
        keys.merge(newKeys) { _, new in new }
        if previews.count > 192 { previews = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }) }
        if keys.count > 1024 { keys = newKeys }
    }
    func detail(_ id: Int, session: UUID, load: @escaping @Sendable () async throws -> ExternalGalleryDetail) async throws -> ExternalGalleryDetail {
        if sessionRevision != session {
            for task in pending.values { task.cancel() }
            pending.removeAll(); details.removeAll()
            sessionRevision = session
        }
        if let value = details[id], Date().timeIntervalSince(value.0) < 120 { return value.1 }
        if let task = pending[id] { return try await task.value }
        let task = Task { try await load() }
        pending[id] = task
        defer { if sessionRevision == session { pending.removeValue(forKey: id) } }
        let value = try await task.value
        try Task.checkCancellation()
        guard sessionRevision == session else { throw CancellationError() }
        details[id] = (Date(), value)
        if details.count > 64, let oldest = details.min(by: { $0.value.0 < $1.value.0 })?.key { details.removeValue(forKey: oldest) }
        return value
    }
}

/// A single bounded request budget prevents catalog, autocomplete and feed hydration from flooding KVS.
private actor Rule34VideoTransport {
    private let session: URLSession
    private var nextStart = Date.distantPast
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = Rule34VideoProvider.headers
        configuration.timeoutIntervalForRequest = 25
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: Rule34VideoRedirectDelegate(), delegateQueue: nil)
    }
    func load(_ url: URL) async throws -> Data {
        try await loadResponse(url).data
    }
    func loadResponse(_ url: URL, cookieOverride: String? = nil) async throws -> Rule34VideoHTTPResponse {
        guard url.scheme == "https", url.host == "rule34video.com" else { throw Rule34VideoError.invalidPage }
        for attempt in 0..<3 {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpShouldHandleCookies = false
            let jsonEndpoint = url.path.hasSuffix(".php")
            let asyncBlock = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "mode" && $0.value == "async" } == true
            if jsonEndpoint || asyncBlock {
                request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                request.setValue(jsonEndpoint ? "application/json" : "text/plain, */*; q=0.01", forHTTPHeaderField: "Accept")
            }
            var credentials: Rule34VideoAuthStore.Credentials
            while true {
                while nextStart > Date() {
                    let delay = nextStart.timeIntervalSinceNow
                    if delay > 20 { throw Rule34VideoError.rateLimited(delay) }
                    try await Task.sleep(for: .seconds(max(0.01, delay)))
                }
                credentials = await Rule34VideoAuthStore.shared.credentials(for: url)
                try Task.checkCancellation()
                // Reading session state is a suspension point; reserve the budget afterward.
                guard nextStart <= Date() else { continue }
                request.setValue(cookieOverride ?? credentials.header, forHTTPHeaderField: "Cookie")
                nextStart = Date().addingTimeInterval(1)
                break
            }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Rule34VideoError.response(0) }
            guard response.url?.scheme == "https", response.url?.host == "rule34video.com" else { throw Rule34VideoError.invalidPage }
            if response.statusCode == 429 {
                let delay = Self.retryDelay(response, fallback: Double((attempt + 1) * 5))
                nextStart = max(nextStart, Date().addingTimeInterval(delay))
                if attempt == 2 { throw Rule34VideoError.rateLimited(delay) }
                continue
            }
            guard response.statusCode == 200 else { throw Rule34VideoError.response(response.statusCode) }
            try Task.checkCancellation()
            var fields: [String: String] = [:]
            for (key, value) in response.allHeaderFields { fields[String(describing: key)] = String(describing: value) }
            let updated = HTTPCookie.cookies(withResponseHeaderFields: fields, for: response.url!)
            if cookieOverride == nil {
                guard await Rule34VideoAuthStore.shared.revision == credentials.revision else { throw CancellationError() }
                await Rule34VideoAuthStore.shared.receiveCookies(updated, revision: credentials.revision)
            }
            return Rule34VideoHTTPResponse(data: data, cookies: updated)
        }
        throw Rule34VideoError.rateLimited(5)
    }

    private static func retryDelay(_ response: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return fallback }
        if let seconds = Double(value), seconds.isFinite { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return max(1, formatter.date(from: value)?.timeIntervalSinceNow ?? fallback)
    }
}

private struct Rule34VideoHTTPResponse {
    let data: Data
    let cookies: [HTTPCookie]
}

private final class Rule34VideoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.scheme != "https" || request.url?.host?.lowercased() != "rule34video.com" || (request.url?.port ?? 443) != 443 {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        redirected.httpShouldHandleCookies = false
        completionHandler(redirected)
    }
}
