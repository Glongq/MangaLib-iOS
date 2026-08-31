import Foundation

/// Errors for ImhentaiProvider — the same deliberately simple scheme as
/// HitomiError/EHentaiError/ThreeHentaiError.
enum ImhentaiError: Error {
    case badResponse
}

/// Categories on imhentai.com/imhentai.xxx (Manga/Doujinshi/Western/Image Set/
/// Artist CG/Game CG — buttons on `/advsearch/`, confirmed by HAR: `<li
/// onclick="toggle_category('manga')"><input type="hidden" name="m" value="1"
/// />Manga</li>` etc.) — the same semantics as EHentaiCategory: tapping
/// EXCLUDES the category from the listing (all are included by default), hence
/// an `excluded` set here too, not `included` (see ImhentaiCategoryPicker).
///
/// `.bit` — ITS OWN bit range (10...15), NOT overlapping with
/// EHentaiCategory (0...9) — by direct design: `excludedCategoryBits:
/// Int` in the protocol is SHARED across the whole request (see ExternalCatalogGridView.
/// fetchPage — the same bitmask goes into fetchIdsBySearch for EVERY
/// site in a combined listing, see ExternalCombinedCatalogView), so
/// if e-hentai AND imhentai are enabled at the same time, one Int has to carry
/// BOTH exclusion sets at once without colliding — non-overlapping bit
/// ranges guarantee that. Each provider masks the incoming bitmask down to
/// ITS OWN known bits (see fetchIdsBySearch below) — other providers' bits in the
/// same Int are simply ignored, and don't corrupt f_cats/m=&d=&...
enum ImhentaiCategory: CaseIterable, Identifiable {
    case manga, doujinshi, western, imageSet, artistCG, gameCG

    var id: Self { self }

    var bit: Int {
        switch self {
        case .manga: return 1 << 10
        case .doujinshi: return 1 << 11
        case .western: return 1 << 12
        case .imageSet: return 1 << 13
        case .artistCG: return 1 << 14
        case .gameCG: return 1 << 15
        }
    }

    /// Query parameter on `/search/`/`/advsearch/` (confirmed by HAR —
    /// `?...&m=1&d=1&w=1&i=1&a=1&g=1&...`) — "1" includes the category in
    /// the listing, "0" excludes it.
    var queryKey: String {
        switch self {
        case .manga: return "m"
        case .doujinshi: return "d"
        case .western: return "w"
        case .imageSet: return "i"
        case .artistCG: return "a"
        case .gameCG: return "g"
        }
    }

    var displayName: String {
        switch self {
        case .manga: return "Manga"
        case .doujinshi: return "Doujinshi"
        case .western: return "Western"
        case .imageSet: return "Image Set"
        case .artistCG: return "Artist CG"
        case .gameCG: return "Game CG"
        }
    }
}

/// Languages on imhentai.com/imhentai.xxx (English/Japanese/Spanish/French/Korean/
/// German/Russian — flag checkboxes on `/advsearch/`) — CONFIRMED by live
/// HAR (Aug 31, third pass): real consecutive requests
/// `/advsearch/?...&en=1&jp=1&es=1&fr=1&kr=1&de=1&ru=1&key=...` →
/// `...&en=1&jp=1&es=0&fr=1&kr=1&de=0&ru=1&key=...` → ... — the same
/// "1" included/"0" excluded semantics, the same tap-to-exclude trick as
/// ImhentaiCategory (all are included by default).
///
/// `.bit` — ITS OWN range (16...22), not overlapping with either EHentaiCategory
/// (0...9) or ImhentaiCategory (10...15) — the same shared Int
/// `excludedCategoryBits` safely carries categories AND languages at once
/// (see the ImhentaiCategory.bit doc-comment — same principle, just another
/// non-overlapping dimension in the same channel, without touching the
/// ExternalSiteProvider protocol).
enum ImhentaiLanguage: CaseIterable, Identifiable {
    case english, japanese, spanish, french, korean, german, russian

    var id: Self { self }

    var bit: Int {
        switch self {
        case .english: return 1 << 16
        case .japanese: return 1 << 17
        case .spanish: return 1 << 18
        case .french: return 1 << 19
        case .korean: return 1 << 20
        case .german: return 1 << 21
        case .russian: return 1 << 22
        }
    }

