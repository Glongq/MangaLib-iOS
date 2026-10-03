import Foundation

/// Errors for ThreeHentaiProvider — the same deliberately simple scheme as
/// HitomiError/EHentaiError.
enum ThreeHentaiError: Error {
    case badResponse
}

/// Advanced search fields — added by direct request (Sep 1). For 3hentai
/// HAR confirms exactly ONE thing: a comma in `q=` means AND of several
/// tags (`q=anal,diaper` → "Anal,diaper", both tags counted at once, see
/// the capabilities.hasSearch doc-comment) — HAR does NOT separately
/// confirm free text combined with tags via a comma (the live example had
/// two bare tags, not text+tag); we combine them by analogy with that same
/// comma-AND, since it's the only confirmed combination mechanism on the
/// site. There are no Parodies/Characters/Artists/Groups fields here —
/// honestly just Tags, the only confirmed dimension.
///
/// The EXCLUSIVE scheme, shared by all sites with advanced fields (see
/// ExternalSearchView.resolvedQuery): if the Tags field or the field's own
/// search is filled in, the screen's general search field stops
/// participating for 3hentai.
struct ThreeHentaiAdvancedQuery {
    var search: String = ""
    var tags: [String] = []

    var isEmpty: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty && tags.isEmpty
    }

    /// Called ONLY when !isEmpty (see ExternalSearchView.resolvedQuery).
    func encoded() -> String {
        var parts = [search.trimmingCharacters(in: .whitespaces)]
        parts.append(contentsOf: tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return parts.filter { !$0.isEmpty }.joined(separator: ",")
    }
}

