import Foundation

/// Errors for EHentaiProvider — the same deliberately simple scheme as HitomiError.
enum EHentaiError: Error {
    case badResponse
    case missingToken
}

/// Advanced search fields — added by direct request (Sep 1). On e-hentai, unlike
/// the other sites, the `namespace:value` command is DIRECT
/// syntax of f_search itself (confirmed by HAR: `f_search=anal+anime+
/// series%3Agenshin` — plain text and a tag command in one and the same request at
/// once, see the EHentaiProvider.tagPrefix doc-comment) — so `encoded()` here does
/// NOT need a private separator channel like SimplyHentaiAdvancedQuery does:
/// the result is already ready-made, real f_search text that can be
/// sent as-is.
///
/// EXCLUSIVE scheme, shared across all sites with advanced fields (see
/// ExternalSearchView.resolvedQuery): if at least one field here is
/// filled in (including its own search), the screen's shared search field for
/// e-hentai stops being used — the query is built ONLY from these fields.
///
/// Multi-word values INSIDE an f_search command (`parody:"kimi no na
/// wa$"` — this is how public guides for the site do it) are NOT confirmed by HAR — by
/// analogy with a regular word we replace the space with `+` (the same formula as
/// in EHentaiProvider.formEncoded for the rest of f_search); this is an
/// ASSUMPTION made by symmetry with the confirmed path `/tag/other:nudity+
/// only`, not separately confirmed specifically inside an f_search command.
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

    /// Called ONLY when !isEmpty (see ExternalSearchView.resolvedQuery)
    /// — its own search replaces the screen's shared field rather than being combined with it.
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

/// e-hentai categories (the Doujinshi/Manga/Artist CG/... buttons on the site's
/// home page — see EHentaiCategoryPicker) and their `f_cats` bitmask.
/// Confirmed by HAR: `f_cats=1019` was seen in a real request, and
/// 1019 = the sum of ALL bits below EXCEPT .manga (4) — i.e. the bitmask semantics
/// are EXCLUSION (checked = category excluded from results), not inclusion;
/// when nothing is excluded, the site doesn't send f_cats at all (see
/// EHentaiProvider.fetchIdsBySearch(excludedCategoryBits:) — 0 means
/// "no parameter").
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