    /// Query parameter — confirmed by HAR (en/jp/es/fr/kr/de/ru).
    var queryKey: String {
        switch self {
        case .english: return "en"
        case .japanese: return "jp"
        case .spanish: return "es"
        case .french: return "fr"
        case .korean: return "kr"
        case .german: return "de"
        case .russian: return "ru"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "Japanese"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .korean: return "Korean"
        case .german: return "German"
        case .russian: return "Russian"
        }
    }

    /// Flag emoji — purely for recognizability in ImhentaiLanguagePicker, not
    /// confirmed by HAR (these are the site's own icons — its own PNGs, not emoji).
    var flag: String {
        switch self {
        case .english: return "🇬🇧"
        case .japanese: return "🇯🇵"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .korean: return "🇰🇷"
        case .german: return "🇩🇪"
        case .russian: return "🇷🇺"
        }
    }
}

/// Advanced search fields — Tags/Parodies/Artists/Characters/Groups (see
/// `/advsearch/`, user screenshot from Aug 31: "Tags (1/16632)"/"Parodies
/// (0/5014)"/... — a separate field per EACH category, not one shared search
/// string; each can accumulate SEVERAL values at once — the counter next to
/// the heading tracks the ones already added). Assembled into the special
/// syntax `+kind:"value"` (see the ImhentaiProvider.fetchIdsBySearch doc-comment —
/// live HAR CONFIRMS only `tag` — `+tag:"anal"`, exactly what
/// the `/advsearch/` page itself assembles into the hidden `key` field; `parody`/
/// `artist`/`character`/`group` — by symmetry with the real URL segments
/// of a single value's card, `/parody/{slug}/`/`/artist/{slug}/`/
/// `/character/{slug}/`/`/group/{slug}/` (see ImhentaiProvider.
/// tagBasePath) — the same principle as `tag`/`/tag/{slug}/`, but NOT
/// confirmed by a separate HAR specifically for these four. Combining
/// SEVERAL values (several tags at once, tag+parody together) is
/// also not confirmed separately (only ONE active tag showed up in the HAR),
/// assembled by analogy — several `+kind:"..."` separated by a space,
/// as in most similar little search mini-languages.
struct ImhentaiAdvancedQuery {
    /// IMHentai's own search string — per a direct request (Aug 31),
    /// SEPARATE from the general top search field: ordinary text typed
    /// "the same way as for other sites" reliably finds nothing on imhentai (see
    /// the fetchIdsBySearch doc-comment — `/search/` and `/advsearch/` are two
    /// DIFFERENT parsers for the same `key=`). So imhentai doesn't look at
    /// the shared field at all — neither on the single-site screen
    /// (ExternalSearchView.resolvedQuery/displayTitle), nor in the combined
    /// "All sites" catalog (ExternalCombinedCatalogView.query(for:) —
    /// there each site now has its own independent query, see
    /// ExternalCatalogGridView.queryForSite; it used to be one shared query for all
    /// sites at once, and imhentai's tag/search would leak into the other
    /// sites' request — fixed per a direct request). Lives in the same "Filters" as
    /// Tags/Parodies/...
    var searchText: String = ""
    var tags: [String] = []
    var parodies: [String] = []
    var artists: [String] = []
    var characters: [String] = []
    var groups: [String] = []

    var isEmpty: Bool {
        searchText.isEmpty && tags.isEmpty && parodies.isEmpty && artists.isEmpty && characters.isEmpty && groups.isEmpty
    }

    /// Values — as-is, WITHOUT slugification (not a URL path, but a value
    /// inside the quoted `key=` string — in the user's screenshot the chip
    /// shows the human-readable "Tag: Anal", not "anal-female"/slug).
    func clauses() -> [String] {
        func kind(_ name: String, _ values: [String]) -> [String] {
            values.map { "+\(name):\"\($0)\"" }
        }
        return kind("tag", tags) + kind("parody", parodies) + kind("artist", artists) + kind("character", characters) + kind("group", groups)
    }
}