/// Client for 3hentai.net — its OWN, fully separate implementation, not
/// connected in any way to MangaNetworkService/LibSite/HitomiProvider/
/// EHentaiProvider. All URLs/formats below are confirmed by real HAR
/// (`de8dcedb-ProxyPin830_21_46_50.har`, evening of Aug 30) — a fresh
/// analysis done specifically for this integration, verified with a live
/// `curl` (unlike hitomi.la, this site is reachable directly from this
/// sandbox, with no domain-fronting tricks).
///
/// This site is SIMPLER than both previous ones: plain server-rendered
/// HTML (no JS rendering of the listing, unlike hitomi.la, and no gg.js
/// formula for full-size pages, unlike hitomi as well) — reading images
/// don't even need a separate network request (unlike e-hentai, where the
/// H@H node link is temporary and can only be obtained with a live
/// request): the image CDN's host + internal ID only needs to be pulled
/// once from the cover on the title page (see extractHost(from:)), after
/// which both the thumbnail and the full size are built by a PURE formula
/// (see pageImageURL).
///
/// `ru.` is not domain-fronting (unlike `ltn.gold-usergeneratedcontent.
/// net` for hitomi) — it's just the site's language version (the same
/// content as on plain `3hentai.net`, confirmed by HAR — the canonical
/// links on the pages themselves point to `ru.3hentai.net`); it's used
/// here only so that the HTML's own interface strings (which don't go
/// into the code, only structure/attributes) are readable during live
/// testing.
struct ThreeHentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .threeHentai
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // A full alphabetical index — tags/series/characters/
        // artists/groups, all 5 confirmed by HAR (letter-picker + the
        // `filter-elem` list, the same markup pattern as hitomi.la, just
        // different CSS classes), see fetchTagIndex.
        hasTagBrowser: true,
        // A REAL full-text search (`?q=`), unlike hitomi
        // (which has an honest stub command) — confirmed by HAR: free
        // text, comma as AND of several tags (`q=anal,diaper` →
        // "Anal,diaper", 125 results — both tags counted at once), the
        // `tag:value` command. The progression ("several words in a row"
        // — how much of that is AND vs OR/a whole phrase) isn't confirmed
        // by live HAR beyond one example — we honestly won't claim the
        // exact semantics beyond what's visible.
        hasSearch: true,
        // EXACTLY one category is confirmed live (`doujinshi`) — the site
        // clearly supports others too (Manga/Artist CG/... — the usual
        // taxonomy for such sites), but without a real category list in
        // HAR we honestly won't make one up (see the report to the user)
        // — so there's no CATEGORY switcher here. The flag is nonetheless
        // `true` — the same trick as hentaiPill (see its doc-comment):
        // here it's the gate for the "Filters" button in general, under
        // which there's now ThreeHentaiAdvancedFieldsPicker (its own
        // search field + Tags, see ThreeHentaiAdvancedQuery in this
        // file).
        hasCategoryFilter: true,
        // The page number is LITERALLY a piece of the path
        // (`/category/doujinshi/2`, `/tags/{slug}/2`,
        // `/search?q=...&page=2`) — an exact jump, the same principle as
        // hitomi (unlike e-hentai, where range= is approximate).
        hasPageJump: true,
        // Popular: 24 hours/week/all time — confirmed by HAR
        // (`?sort=popular-24h`/`popular-7d`/`popular`), see SortOption.
        // Only on listing pages (tag/category/search) — the main
        // "Recently" feed has NO sorting (no `.sorts` block in HAR), so
        // an empty query honestly ignores sortKey (see
        // fetchIdsBySearch).
        hasSortOptions: true,
        // The site itself REALLY does have an account/favorites/history
        // (confirmed by HAR — `/user/panel`, `toggle-favorite`), but this
        // integration doesn't log into an account, so it's still false
        // here — the same principle as EHentaiProvider (see its
        // doc-comment).
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // Not a single comment-related markup fragment on any saved
        // title card in HAR — honestly false, we don't make it up (the
        // same principle as hitomi).
        hasComments: false
    )

    /// A separate session — doesn't overlap with any other provider.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://ru.3hentai.net/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://ru.3hentai.net"

    // MARK: Alphabetical index (tags/series/characters/artists/groups)

    private static func tagKindPath(_ kind: ExternalTagKind) -> String {
        switch kind {
        case .tags: return "tags"
        case .series: return "series"
        case .characters: return "characters"
        case .artists: return "artists"
        case .groups: return "groups"
        }
    }

    /// "#" is a separate bucket for symbols/digits (confirmed by HAR:
    /// `?letter=%23`), just like "123" for hitomi — except there it's
    /// part of the path, here it's a query parameter. `letter.isNumber`
    /// is the same signal that ExternalTagBrowserView already sends
    /// instead of "#" (see HitomiProvider.fetchTagIndex — the same
    /// trick).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        let letterParam = letter.isNumber ? "#" : String(letter).lowercased()
        let encodedLetter = letterParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? letterParam
        let basePath = Self.tagKindPath(kind)
        var result: [ExternalTagEntry] = []
        var seenSlugs = Set<String>()
        // Busy letters (e.g. "y" for artists/groups) really do paginate
        // (`?letter=y&page=2`, confirmed by HAR) — we pull all pages in a
        // row, not just the first one, otherwise the list would look
        // truncated for no visible reason. A reasonable cap (20 pages =
        // max ~500 entries) is just to avoid an infinite loop on
        // unexpected markup.
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
    /// NAME</a></span>` — the common format for tags/series/characters/
    /// artists/groups (confirmed by HAR on all five), differing only in
    /// `basePath` within the href itself. `data-qty` is an abbreviated
    /// number ("217k"), not always an integer — taken as-is into
    /// `count` if it doesn't parse as an Int (see parseCount below).
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

    /// "217k"/"87k"/"0" → an approximate integer (the site abbreviates
    /// large numbers with the letter "k" = ×1000; "m" hasn't been seen
    /// in HAR, but it's supported too just in case).
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

    /// Autocomplete isn't confirmed by HAR — not a single JSON/XHR
    /// endpoint for type-ahead search turned up (only the plain HTML
    /// `/search?q=` page as a whole) — honestly empty, the same
    /// principle as EHentaiProvider.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: Sorting

    /// Reuses hitomi's VOCABULARY (`HitomiProvider.SortOption`) — not
    /// because the semantics are identical, but because the shared
    /// sorting UI (see ExternalCatalogGridView.sortSelection/
    /// sortMenuButton) is currently hard-wired to this exact enum (the
    /// single source of options for the whole screen, not per-provider).
    /// 3hentai really has ONLY 3 tiers (24 hours/week/all time, confirmed
    /// by HAR) — `.dateAdded` maps to "no sorting" (same as hitomi),
    /// `.popularToday`/`.popularWeek` map to the confirmed
    /// `popular-24h`/`popular-7d`, and `.popularMonth`/`.popularYear`
    /// (menu items that 3hentai doesn't have at all) both honestly fall
    /// back to `popular` (all time), not to an error and not silently
    /// ignored — the closest real existing option in meaning. See the
    /// report to the user — an imperfect mapping; a separate per-site
    /// sorting UI wasn't built for this.
    private static func sortQueryValue(for sortKey: String?) -> String? {
        guard let option = sortKey.flatMap(HitomiProvider.SortOption.init(rawValue:)) else { return nil }
        switch option {
        case .dateAdded: return nil
        case .popularToday: return "popular-24h"
        case .popularWeek: return "popular-7d"
        case .popularMonth, .popularYear: return "popular"
        }
    }

    // MARK: Title list by tag/category

    private static func tagBasePath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        // female/male on 3hentai are NOT a separate namespace: gender is
        // already "baked into" the slug itself (`big-breasts-female`/
        // `big-breasts-male`, see ExternalTagBrowserView — entry.slug
        // for .tags already carries this suffix, nothing needs to be
        // added here, unlike hitomi).
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

    /// Normalizes ANY input text into the site's real URL slug —
    /// lowercase, any RUN of non-alphanumeric characters collapses into
    /// ONE hyphen (not character by character), edges are trimmed.
    /// Confirmed by HAR on real name→slug pairs: "big breasts" →
    /// "big-breasts", "focalors | lady furina" → "focalors-lady-furina"
    /// (the spaces around "|" together with "|" itself — ONE run →
    /// ONE hyphen, not three), "y. ginjho the 3rd" → "y-ginjho-the-3rd".
    /// IDEMPOTENT on an already-formed slug (the ones coming from
    /// ExternalTagBrowserView/entry.slug are already in this shape —
    /// re-normalizing changes nothing, since hyphens themselves are
    /// non-alphanumeric characters and stay single) — but a value from
    /// the title card's CHIP (see ExternalGalleryDetailView, tapping a
    /// tag/genre, Aug 31) carries only the PLAIN display name, and
    /// without this normalization such requests would 404.
    private static func slugify(_ text: String) -> String {
        var slug = ""
        var lastWasSeparator = true // true — so we don't start with a hyphen
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

    /// Gender — the `-female`/`-male` suffix IN the slug itself (see the
    /// tagBasePath doc-comment) — added only if it's not ALREADY there
    /// (a value from ExternalTagBrowserView/entry.slug for tags in the
    /// "Tags" category already carries it by itself, adding it again
    /// would double the suffix; a value from the title card's CHIP is
    /// only the plain tag name, without a suffix, see
    /// ExternalGalleryDetailView).
    private static func withGenderSuffix(_ slug: String, namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .female where !slug.hasSuffix("-female"): return slug + "-female"
        case .male where !slug.hasSuffix("-male"): return slug + "-male"
        default: return slug
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let basePath = Self.tagBasePath(for: namespace)
        let slug = Self.withGenderSuffix(Self.slugify(value), namespace: namespace)
        let encodedValue = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        var urlString = "\(Self.baseURL)/\(basePath)/\(encodedValue)"
        let page = Int(cursor ?? "1") ?? 1
        if page > 1 { urlString += "/\(page)" }
        if let sortValue = Self.sortQueryValue(for: sortKey) { urlString += "?sort=\(sortValue)" }
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// The cursor is just the page number (the exact same scheme as
    /// hitomi, see HitomiProvider.cursorForPage) — here the page is
    /// directly in the URL path, not a byte offset, so it's even
    /// simpler: the string is the number as-is, no arithmetic.
    func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return String(page)
    }

    /// An empty query is "Recently" (the home page `/`, pagination is
    /// `/{page}`, no sorting — the feed itself doesn't have any, see
    /// the capabilities.hasSortOptions doc-comment). A non-empty query
    /// is the usual `?q=` (free text OR a `tag:value` command, just
    /// like on the site itself, see the capabilities.hasSearch
    /// doc-comment).
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

    /// Shared parsing of a listing page (home/category/tag/search — the
    /// same `.doujin-col`/`.cover` markup everywhere) — 25 items per
    /// page, a number fixed by the site (not the `limit` parameter —
    /// the same tradeoff as EHentaiProvider.fetchGalleryList).
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

    // MARK: Title card

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "\(Self.baseURL)/d/\(id)") else { throw ThreeHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ThreeHentaiError.badResponse
        }
        return Self.parseDetail(html: html, id: id)
    }

    /// `https://{host}/d{internalId}/cover.jpg` — extracts the whole
    /// `{host}/d{internalId}` (e.g. "s1.3hentai.net/d2441052") — used
    /// as-is both for thumbnails (`/{n}t.jpg`) and for full-size pages
    /// (`/{n}.jpg`, see pageImageURL) — both live on the SAME host+ID
    /// as the cover, confirmed by HAR (the host is sometimes `.net`,
    /// sometimes `.xyz` — we take literally whatever the server
    /// actually returned IN THIS response, we don't hardcode either
    /// variant).
    private static func extractStorageKey(from html: String) -> String? {
        firstMatch(in: html, pattern: #"data-src="https://(s\d+\.3hentai\.(?:net|xyz)/d\d+)/cover\.jpg""#)
    }

    /// The section heading above the tags/category/language block
    /// (`Категории:`/`Серия:`/`Персонажи:`/`Теги:`) is deliberately NOT
    /// parsed by that text (it would depend on the site's own Russian
    /// localization, which is fragile) — instead routing is done by the
    /// FIRST path segment in the href (`category`/`series`/`characters`/
    /// `artists`/`groups`/`language`/`tags`) — robust against the
    /// interface language and against which exact
    /// `<div class="tag-container">` the link ended up in.
    private static func parseDetail(html: String, id: Int) -> ExternalGalleryDetail {
        // `.*?` (dotall) + stripping nested tags, NOT `[^<]*` — the site
        // wraps a middle chunk of some titles in
        // `<span class="middle-title">...</span>` (confirmed by a live
        // curl on Aug 30 on this very same ID — the HAR for the same
        // title somehow didn't contain it, but the live fetch does),
        // `[^<]*` wouldn't match at all on such markup (it would break
        // at the first `<`), which is why the title silently fell back
        // to "Untitled" on any such heading.
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
                    // Gender — by the slug's SUFFIX (`-female`/`-male`),
                    // not by the display text (which contains
                    // " (female)"/" (male)" in parentheses, see
                    // strippedTagName below) — more reliable, the slug
                    // is always ASCII and free of whitespace/casing
                    // variations.
                    let female = slug.hasSuffix("-female")
                    let male = slug.hasSuffix("-male")
                    let cleanName = strippedTagName(name)
                    tags.append(ExternalGalleryTag(name: cleanName, female: female, male: male))
                default: break
                }
            }
        }

        // Full-size/thumbnail pages — see extractStorageKey
        // (host+internal ID) + the highest page number among the
        // `{n}t.jpg` thumbnails in the preview strip (there's no
        // separate "related"/similar galleries section on this same
        // page that could give false high numbers — see the type's
        // doc-comment above).
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
            // There's no separate "similar"/related ID list on the
            // title page (not a single related markup fragment in HAR,
            // unlike hitomi) — honestly empty, same as e-hentai.
            related: [],
            pages: pages,
            coverURL: coverURL,
            posted: posted,
            // 3hentai physically doesn't have these fields
            // (e-hentai-specific, see the plan PART B.2) — honestly
            // nil/[], we don't make it up.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: nil,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    /// "big breasts (female)" → "big breasts" — the site's own display
    /// text appends gender in parentheses (see the
    /// `tag_display = tag.replace(...)` equivalent for hitomi, same
    /// principle); female/male are already extracted separately from
    /// the slug (see parseDetail), so in `name` this information would
    /// be redundant (the UI already labels the block "Female"/"Male",
    /// see ExternalGalleryDetailView.aboutTab).
    private static func strippedTagName(_ name: String) -> String {
        guard let range = name.range(of: #"\s*\((?:female|male)\)\s*$"#, options: .regularExpression) else { return name }
        return String(name[name.startIndex..<range.lowerBound])
    }

    // MARK: Image URLs

    /// A pure formula (host+internalId already in `page.key`, see
    /// extractStorageKey) — no network, like hitomi (unlike e-hentai,
    /// where there's a real request per page), just wrapped in async
    /// for the sake of the shared protocol.
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: "https://\(page.key)/\(page.index).jpg") else {
            throw ThreeHentaiError.badResponse
        }
        return url
    }

    // MARK: Utilities

    private static func firstMatch(in html: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 2,
              let matchRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[matchRange])
    }

    /// Strips nested HTML tags (e.g. `<span class="middle-title">
    /// ...</span>` inside the title, see parseDetail) — leaves only the
    /// text content, the same trick as EHentaiProvider.parseComments
    /// for comment text.
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