/// e-hentai.org client — its OWN, fully separate implementation, not connected
/// in any way to MangaNetworkService/LibSite/HitomiProvider. All the URLs/formats
/// below are confirmed by real HAR (see the plan — the "e-hentai" analysis section).
///
/// `actor`, not `struct` (unlike HitomiProvider): real
/// mutable state is needed BETWEEN calls — a gid→token cache (see tokenCache below),
/// without which fetchGalleryDetail(id:) is impossible (on e-hentai a gallery
/// is addressed by a PAIR (gid, token), not a single number — the token is only learned from
/// links on the results/search page, which is also where we cache it from). `actor` safely
/// serializes concurrent access to this cache; `site`/`capabilities`
/// are declared `nonisolated let` so they can be read synchronously from SwiftUI code
/// (like HitomiProvider), without requiring an await for every little thing.
actor EHentaiProvider: ExternalSiteProvider {
    nonisolated let site: ExternalSite = .ehentai
    nonisolated let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // e-hentai has no alphabetical tag index (unlike
        // hitomi.la) — but it does have regular full-text search, see hasSearch.
        hasTagBrowser: false,
        hasSearch: true,
        hasCategoryFilter: true,
        // Approximate (not an exact offset, see cursorForPage) — but
        // real, confirmed by HAR (`range=`), see paginationQueryItem.
        hasPageJump: true,
        // Neither in HAR nor on the e-hentai search page itself is there a visible
        // user-facing sort control for results (unlike
        // hitomi — see HitomiProvider.SortOption) — honestly false, we don't
        // make one up.
        hasSortOptions: false,
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        hasComments: false
    )

    /// A separate session — its own, not shared with either HitomiProvider.session
    /// or, even less so, MangaNetworkService. `Cookie: nw=1` — confirmed by a
    /// live HAR (Aug 30, ProxyPin830_18_35_43.har): the title page
    /// `/g/{id}/{token}/` without this cookie returns NOT the real content but an
    /// intermediate "Content Warning" page (for galleries marked
    /// as "Offensive For Everyone" — e-hentai has quite a few of these; any
    /// search with scat/guro/etc. categories is almost guaranteed to run
    /// into them) with two links, `?nw=session`/`?nw=always` ("Never Warn
    /// Me Again") — both simply SET this cookie (`Set-Cookie: nw=1`) and
    /// redirect back to the same page, this time with the real markup.
    /// Without it, parseMetadata/parsePages silently find 0 matches on
    /// the warning page (it has neither gdt1/gdt2, nor tags, nor page
    /// links) — hence "title won't load" / an empty skeleton cover in
    /// the catalog grid / an empty preview grid for ANY gallery marked this way.
    /// We set the cookie on EVERY session request up front — the same effect as one
    /// click of "Never Warn Me Again", just done in advance, without a separate parse of the
    /// warning page and a redirect for every such gallery.
    nonisolated private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://e-hentai.org/",
            "Cookie": "nw=1"
        ]
        return URLSession(configuration: config)
    }()

    /// gid → token, accumulated as galleries are encountered in the
    /// results (tag/search) — a title card is addressed by BOTH parts
    /// (see the type's doc-comment); without the token fetchGalleryDetail can't
    /// build the canonical URL `/g/{gid}/{token}/`.
    private var tokenCache: [Int: String] = [:]

    // MARK: Alphabetical index — not confirmed for e-hentai, honestly empty.

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        []
    }

    /// e-hentai autocomplete is not confirmed by HAR — honestly empty (same as
    /// hasTagBrowser, see capabilities).
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: List of titles by tag/search

    /// e-hentai has NO separate "tag search feature" — there's ONE search
    /// field (f_search), and `namespace:value` is just a COMMAND inside it
    /// (confirmed by HAR: `f_search=anal+anime+series%3Agenshin` — plain
    /// text and a tag command in the very same request at the same time). As for
    /// `/tag/{ns}:{value}` — that's simply what opens when you click a
    /// ready-made tag link in the markup (also confirmed by HAR, separately from
    /// f_search); a convenient shortcut for a SINGLE tag without extra text
    /// — kept as a separate protocol method rather than folded into
    /// fetchIdsBySearch, ONLY because multi-word tag values
    /// (`nudity only`, `textless narrative`) are confirmed specifically in this
    /// form (`+` instead of a space right in the path); the quoting syntax for
    /// a multi-word tag INSIDE f_search (`parody:"kimi no na wa$"` and
    /// similar — this is what public guides for the site do) is not confirmed by HAR,
    /// so we don't risk guessing at it here.
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

    /// e-hentai encodes a space as `+` (the `application/x-www-form-
    /// urlencoded` form), NOT `%20` — confirmed by HAR both in the query (`f_search=anal
    /// +anime`) and right in the path (`/tag/other:nudity+only`). `.urlPathAllowed`/
    /// `.urlQueryAllowed` on their own produce `%20`, so the space is replaced
    /// with `+` manually BEFORE percent-encoding the rest (encoding leaves an
    /// already-inserted `+` as-is — it's part of `.urlQueryAllowed`).
    private static func formEncoded(_ text: String) -> String {
        let withPlus = text.replacingOccurrences(of: " ", with: "+")
        return withPlus.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? withPlus
    }

    /// Synthesizes a jump cursor (see paginationQueryItem below) — simply
    /// wraps the page number as-is into a future `range=`,
    /// approximately (there's no exact page→range formula). `nonisolated` —
    /// the protocol declares this method as SYNCHRONOUS (no async, like site/
    /// capabilities), while an actor isolates even such methods by default;
    /// it's a pure computation with no access to tokenCache/session, so isolation isn't
    /// needed — without this the build fails ("crosses into actor-isolated code").
    nonisolated func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return "page:\(page)"
    }

    /// The cursor is either the REGULAR kind, returned by the previous call (the id of the
    /// last title on the current page, goes into `&next=` — the site's
    /// standard pagination), or a SPECIAL one, synthesized by the client itself to jump
    /// to an arbitrary page (see cursorForPage above) — prefixed with
    /// `page:`, goes into `&range=`. `range=N` is confirmed by HAR (the second HAR,
    /// about sorting/navigation): it genuinely changes the position within the results (a request with
    /// `range=68` returned a completely different range of title ids than without it) —
    /// this is exactly the mechanism behind the "Jump/Seek" button on the site itself, it just
    /// plugs the entered number straight into this parameter. The EXACT formula for
    /// converting a "page number" into a specific range value is not confirmed
    /// (the site clearly doesn't treat it as an offset/limit) — we treat it as an
    /// approximate jump and don't guarantee showing EXACTLY the same page
    /// that regular page-by-page pagination from the start would show.
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

    /// Regular site-wide full-text search (`?f_search=`) — something
    /// hitomi doesn't have (see HitomiProvider.fetchIdsBySearch — a stub).
    /// The user can type in EITHER free text OR an `ns:value`
    /// command, even mixed together (see the tagPrefix doc-comment) — this method
    /// doesn't distinguish between them, it just honestly passes it through as-is.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, cursor: cursor, limit: limit)
    }

    /// An empty query — just the home page (see HAR: `GET https://
    /// e-hentai.org/` with no parameters at all — the same "recently
    /// uploaded" feed you see in the browser) — following the same "Recently"
    /// principle as hitomi (see HitomiProvider.fetchIdsBySearch).
    /// `excludedCategoryBits` — see EHentaiCategory (the bitmask of EXCLUDED
    /// categories, confirmed by HAR). 0 means the `f_cats` parameter isn't
    /// added to the URL at all, exactly as on the site itself when no
    /// category button is toggled off.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var params: [String] = []
        if !trimmed.isEmpty { params.append("f_search=\(Self.formEncoded(trimmed))") }
        if excludedCategoryBits != 0 { params.append("f_cats=\(excludedCategoryBits)") }
        if let cursor { params.append(Self.paginationQueryItem(for: cursor)) }
        let urlString = params.isEmpty ? "https://e-hentai.org/" : "https://e-hentai.org/?" + params.joined(separator: "&")
        return try await fetchGalleryList(urlString: urlString)
    }

    /// Shared parsing for a results page (tag OR search — the same markup either way):
    /// pulls (gid, token) pairs out of the card links, stores them in
    /// tokenCache (otherwise fetchGalleryDetail can't assemble the URL), and
    /// pulls the next-page cursor from the `&next=` pagination link.
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
                // Duplicates: a card in the results contains several links to the
                // same gid (thumbnail + title) — we take the first one, we don't
                // duplicate the id in the resulting list.
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

    // MARK: Title card

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let token = tokenCache[id] else { throw EHentaiError.missingToken }
        let html = try await fetchHTML(urlString: "https://e-hentai.org/g/\(id)/\(token)/")
        let metadata = Self.parseMetadata(html: html)
        var pages = Self.parsePages(from: html)

        // The page-thumbnail strip is served in chunks of ~20 at a time (see
        // ?p=N at the bottom of the card) — the base /g/{id}/{token}/ WITHOUT ?p=
        // only returns the first ~20, confirmed by HAR (a 67-page gallery:
        // "Length: 67 pages" in the metadata, but only 20 /s/... links in
        // the response itself; ?p=1/?p=2/?p=3 each add the next ~20).
        // Without this follow-up fetching, reading would silently break off at page 20 for
        // any sufficiently long gallery.
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
            // Similar titles on the e-hentai page aren't a separate list of IDs
            // (like related on hitomi), but cards with their own gid/token —
            // not confirmed by the parsing, honestly empty (see the plan's "what's missing").
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

    /// Everything that isn't part of the page list — the reason there's no point
    /// re-parsing tags/artist/cover on EVERY ?p=N follow-up (see
    /// fetchGalleryDetail): calling it once on the base page is enough.
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
        /// From `<td class="gdt1">Length:</td><td class="gdt2">67 pages</td>`
        /// — the total number of PAGES IN THE TITLE (not the same thing as the number of ?p=N
        /// follow-ups for the thumbnail strip — that's just their source).
        let totalPages: Int
        /// The fields below come from the same `gdt1`/`gdt2` rows of the metadata table + the
        /// rating widget (`#gdr`) + the comments block (`#cdiv`), confirmed by
        /// real markup (`eh_detail.html` from this session's HAR), see
        /// the plan, PART B.2/B.5. hitomi has no fields like these at all — this is a purely
        /// e-hentai-specific set.
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

    /// `<a name="c{id}"></a>...<div class="c3">Posted on {date} by: ...
    /// <a href=".../uploader/...">{author}</a>...</div>...<div class="c6"
    /// id="comment_{id}">{text}</div>` — confirmed by real markup
    /// (`eh_detail.html`, this session's HAR), see the plan, PART B.5. The `.*?`
    /// captures are lazy — they stop at the FIRST match inside the block for
    /// this specific comment (one "by:"/`c6` per comment).
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

    /// Page thumbnails from a SINGLE response (the base /g/{id}/{token}/ OR
    /// any of its ?p=N follow-ups — the markup is the same, see fetchGalleryDetail).
    /// Also pulls out `thumbnailURL` — the real CSS background-image
    /// URL of the thumbnail strip (`<div style="...url(https://.../{id}-{n}.webp)...">`,
    /// (no quotes inside url(), confirmed by HAR), see the plan, PART B.3.
    /// IMPORTANT: e-hentai thumbnails are NOT a separate image per page. One
    /// strip (a ?p=N follow-up, ~20 pages) serves ONE shared "sprite" +
    /// a CSS `background-position` that crops out the tile you need — confirmed
    /// byte-for-byte by real markup:
    /// `<a href=".../s/{key}/{gid}-{n}"><div title="Page N: ..."
    /// style="width:200px;height:278px;background:transparent
    /// url(.../{gid}-{p}.webp) -200px 0 no-repeat"></div></a>` — 20
    /// ADJACENT pages all link to the SAME url(...), with the offset increasing
    /// by 200 (= tile width) each time. Previously the offset wasn't accounted for at all
    /// — because of that, the title card's preview grid showed the same
    /// (wrong, uncropped) sprite on EVERY page of a batch — that was
    /// the complaint "one image shown many times + the grid looks off" (the wrong
    /// wide sprite, stretched onto a narrow tile via scaledToFill,
    /// looks distorted). See ExternalSpriteThumbnail
    /// (App/Views/ExternalSites/ExternalImage.swift) — that's where the actual cropping happens.
    /// The tile's width/height (200×278 etc., varies per page) is also
    /// used as the page's width/height — previously these were 0/0
    /// ("size unknown"), and this is a reasonable approximation of the real proportions
    /// (the placeholder in the reader / height calculation for "fit to width" is now a bit more accurate).
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
    /// — extract the text of every `<a>` inside a single namespace's block.
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

    // MARK: Reading page URL

    /// A REAL network request every time (unlike hitomi's pure
    /// formula) — the H@H image link is temporary, with an expiring keystamp,
    /// it can't be computed ahead of time and can't be cached for long (see the plan).
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