/// Client for imhentai.xxx — ITS OWN, fully separate implementation. All URLs/
/// formats below are confirmed by real HAR (Aug 31, three passes — catalog/
/// search, then a title card + reader captured live from the user's phone)
/// and rechecked with a live curl before committing.
///
/// IMPORTANT (see the report to the user) — the site sits behind Cloudflare: some
/// paths (`/gallery/`, `/view/`, `/groups/`, `/artist/`, `/tags/`, `/advsearch/`,
/// even `/` itself) returned 403 "Just a moment..." in this session's sandbox without
/// a `cf_clearance` cookie (which is only issued after passing the JS check
/// in a real browser — `URLSession` can't pass it). From the user's real
/// device (see the HAR from Aug 31, later pass) the same paths
/// returned 200 without a hitch — but that's browser traffic (JS
/// executes), not the same thing as a plain `URLSession` client even on
/// the same network/IP: Cloudflare distinguishes them by TLS/HTTP
/// fingerprint too, not just IP reputation. It's possible this particular
/// Cloudflare zone is lenient enough (the JS challenge passes unnoticed for any client
/// with a plausible TLS fingerprint) — but there's no guarantee until it's checked
/// live from the app itself.
struct ImhentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .imhentai
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // Alphabetical directory — tags/parodies/artists/characters/groups,
        // all 5 through the SAME `/{section}/{letter}/` scheme (confirmed by
        // HAR only for groups — the other four assumed by symmetry with the
        // nav-bar markup, not verified individually).
        hasTagBrowser: true,
        // Real full-text search (`/search/?key=`), confirmed by
        // HAR (200, real cards in the response).
        hasSearch: true,
        // Manga/Doujinshi/Western/Image Set/Artist CG/Game CG — all 6
        // confirmed by HAR (`/advsearch/`), see ImhentaiCategory.
        hasCategoryFilter: true,
        // Page number — an ordinary `?page=N` query parameter, exact jump
        // (confirmed by HAR — pagination on `/search/`/`/groups/{letter}/`).
        hasPageJump: true,
        // Latest/Popular/Downloaded/Top Rated (`lt`/`pp`/`dl`/`tr`,
        // confirmed by HAR on `/advsearch/`) — reuses the shared UI/vocabulary of
        // HitomiProvider.SortOption (see its mapping below and the same trick used by
        // ThreeHentaiProvider — currently the only source of options for the
        // sort screen, we don't build a separate list here).
        hasSortOptions: true,
        // Account/favorites/downloads REALLY do exist on the site itself
        // (Favourite/Download buttons on the card, confirmed by HAR), but this
        // integration is signed-out — the same principle as EHentaiProvider/
        // ThreeHentaiProvider.
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // The `POST /inc/comments.php` endpoint genuinely exists
        // (confirmed by HAR — 200 on both checked cards), but the
        // response was `empty` on every title checked (not one of them
        // had a single comment) — neither the request-body format nor the
        // response format WITH ACTUAL comments is confirmed, so honestly false,
        // we don't make it up.
        hasComments: false
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://imhentai.xxx/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://imhentai.xxx"

    // MARK: Alphabetical directory (Tags/Parodies/Artists/Characters/Groups)

    private static func letterIndexPath(for kind: ExternalTagKind) -> String {
        switch kind {
        case .tags: return "tags"
        case .series: return "parodies"
        case .characters: return "characters"
        case .artists: return "artists"
        case .groups: return "groups"
        }
    }

    /// Singular form of the same section — part of the URL for a single
    /// value's card (`/tag/{slug}/`, not `/tags/{slug}/`,
    /// confirmed by HAR on a live title card: href="/tag/lolicon/").
    private static func singularSegment(for basePath: String) -> String {
        switch basePath {
        case "tags": return "tag"
        case "parodies": return "parody"
        case "characters": return "character"
        case "artists": return "artist"
        case "groups": return "group"
        default: return basePath
        }
    }

    /// "num" — a separate bucket for digits/symbols (confirmed by HAR:
    /// `/groups/num/`), the same signal (`letter.isNumber`) already sent by
    /// ExternalTagBrowserView instead of "#" (see HitomiProvider/
    /// ThreeHentaiProvider.fetchTagIndex — the same trick).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        let basePath = Self.letterIndexPath(for: kind)
        let singular = Self.singularSegment(for: basePath)
        let letterSlug = letter.isNumber ? "num" : String(letter).lowercased()
        var result: [ExternalTagEntry] = []
        var seenSlugs = Set<String>()
        // Populated letters genuinely paginate (`?page=2`, confirmed by HAR
        // on /groups/a/ — 48 pages) — we pull all pages in sequence, the same
        // trick and cap as ThreeHentaiProvider.fetchTagIndex.
        var page = 1
        while page <= 20 {
            var urlString = "\(Self.baseURL)/\(basePath)/\(letterSlug)/"
            if page > 1 { urlString += "?page=\(page)" }
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
            let entries = Self.parseLetterIndexList(html: html, singularSegment: singular)
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

    /// `<a class="tag_btn ..." href="/{singular}/{slug}/"><h3 class=
    /// "list_tag">{name}[ <span class='split_tag'>...</span>]</h3>
    /// <span class="badge">{count}</span>...` — confirmed by HAR
    /// (/groups/a/). `.dotMatchesLineSeparators` — the h3 content can
    /// wrap onto an optional nested `<span>` (split_tag/alternate
    /// name) before the closing `</h3>`, stripped out via stripInnerTags the
    /// same way as e-hentai comments in EHentaiProvider.
    private static func parseLetterIndexList(html: String, singularSegment: String) -> [ExternalTagEntry] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="/\#(NSRegularExpression.escapedPattern(for: singularSegment))/([^"]+)/"><h3[^>]*>(.*?)</h3>\s*<span class="badge">(\d+)</span>"#,
            options: [.dotMatchesLineSeparators]
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
            let name = decodeHTMLEntities(stripInnerTags(String(html[nameRange]))).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ExternalTagEntry(id: slug, name: name, count: count, slug: slug))
        }
        return result
    }

    private static func hasNextPage(html: String) -> Bool {
        html.range(of: #"href='[^']*page=\d+[^']*'>Next"#, options: .regularExpression) != nil
    }

    /// Autocomplete isn't confirmed by HAR — not a single AJAX request under the
    /// "search tags..."/"search parodies..." fields on `/advsearch/` was caught
    /// (possibly purely client-side filtering of an already-loaded list, not a
    /// network autocomplete) — honestly empty, the same principle as
    /// EHentaiProvider/ThreeHentaiProvider.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: Sorting

    /// Reuses hitomi's dictionary (see its doc-comment on ThreeHentaiProvider
    /// — the same trick: the shared sort UI in ExternalCatalogGridView is currently
    /// hard-wired to HitomiProvider.SortOption). imhentai has 4 REAL
    /// modes — Latest/Popular/Downloaded/Top Rated (`lt`/`pp`/`dl`/`tr`,
    /// confirmed by HAR on `/advsearch/`), not time-window periods, so
    /// the mapping isn't perfect: `.dateAdded` → no parameters (the site already
    /// sorts by date by default), `.popularToday` → `pp`,
    /// `.popularWeek` → `dl` (the closest engagement metric by meaning),
    /// `.popularMonth`/`.popularYear` → `tr` (both — there simply isn't a
    /// third separate metric).
    private static func sortQueryParams(for sortKey: String?) -> [String] {
        guard let option = sortKey.flatMap(HitomiProvider.SortOption.init(rawValue:)) else { return [] }
        let active: String
        switch option {
        case .dateAdded: return []
        case .popularToday: active = "pp"
        case .popularWeek: active = "dl"
        case .popularMonth, .popularYear: active = "tr"
        }
        return ["lt", "pp", "dl", "tr"].map { "\($0)=\($0 == active ? 1 : 0)" }
    }

    // MARK: Title listing by tag/series/artist/group

    private static func tagBasePath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male: return "tag"
        case .series: return "parody"
        case .character: return "character"
        case .artist: return "artist"
        case .group: return "group"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `value` — a slug (from ExternalTagBrowserView/entry.slug — a real one,
    /// or a plain display name from a title card's chip, see
    /// ExternalGalleryDetailView) — slugified the same way as
    /// ThreeHentaiProvider (see its slugify doc-comment — the same formula:
    /// lowercase + any run of non-alphanumeric
    /// characters collapses to a single hyphen), idempotent on slugs that are already
    /// slug-formatted.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let basePath = Self.tagBasePath(for: namespace)
        let slug = Self.slugify(value)
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        var params = Self.sortQueryParams(for: sortKey)
        let page = Int(cursor ?? "1") ?? 1
        if page > 1 { params.append("page=\(page)") }
        var urlString = "\(Self.baseURL)/\(basePath)/\(encodedSlug)/"
        if !params.isEmpty { urlString += "?" + params.joined(separator: "&") }
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Slugification — identical to ThreeHentaiProvider.slugify (the same real
    /// site scheme: lowercase, a run of non-alphanumeric
    /// characters → a single hyphen), confirmed by HAR: "seven of seven"
    /// → "seven-of-seven", "akumu no takuhaibin" → "akumu-no-takuhaibin".
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

    /// Strictly alphanumeric set for percent-encoding the `key=` value
    /// — NOT `.urlQueryAllowed` (that RFC3986 set leaves `+`/`:` as-
    /// is, doesn't escape them) but a manually narrowed one: `+`/`:`/`"` in
    /// ImhentaiAdvancedQuery.clauses() MUST come out percent-encoded (otherwise
    /// a raw "+" gets decoded server-side by PHP as a space — the same
    /// semantics as application/x-www-form-urlencoded, i.e. as $_GET — and
    /// the special syntax "+tag:..." falls apart into space+"tag:..."). A real
    /// browser (see the HAR, Aug 31) encodes it EXACTLY this way — `%2Btag%3A%22anal%22`,
    /// i.e. literally the JS equivalent of `encodeURIComponent`, not the
    /// RFC3986-safe set.
    private static let searchValueAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    /// `/search/?key=...` — confirmed by HAR (200, real cards) for
    /// ORDINARY text. The special syntax `+tag:"..."`/`+parody:"..."`/
    /// ... (see ImhentaiAdvancedQuery — Tags/Parodies/Artists/Characters/
    /// Groups on `/advsearch/`, user screenshot from Aug 31) is NOT understood by
    /// `/search/` — rechecked with a live curl: `key=+tag:"anal"` through
    /// `/search/` gives "(0) results found" (it literally searches it as TEXT), the
    /// same query through `/advsearch/` in the real HAR gave "(219,197) results
    /// found" — these two endpoints parse the same `key=` DIFFERENTLY.
    /// `/advsearch/` from this session's sandbox is behind Cloudflare (403, the same
    /// JS challenge as `/gallery/`/`/view/`) — so the routing below
    /// (`usesAdvancedSyntax`) is only confirmed INDIRECTLY (by the real HAR +
    /// the "two different parsers" logic); the actual final request from a real
    /// device has NOT been rechecked — same as the rest of this site's HTML
    /// pages, see the type's doc-comment.
    /// Categories/languages — only THEIR OWN bits (see the ImhentaiCategory/
    /// ImhentaiLanguage.bit doc-comment — non-overlapping ranges from
    /// EHentaiCategory, masked on input; other providers' bits in the same Int are simply
    /// ignored).
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: Self.searchValueAllowedCharacters) ?? trimmed
        var params = ["key=\(encodedQuery)"]

        let ownCategoryMask = ImhentaiCategory.allCases.reduce(0) { $0 | $1.bit }
        let ownExcludedCategoryBits = excludedCategoryBits & ownCategoryMask
        if ownExcludedCategoryBits != 0 {
            for category in ImhentaiCategory.allCases {
                let included = (ownExcludedCategoryBits & category.bit) == 0
                params.append("\(category.queryKey)=\(included ? 1 : 0)")
            }
        }

        // Languages — the same principle as categories above, just their own
        // non-overlapping subset of bits within the same Int (see the
        // ImhentaiLanguage.bit doc-comment).
        let ownLanguageMask = ImhentaiLanguage.allCases.reduce(0) { $0 | $1.bit }
        let ownExcludedLanguageBits = excludedCategoryBits & ownLanguageMask
        if ownExcludedLanguageBits != 0 {
            for language in ImhentaiLanguage.allCases {
                let included = (ownExcludedLanguageBits & language.bit) == 0
                params.append("\(language.queryKey)=\(included ? 1 : 0)")
            }
        }

        params.append(contentsOf: Self.sortQueryParams(for: sortKey))

        let page = Int(cursor ?? "1") ?? 1
        if page > 1 { params.append("page=\(page)") }

        // `+tag:"..."`/`+parody:"..."`/`+artist:"..."`/`+character:"..."`/
        // `+group:"..."` — the ONLY source of this construction in the
        // app, see ImhentaiAdvancedQuery.clauses() — ordinary
        // free text never looks like this, so there are no false positives.
        // `apply=Search` — present in ALL confirmed HAR requests to
        // `/advsearch/`, added only here, together with the path
        // switch (see the doc-comment on the function above).
        let usesAdvancedSyntax = trimmed.range(of: #"\+(tag|parody|artist|character|group):"#, options: .regularExpression) != nil
        let path = usesAdvancedSyntax ? "advsearch" : "search"
        if usesAdvancedSyntax { params.append("apply=Search") }

        let urlString = "\(Self.baseURL)/\(path)/?" + params.joined(separator: "&")
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Shared parsing of a listing page (search/category/tag — the same markup
    /// everywhere: `<div class="thumbnail"><a href="/gallery/{id}/">...`).
    private func fetchGalleryList(urlString: String, currentPage: Int) async throws -> (ids: [Int], nextCursor: String?) {
        guard let url = URL(string: urlString) else { throw ImhentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ImhentaiError.badResponse
        }
        let ids = Self.parseGalleryIds(html: html)
        let nextCursor = Self.hasNextPage(html: html) ? String(currentPage + 1) : nil
        return (ids, nextCursor)
    }

    private static func parseGalleryIds(html: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"href="/gallery/(\d+)/""#) else { return [] }
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

    // MARK: Title card

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "\(Self.baseURL)/gallery/\(id)/") else { throw ImhentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ImhentaiError.badResponse
        }
        return Self.parseDetail(html: html, id: id)
    }

    /// The section heading (Parodies:/Characters:/Tags:/.../Category:) is NOT
    /// parsed by text — routing is by the FIRST href segment
    /// (parody/character/tag/artist/group/language/category), the same trick
    /// as ThreeHentaiProvider.parseDetail — robust against localization.
    private static func parseDetail(html: String, id: Int) -> ExternalGalleryDetail {
        let title = firstMatch(in: html, pattern: #"<h1>([^<]*)</h1>"#).map(decodeHTMLEntities) ?? "Untitled"
        let posted = firstMatch(in: html, pattern: #"class="posted">Posted: ([^<]+)</li>"#)
        let favoritedCount = firstMatch(in: html, pattern: #"Favourite \((\d+)\)"#)

        var type = ""
        var series: [String] = []
        var characters: [String] = []
        var artists: [String] = []
        var groups: [String] = []
        var languageParts: [String] = []
        var tags: [ExternalGalleryTag] = []

        // `<a class='tag[...]' href='/{section}/{slug}/'>{name}[<span
        // class='split_tag'>...</span>]<span class='badge'>{count}</span>`
        // — single quotes, WITHOUT the h3 wrapper (unlike the letter-index
        // pages, see parseLetterIndexList) — confirmed by HAR on a live
        // title card.
        if let regex = try? NSRegularExpression(
            pattern: #"<a class='tag[^']*' href='/([a-z]+)/([^']+)/'>([^<]+)"#
        ) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 4,
                      let sectionRange = Range(match.range(at: 1), in: html),
                      let slugRange = Range(match.range(at: 2), in: html),
                      let nameRange = Range(match.range(at: 3), in: html) else { return }
                let section = String(html[sectionRange])
                let slug = String(html[slugRange])
                let name = decodeHTMLEntities(String(html[nameRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                switch section {
                case "category":
                    if type.isEmpty { type = name }
                case "parody": series.append(name)
                case "character": characters.append(name)
                case "artist": artists.append(name)
                case "group": groups.append(name)
                case "language": languageParts.append(name)
                case "tag":
                    // No gender namespace has shown up in imhentai's markup
                    // (unlike hitomi) — a neutral tag, female/male
                    // both false, we honestly don't invent a gender split.
                    tags.append(ExternalGalleryTag(name: name, female: false, male: false))
                default: break
                }
                _ = slug // the chips' own slug isn't needed — following a chip
                // re-slugifies the name (see ImhentaiProvider.slugify),
                // the same trick as ThreeHentaiProvider.
            }
        }

        // Images — from the hidden fields load_server/load_dir/load_id/
        // load_pages (confirmed by HAR on TWO independent titles, not
        // rechecked with a live curl — the site is behind Cloudflare, see the
        // type's doc-comment). The formula is CONFIRMED against a real
        // `/view/{id}/1/`: `https://m{server}.imhentai.xxx/{dir}/{id}/{page}.webp`.
        let loadServer = firstMatch(in: html, pattern: #"name="load_server"[^>]*value="([^"]*)""#)
        let loadDir = firstMatch(in: html, pattern: #"name="load_dir"[^>]*value="([^"]*)""#)
        let loadId = firstMatch(in: html, pattern: #"name="load_id"[^>]*value="([^"]*)""#)
        let loadPages = firstMatch(in: html, pattern: #"name="load_pages"[^>]*value="([^"]*)""#).flatMap(Int.init) ?? 0

        var pages: [ExternalGalleryPage] = []
        var coverURL: URL?
        if let server = loadServer, let dir = loadDir, let galleryFolder = loadId, loadPages > 0 {
            let storageKey = "m\(server).imhentai.xxx/\(dir)/\(galleryFolder)"
            // thumbnailURL — a separate lightweight thumbnail "{N}t.jpg", NOW
            // confirmed by live HAR (Aug 31, second pass — real
            // requests against /view/{id}/{page}/): `https://m11.imhentai.xxx/
            // 032/{galleryFolder}/6t.jpg` and `.../5t.jpg`, both 200
            // image/jpeg. The earlier "fix" (reusing the full-size
            // .webp link instead) was a hedge without
            // confirmation — no longer needed, reverting to the actual
            // thumbnail.
            //
            // IMPORTANT — rechecked with a live curl: the image CDN itself
            // (m11.imhentai.xxx) isn't behind Cloudflare at all (200 without
            // a single cf_clearance cookie, even though the browser's HAR request did
            // carry one — just carried over from the main domain out of habit, not because
            // it's required). The Cloudflare JS challenge sits ONLY on
            // HTML pages (`/gallery/`, `/view/`, `/`, occasionally `/search/`)
            // — the actual image delivery (cover/thumbnails/reading
            // pages) doesn't depend on it, so once the card's HTML has
            // been successfully fetched (from a real device — the site serves it
            // fine, see the type's doc-comment), any further loading of
            // images should go through without issue.
            pages = (1...loadPages).map { n in
                ExternalGalleryPage(
                    index: n, key: storageKey, width: 0, height: 0,
                    thumbnailURL: URL(string: "https://\(storageKey)/\(n)t.jpg"),
                    thumbnailSpriteOffsetX: nil
                )
            }
            // `thumb.jpg` — confirmed with a live curl (Aug 31) on the real
            // /search/?key=... page (not blocked by Cloudflare, unlike
            // /gallery/) — `<img src="https://m11.imhentai.xxx/
            // 032/{id}/thumb.jpg">` on the cards in the catalog grid.
            coverURL = URL(string: "https://\(storageKey)/thumb.jpg")
        }

        return ExternalGalleryDetail(
            id: id,
            site: .imhentai,
            title: title,
            type: type,
            language: languageParts.isEmpty ? nil : languageParts.joined(separator: ", "),
            tags: tags,
            artists: artists,
            groups: groups,
            characters: characters,
            series: series,
            // Related titles ("Related") haven't shown up on any imhentai
            // card checked so far — honestly empty, same as for e-hentai/3hentai.
            related: [],
            pages: pages,
            coverURL: coverURL,
            posted: posted,
            // e-hentai-specific fields (Parent/Visible/File Size/Rating)
            // aren't confirmed for imhentai — honestly nil, we don't make them up.
            // The Favourite count goes into favoritedCount — the closest
            // suitable existing slot.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: favoritedCount,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    // MARK: Image URLs

    /// A pure formula (host+dir+id already in `page.key`, see parseDetail) —
    /// no network, like hitomi/3hentai (unlike e-hentai — that makes a real
    /// request on every page), just wrapped in async for the sake of the shared
    /// protocol. Confirmed by live HAR (`/view/{id}/1/` →
    /// `<img id="gimg" src="https://m11.imhentai.xxx/032/{id}/1.webp">`).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: "https://\(page.key)/\(page.index).webp") else {
            throw ImhentaiError.badResponse
        }
        return url
    }

    // MARK: Utilities

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 2,
              let matchRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[matchRange])
    }

    /// Strips nested HTML tags (e.g. `<span class='split_tag'>
    /// ...</span>` inside h3 on the letter-index pages) — the same trick
    /// as ThreeHentaiProvider.stripInnerTags.
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
