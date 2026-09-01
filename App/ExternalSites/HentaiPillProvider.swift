import Foundation

/// Errors for HentaiPillProvider — the same deliberately simple scheme as
/// the other providers in this folder.
enum HentaiPillError: Error {
    case badResponse
}

/// Advanced search field — added by direct request (Sep 1), but hentaipill's
/// shape is fundamentally DIFFERENT from the other sites': there is NO single
/// search parameter you could append `tag:value` to —
/// Tags/Parodies/Characters/Artists are SEPARATE, incompatible routes
/// (`/genre/{slug}`, `/parody/{slug}`, `/character/{slug}`, `/artist/
/// {slug}` — see the HentaiPillProvider.capabilities.hasCategoryFilter
/// doc-comment), and HAR confirms not a single "tag + text" or "tag + tag" combination.
/// Honestly — this isn't a list of chips, it's a choice of EXACTLY ONE
/// dimension (Tags/Parodies/Characters/Artists) and ONE value for it;
/// there's also no separate text search field of its own, apart from the shared one —
/// the shared field is already a direct `/search?q=` (see ExternalSearchView —
/// `.searchable()` on hentaipill works as usual).
///
/// EXCLUSIVE scheme, shared across all sites with advanced fields: if
/// value is not empty, the screen's shared search field for hentaipill stops
/// being used — the request BYPASSES fetchIdsBySearch, going directly through
/// fetchIdsByTag(namespace: kind, value: value, ...) (see
/// ExternalSearchView.resolvedQuery — this is the only site where
/// the advanced field produces ExternalCatalogQuery.tag(...) rather than .search(...)).
struct HentaiPillAdvancedQuery {
    var kind: ExternalTagNamespace = .tag
    var value: String = ""

