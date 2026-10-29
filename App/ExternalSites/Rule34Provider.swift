import Foundation

enum Rule34Error: LocalizedError {
    case badResponse(Int)
    case unsupportedMedia
    case invalidPage
    case rateLimited(TimeInterval)
    case verificationRequired

    var retryAfter: TimeInterval? {
        if case .rateLimited(let delay) = self { return delay }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .badResponse(let status): return "Rule34: ошибка загрузки (\(status))."
        case .unsupportedMedia: return "У этого поста нет поддерживаемого видео."
        case .invalidPage: return "Не удалось прочитать страницу Rule34."
        case .rateLimited: return "Rule34 временно ограничил запросы. Загрузка продолжится после паузы."
        case .verificationRequired: return "Rule34 требует проверку CAPTCHA на сайте. Это не ошибка соединения."
        }
    }
}

/// Video-only integration based on the captured HTML, redirects and autocomplete JSON.
struct Rule34Provider: ExternalSiteProvider {
    let site: ExternalSite = .rule34
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true, hasTagBrowser: false, hasSearch: true,
        hasCategoryFilter: true, hasPageJump: true, hasSortOptions: false,
        hasBookmarks: false, hasHistory: false, hasNotifications: false,
        hasComments: false, typicalPageSize: 42
    )

    static let baseURL = URL(string: "https://rule34.xxx/")!
    static let loginURL = URL(string: "https://rule34.xxx/index.php?page=account&s=login&code=00")!
    static let mediaHeaders = [
        "Referer": "https://rule34.xxx/",
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    ]
    private static let transport = Rule34Transport(headers: mediaHeaders)
    private static let cache = Rule34DetailCache()

    /// The captured success redirect is not sufficient on its own: the server's
    /// account page must expose Logout and the matching authenticated profile.
    static func validateAccount(cookies: [HTTPCookie]) async throws -> Rule34Account {
        guard let cookieID = await Rule34AuthStore.credentialUserID(cookies) else {
            throw Rule34AuthError.notLoggedIn
        }
        let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
        let url = URL(string: "index.php?page=account&s=home", relativeTo: baseURL)!.absoluteURL
        let data = try await transport.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData), cookieOverride: header)
        guard let html = String(data: data, encoding: .utf8) else { throw Rule34Error.invalidPage }
        guard let id = authenticatedUserID(in: html), id == cookieID else {
            let fields = matches(#"(<input\b[^>]*>)"#, in: html).map(attributes)
            let hasLoginForm = fields.contains { $0["name"] == "user" }
                && fields.contains { $0["name"] == "pass" && $0["type"] == "password" }
            if html.contains("user-index") || hasLoginForm { throw Rule34AuthError.notLoggedIn }
            throw Rule34Error.invalidPage
        }
        let profile = URL(string: "index.php?page=account&s=profile&id=\(id)", relativeTo: baseURL)!.absoluteURL
        var username: String?
        // The display name is optional; failure to load a public profile must not
        // discard an otherwise server-confirmed session.
        if let data = try? await transport.load(URLRequest(url: profile, cachePolicy: .reloadIgnoringLocalCacheData), cookieOverride: header),
           let profileHTML = String(data: data, encoding: .utf8),
           let heading = first(#"<h2\s*>([\s\S]*?)</h2>"#, in: profileHTML) {
            let name = decode(heading.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            username = name.isEmpty ? nil : name
        }
        try Task.checkCancellation()
        return Rule34Account(id: id, username: username)
    }

    static func authenticatedUserID(in html: String) -> Int? {
        guard html.contains("user-index") else { return nil }
        let links = matches(#"(<a\b[^>]*>)"#, in: html).compactMap { anchor -> URLComponents? in
            guard let href = attributes(anchor)["href"], let url = resolveURL(href),
                  url.host == "rule34.xxx", url.path == "/index.php" else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)
        }
        func value(_ name: String, in link: URLComponents) -> String? {
            link.queryItems?.first(where: { $0.name == name })?.value
        }
        guard links.contains(where: { value("page", in: $0) == "account"
            && value("s", in: $0) == "login" && value("code", in: $0) == "01" }) else { return nil }
        return links.first(where: { value("page", in: $0) == "account" && value("s", in: $0) == "profile" })
            .flatMap { value("id", in: $0) }.flatMap(Int.init)
    }

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] { [] }

    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        let prefix = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return [] }
        var components = URLComponents(string: "https://ac.rule34.xxx/autocomplete.php")!
        components.queryItems = [URLQueryItem(name: "q", value: Self.searchTag(prefix))]
        let data = try await Self.load(components.url!)
        // The captured service labels JSON as text/html, so decode its body directly.
        let entries = try JSONDecoder().decode([Suggestion].self, from: data)
        return entries.map { entry in
            let count = Self.first(#"\((\d+)\)\s*$"#, in: entry.label).flatMap(Int.init) ?? 0
            return ExternalTagSuggestion(name: entry.value, count: count, category: entry.type)
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: Self.searchTag(value), cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let offset = max(0, cursor.flatMap(Int.init) ?? 0)
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("index.php"), resolvingAgainstBaseURL: false)!
        var tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        tokens.removeAll { ["video", "-video"].contains($0.lowercased()) }
        tokens.insert("video", at: 0)
        components.queryItems = [
            .init(name: "page", value: "post"), .init(name: "s", value: "list"),
            .init(name: "tags", value: tokens.joined(separator: " "))
        ]
        if offset > 0 { components.queryItems?.append(.init(name: "pid", value: String(offset))) }
        let data = try await Self.load(components.url!)
        guard let html = String(data: data, encoding: .utf8) else { throw Rule34Error.invalidPage }
        let listing = try Self.parseListing(html, offset: offset)
        await Self.cache.insertPreviews(Self.parseCatalogPreviews(html))
        return listing
    }

    func cursorForPage(_ page: Int, limit: Int) -> String? {
        page <= 1 ? nil : String((page - 1) * capabilities.typicalPageSize)
    }

    /// A best-effort website action, independent of local recommendation feedback.
    func upvote(id: Int) async throws {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("index.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "page", value: "post"), .init(name: "s", value: "vote"),
            .init(name: "id", value: String(id)), .init(name: "type", value: "up")
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("https://rule34.xxx/index.php?page=post&s=view&id=\(id)", forHTTPHeaderField: "Referer")
        _ = try await Self.transport.load(request)
    }

    func fetchCatalogPreview(id: Int) async throws -> ExternalGalleryDetail {
        if let cached = await Self.cache.preview(id) { return cached }
        return try await fetchGalleryDetail(id: id)
    }

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        if let cached = await Self.cache.value(id) { return cached }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("index.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "page", value: "post"), .init(name: "s", value: "view"), .init(name: "id", value: String(id))]
        let data = try await Self.load(components.url!)
        guard let html = String(data: data, encoding: .utf8) else { throw Rule34Error.invalidPage }
        let detail = try Self.parseDetail(html, id: id)
        await Self.cache.insert(detail)
        return detail
    }

    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        throw Rule34Error.unsupportedMedia
    }

    static func searchTag(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
    }

    private static func load(_ url: URL) async throws -> Data {
        try await transport.load(URLRequest(url: url))
    }

    private struct Suggestion: Decodable {
        let label: String
        let value: String
        let type: String
    }

    static func parseListing(_ html: String, offset: Int) throws -> (ids: [Int], nextCursor: String?) {
        guard html.contains("post-list") else { throw Rule34Error.invalidPage }
        var ids: [Int] = []
        var seen = Set<Int>()
        for card in matches(#"<span\b[^>]*\bclass\s*=\s*["'][^"']*\bthumb\b[^"']*["'][^>]*>([\s\S]*?)</span>"#, in: html) {
            for anchor in matches(#"(<a\b[^>]*>)"#, in: card) {
                guard let href = attributes(anchor)["href"], let url = resolveURL(href),
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let raw = components.queryItems?.first(where: { $0.name == "id" })?.value,
                      let id = Int(raw), seen.insert(id).inserted else { continue }
                ids.append(id)
            }
        }
        // Follow real pagination links instead of manufacturing a page count.
        let offsets: [Int] = matches(#"(<a\b[^>]*>)"#, in: html).compactMap { anchor in
            guard let href = attributes(anchor)["href"], let url = resolveURL(href),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = components.queryItems?.first(where: { $0.name == "pid" })?.value,
                  let next = Int(raw), next > offset else { return nil }
            return next
        }
        return (ids, ids.isEmpty ? nil : offsets.min().map(String.init))
    }

    static func parseDetail(_ html: String, id: Int) throws -> ExternalGalleryDetail {
        guard let videoElement = first(#"(<video\b[^>]*>)"#, in: html) else { throw Rule34Error.unsupportedMedia }
        let sources = matches(#"(<source\b[^>]*>)"#, in: html).map(attributes)
        let videoAttributes = attributes(videoElement)
        let source = sources.first { ($0["type"] ?? "").lowercased() == "video/mp4" }
            ?? sources.first { ($0["src"] ?? "").lowercased().contains(".mp4") }
        guard let rawURL = source?["src"] ?? videoAttributes["src"], let url = resolveURL(rawURL),
              url.path.lowercased().hasSuffix(".mp4") else { throw Rule34Error.unsupportedMedia }
        let poster = videoAttributes["poster"].flatMap(resolveURL)

        var tags: [ExternalGalleryTag] = []
        var artists: [String] = []
        var characters: [String] = []
        var series: [String] = []
        let sidebar = first(#"<ul\b[^>]*\bid\s*=\s*["']tag-sidebar["'][^>]*>([\s\S]*?)</ul>"#, in: html) ?? ""
        for row in matches(#"(<li\b[^>]*>[\s\S]*?</li>)"#, in: sidebar) {
            let category = first(#"tag-type-([a-z]+)"#, in: row) ?? "general"
            let value: String? = matches(#"(<a\b[^>]*>)"#, in: row).compactMap { anchor -> String? in
                guard let href = attributes(anchor)["href"], let link = resolveURL(href) else { return nil }
                return URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "tags" })?.value
            }.first
            guard let value, !value.isEmpty else { continue }
            switch category {
            case "artist": artists.append(value)
            case "character": characters.append(value)
            case "copyright": series.append(value)
            default: tags.append(.init(name: value, female: false, male: false))
            }
        }
        let statistics = first(#"<div\b[^>]*\bid\s*=\s*["']stats["'][^>]*>([\s\S]*?)</div>"#, in: html) ?? ""
        let posted = first(#"Posted:\s*([0-9-]+\s+[0-9:]+)"#, in: statistics)
        let title = matches(#"(<input\b[^>]*>)"#, in: html).map(attributes)
            .first(where: { $0["name"] == "title" })?["value"] ?? ""
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalGalleryDetail(
            id: id, site: .rule34,
            title: displayTitle.isEmpty ? "\(artists.first ?? "Rule34") · #\(id)" : displayTitle,
            type: "video", language: nil, tags: tags, artists: artists, groups: [],
            characters: characters, series: series, related: [], pages: [], coverURL: poster,
            posted: posted, parentId: nil, visible: nil, fileSize: nil,
            favoritedCount: nil, ratingAverage: nil, ratingCount: nil, comments: [],
            video: ExternalVideo(url: url, posterURL: poster, headers: mediaHeaders)
        )
    }

    /// Listing cards already contain their poster; rendering a grid needs no post request.
    private static func parseCatalogPreviews(_ html: String) -> [ExternalGalleryDetail] {
        matches(#"<span\b[^>]*\bclass\s*=\s*["'][^"']*\bthumb\b[^"']*["'][^>]*>([\s\S]*?)</span>"#, in: html).compactMap { card in
            guard let anchor = first(#"(<a\b[^>]*>)"#, in: card),
                  let href = attributes(anchor)["href"], let link = resolveURL(href),
                  let rawID = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = Int(rawID), let image = first(#"(<img\b[^>]*>)"#, in: card),
                  let rawCover = attributes(image)["src"], let cover = resolveURL(rawCover) else { return nil }
            return ExternalGalleryDetail(
                id: id, site: .rule34, title: "Rule34 · #\(id)", type: "video", language: nil,
                tags: [], artists: [], groups: [], characters: [], series: [], related: [], pages: [],
                coverURL: cover, posted: nil, parentId: nil, visible: nil, fileSize: nil,
                favoritedCount: nil, ratingAverage: nil, ratingCount: nil, comments: []
            )
        }
    }

    private static func resolveURL(_ value: String) -> URL? {
        guard let url = URL(string: decode(value), relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func attributes(_ element: String) -> [String: String] {
        let pattern = #"([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: element, range: NSRange(element.startIndex..., in: element)) {
            guard let key = Range(match.range(at: 1), in: element),
                  let value = Range(match.range(at: 2), in: element) ?? Range(match.range(at: 3), in: element) else { continue }
            result[String(element[key]).lowercased()] = decode(String(element[value]))
        }
        return result
    }

    private static func first(_ pattern: String, in text: String) -> String? { matches(pattern, in: text).first }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func decode(_ value: String) -> String {
        var text = value
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }
}

private actor Rule34DetailCache {
    private var entries: [Int: (date: Date, detail: ExternalGalleryDetail)] = [:]
    private var previews: [Int: (date: Date, detail: ExternalGalleryDetail)] = [:]

    func preview(_ id: Int) -> ExternalGalleryDetail? {
        if let detail = value(id) { return detail }
        guard let entry = previews[id], Date().timeIntervalSince(entry.date) < 300 else { return nil }
        return entry.detail
    }

    func insertPreviews(_ details: [ExternalGalleryDetail]) {
        for detail in details { previews[detail.id] = (Date(), detail) }
        if previews.count > 192 {
            for key in previews.sorted(by: { $0.value.date < $1.value.date }).prefix(previews.count - 192).map(\.key) {
                previews.removeValue(forKey: key)
            }
        }
    }

    func value(_ id: Int) -> ExternalGalleryDetail? {
        guard let entry = entries[id], Date().timeIntervalSince(entry.date) < 300 else { return nil }
        return entry.detail
    }

    func insert(_ detail: ExternalGalleryDetail) {
        entries[detail.id] = (Date(), detail)
        if entries.count > 96, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

/// One shared request budget covers search, metadata, suggestions and votes.
/// Actor reentrancy is handled by rechecking the deadline after every suspension.
private actor Rule34Transport {
    private let session: URLSession
    private var nextStart = Date.distantPast

    init(headers: [String: String]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = headers
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 25
        session = URLSession(configuration: configuration, delegate: Rule34RedirectDelegate(), delegateQueue: nil)
    }

    func load(_ original: URLRequest, cookieOverride: String? = nil) async throws -> Data {
        for attempt in 0..<4 {
            var request = original
            request.httpShouldHandleCookies = false
            while true {
                while nextStart > Date() {
                    let delay = nextStart.timeIntervalSinceNow
                    if delay > 20 { throw Rule34Error.rateLimited(delay) }
                    try await Task.sleep(for: .seconds(max(0.01, delay)))
                }
                let cookie: String?
                if let cookieOverride { cookie = cookieOverride }
                else { cookie = await Rule34AuthStore.shared.cookieHeader(for: request.url) }
                try Task.checkCancellation()
                // Reading MainActor state is also a suspension point. Another
                // request may have reserved the budget while we awaited cookies.
                guard nextStart <= Date() else { continue }
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                nextStart = Date().addingTimeInterval(1.1)
                break
            }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw Rule34Error.badResponse(0) }
            if http.statusCode == 429 {
                let delay = Self.retryDelay(http, fallback: Double(attempt + 1) * 3)
                nextStart = max(nextStart, Date().addingTimeInterval(delay))
                if attempt == 3 { throw Rule34Error.rateLimited(delay) }
                continue
            }
            if http.statusCode == 403, String(decoding: data, as: UTF8.self).contains("CAPTCHA") {
                throw Rule34Error.verificationRequired
            }
            guard http.statusCode == 200 else { throw Rule34Error.badResponse(http.statusCode) }
            return data
        }
        throw Rule34Error.rateLimited(3)
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

private final class Rule34RedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.scheme != "https" || request.url?.host?.lowercased() != "rule34.xxx" {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        redirected.httpShouldHandleCookies = false
        completionHandler(redirected)
    }
}