    var isEmpty: Bool { value.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// hentaipill.com client — its OWN, fully separate implementation. All the URLs/
/// formats below are confirmed by the user's real HAR (Aug 31,
/// `ProxyPin831_22_09_01.har`) AND double-checked with a live curl from this sandbox
/// (unlike imhentai, the site is reachable DIRECTLY — no Cloudflare
/// challenge, no domain fronting, not a single 403 on any of the checked
/// paths).
///
/// Simpler than the other four sites: it has NO separate "reader" at all —
/// the title card (`/gallery/g{id}`) renders ALL pages
/// right away as one long `<img>` list (real, ready-made absolute
/// URLs right in the markup, with width/height), and at the bottom of the same page is a "You may
/// also like" block with similar titles. No sharding formula (hitomi/3hentai),
/// no temporary signed links (e-hentai), no separate per-page chunk request —
/// just take what's already sitting in the card's HTML.
///
/// IMPORTANT regarding the image CDN (`b{N}.hentaipill.{com,me,...}`) — the domain/TLD
/// GENUINELY drifts even between two consecutive live requests (the user's HAR
/// showed `.com`, a live curl at the time of analysis already showed `.me`,
/// for the same internal picture id) — so there's NO host+id formula here;
/// the image URL is taken WHOLESALE, as-is, from fresh HTML at the time of the
/// card request, never cached or reconstructed separately (see
/// parseDetail — `page.key` already holds the ready-made absolute URL).
struct HentaiPillProvider: ExternalSiteProvider {
    let site: ExternalSite = .hentaiPill
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // A full alphabetical index — Tags(genre)/Parodies/
        // Characters/Artists, all 4 confirmed by HAR+live curl (see
        // fetchTagIndex). There is NO Group section on the site AT ALL (no
        // menu entry, no `/group/...` links on any page) — honestly [].
        hasTagBrowser: true,
        // A REAL full-text search (`/search?q=`) — unlike
        // imhentai, there's ONE parser for the whole site, plain text finds
        // exactly what you're looking for (confirmed by HAR: "genshin"/"anal" — both
        // returned genuinely relevant cards). An empty query → `/search?q=`
        // returns 404 (double-checked with a live curl) — so an empty input here
        // substitutes the home feed (`/`), see fetchIdsBySearch.
        hasSearch: true,
        // There's no EHentaiCategory-like bitmask category toggle
        // (Category — `/category/{slug}` is a SEPARATE, incompatible route,
        // not a single example in HAR combines it with `?q=`/a tag) — but
        // the flag is repurposed (the same trick used for imhentai/simplyHentai)
        // as a general gate for "there is a «Filters» sheet": here it opens a choice
        // of ONE dimension (Tags/Parodies/Characters/Artists) + a value
        // (see the HentaiPillAdvancedQuery doc-comment), not categories.
        hasCategoryFilter: true,
        // The page number is LITERALLY part of the path (`/genre/{slug}/{page}`,
        // `/category/{slug}/{page}`) or a query param (`/search?q=...&page=N`) —
        // an exact jump, double-checked with a live curl. EXCEPTION: the home
        // feed (`/`) and `/popular` visually show NO pagination, and
        // `?page=2` there genuinely returns the SAME IDs as page 1
        // (double-checked with a live curl, line-by-line comparison) — we honestly
        // treat this as the single non-expandable page, see
        // fetchIdsBySearch(query: "").
        hasPageJump: true,
        // Rising/Popular — SEPARATE fixed top-N feeds (see
        // the capabilities.hasPageJump doc-comment — `?page=` doesn't work on
        // them), not a sort applied on top of search/tag results — the
        // search/tag/category pages themselves have no `.sorts` block in HAR at all.
        // Honestly false, we don't make up a sort UI that doesn't exist.
        hasSortOptions: false,
        // The site GENUINELY has Favorites/History (menu entries, an
        // "Add to my favorites" button on the card) — but, like the other
        // external sites in this client, the integration doesn't sign into an account,
        // so this stays false regardless (the same principle, see the doc-comment on
        // ImhentaiProvider.capabilities).
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // Not a single comment-related markup fragment on any
        // saved title card in HAR — honestly false, we don't make one up.
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

    // MARK: Alphabetical index (Tags/Parodies/Characters/Artists)

    private static func tagKindPath(_ kind: ExternalTagKind) -> String? {
        switch kind {
        case .tags: return "genre"
        case .series: return "parody"
        case .characters: return "character"
        case .artists: return "artist"
        // There's no Group section on the site at all — honestly nil, not a made-up path.
        case .groups: return nil
        }
    }

    /// Unlike hitomi/3hentai/imhentai, the list here is NOT split into
    /// letters server-side — ONE request (`/genre`, `/parody`, `/character`,
    /// `/artist`) returns everything at once (confirmed by a live curl: `/genre` —
    /// 1526 tags on one page, `/parody` — 3424, with NO pagination).
    /// `Characters`/`Artists` — the site ITSELF caps the results at the first ~5000
    /// (17110/24258 claimed in the "N elements" header, but only 5002 links
    /// actually appear in the markup; no letter-based pagination/limiting
    /// either) — honestly an incomplete list for these two sections, not our
    /// shortcoming but the site's own ceiling. letter — filtered
    /// LOCALLY out of the already-downloaded full list (namespace.isNumber →
    /// the digits bucket, the same signal used by the other providers).
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
    /// ({count})</span>` — the same format on all four sections
    /// (genre/parody/character/artist), confirmed by HAR+live curl.
    /// A genre tag's display name CAN carry a " (female)"/
    /// " (male)" suffix (e.g. "big breasts (female)") — here it is NOT stripped
    /// (unlike on the title card, see stripGenderSuffix) — this is a
    /// standalone entry in the alphabetical index, exactly as it appears on
    /// the site; stripping is only needed where female/male is a separate boolean
    /// flag (ExternalGalleryTag).
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

    /// A REAL AJAX endpoint `/tag-search-ajax/{tags|characters|parodies}`
    /// is confirmed by HAR (POST `query=.../_token=...` → live matches,
    /// by substring, not just by prefix). But a live curl test (Aug 31:
    /// a plain GET → cookie jar → `_token` from the hidden HTML field → a POST with
    /// the same cookies) still gave "CSRF token mismatch" — the token
    /// embedded in THAT SPECIFIC GET response apparently doesn't match
    /// what the server expects for the SAVED session cookie (two
    /// different points in the PHP session's initialization; digging into this further
    /// would take a real browser/DevTools, not curl). We're not shipping
    /// half-working code to production that would silently 419 on every
    /// input — we honestly return []. fetchTagIndex (the full list in one
    /// request, with no cookie at all) already covers the main use case
    /// for suggestions while typing a tag.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: List of titles by tag/series/character/artist

    private static func tagBasePath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male: return "genre"
        case .series: return "parody"
        case .character: return "character"
        case .artist: return "artist"
        // There's no Group on the site — ExternalGalleryDetail.groups is ALWAYS
        // [] here (see parseDetail), so a chip with this namespace will never
        // show up in the UI and will never reach this — a safe fallback to "genre".
        case .group: return "genre"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `value` — either a ready-made slug (from ExternalTagBrowserView/
    /// entry.slug — already includes the "-female"/"-male" suffix on its
    /// own, if one is needed), or a plain display name from a gallery-card
    /// chip (ExternalGalleryDetailView, namespace .female/.male — then the
    /// suffix still needs to be added, see withGenderSuffix). The slugify/
    /// suffix formula is the same as 3hentai/imhentai (the same real site
    /// format, confirmed via name→slug pairs from HAR: "dulce-q | q" →
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

    // MARK: Search

    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// Empty query → the home feed `/` — NOT actually paginated (see the
    /// capabilities.hasPageJump doc-comment, re-checked with a live curl:
    /// `/?page=2` returns the SAME IDs as `/`), so here nextCursor is
    /// honestly ALWAYS nil, and no request past the first page is ever
    /// made. Non-empty → `/search?q=...` (re-checked with a live curl:
    /// `/search?q=` empty returns 404, so the empty branch has to stay
    /// separate).
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

    /// Shared parser for a result-list page (home/category/tag/search — the
    /// card markup `<a href=".../gallery/g{id}">...` is the same everywhere).
    /// `allowsNextPage: false` — see the fetchIdsBySearch(query: "") doc-comment.
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

    /// `rel="next"` on the "»" pagination button — confirmed by HAR + live
    /// curl on category/genre/parody/character/artist/search; ABSENT on
    /// `/`/`/popular` (they have no pagination at all, see allowsNextPage).
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

    /// The metadata block headers (Parodies:/Characters:/Tags:/Languages:)
    /// are NOT parsed by their text — routing is done by the FIRST href
    /// segment (genre/parody/character/artist/language), the same
    /// localization-resistant approach as ImhentaiProvider/ThreeHentaiProvider.
    private static func parseDetail(html: String, id: Int) -> ExternalGalleryDetail {
        let title = firstMatch(in: html, pattern: #"<h1>(.*?)</h1>"#, options: [.dotMatchesLineSeparators])
            .map(stripInnerTags).map(decodeHTMLEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"

        // "2026-08-31 03:08" — right after the clock icon in the header,
        // before the category link (confirmed by HAR — see the type doc-comment).
        let posted = firstMatch(
            in: html,
            pattern: #"reading-page-header-data">\s*<span>[\s\S]*?</svg>([^<]+)</span>"#
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let type = firstMatch(in: html, pattern: #"href="https://hentaipill\.com/category/[^"]+">([^<]+)</a>"#)
            .map(decodeHTMLEntities) ?? ""

        // Parsing tags/parodies/characters/language — ONLY in the region
        // BEFORE the reading pages themselves start, otherwise the later
        // "You may also like" block (its own tag list belonging to unrelated
        // similar titles — not the case here since it comes after
        // reading-pages-content, but the boundary is still needed for
        // safety) would get mixed into THIS title's metadata.
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

        // Images — already FULLY-FORMED absolute URLs right in the markup
        // (see the type doc-comment) — no formula/CDN sharding needed,
        // unlike hitomi/e-hentai/3hentai/imhentai. width/height are also
        // right there in the attributes, useful for the reader to
        // precompute layout.
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

        // `cover: "https://b1.hentaipill.me/picture/{id}-thumb.jpg"` — a JS
        // variable near the top of the page, the same CDN host as the
        // reading pages (see the type doc-comment about the floating
        // domain/TLD).
        let coverURL = firstMatch(in: html, pattern: #"cover:\s*"([^"]+)""#).flatMap { URL(string: $0) }

        // "You may also like" — the same card markup as the regular grid
        // (see parseGalleryIds), just in its own block at the end of the
        // page — take everything found AFTER the marker, no artificial
        // cap (the block itself is already limited to a reasonable number
        // of cards on the site).
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
            // No groups on the site at all — honestly empty, not made up.
            groups: [],
            characters: characters,
            series: series,
            related: related,
            pages: pages,
            coverURL: coverURL,
            posted: posted,
            // e-hentai-specific fields (Parent/Visible/File Size/Rating) —
            // not confirmed for hentaipill, honestly nil, not made up.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: nil,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    /// "big breasts (female)" → ("big breasts", true, false); "sole female"
    /// → ("sole female", false, false) — the suffix is stripped ONLY when
    /// it's a parenthesized qualifier, not when "female"/"male" is part of
    /// the tag name itself without parentheses (those are distinct, real
    /// tags on the site — see the full /genre list, "sole female"/"sole
    /// male" are separate entries there, not female/male variants of
    /// something else).
    private static func stripGenderSuffix(_ name: String) -> (name: String, female: Bool, male: Bool) {
        if let range = name.range(of: #"\s*\(female\)\s*$"#, options: .regularExpression) {
            return (String(name[name.startIndex..<range.lowerBound]), true, false)
        }
        if let range = name.range(of: #"\s*\(male\)\s*$"#, options: .regularExpression) {
            return (String(name[name.startIndex..<range.lowerBound]), false, true)
        }
        return (name, false, false)
    }

    // MARK: Image URLs

    /// No network call — `page.key` already carries the FULLY-FORMED
    /// absolute URL, taken straight from the HTML at fetchGalleryDetail
    /// time (see its doc-comment about the floating CDN domain/TLD —
    /// deliberately not recomputed here).
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
