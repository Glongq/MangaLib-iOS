import Foundation

/// Errors for HitomiProvider — intentionally simple (this is not the
/// production-grade error-handling layer of the old MangaNetworkService, but a
/// separate minimal client — see the plan on "barely overlapping with the old networking code").
enum HitomiError: Error {
    case badResponse
    case notFound
    case decodingFailed
}

/// Hitomi's "Filters" field (see HitomiAdvancedFieldsPicker) — unlike
/// every other site's advanced query, this is NOT a set of structured
/// chip fields, it's a single free-text field using the site's OWN
/// prefix syntax directly (space-separated terms, each optionally
/// carrying `female:`/`male:`/`type:`/`tag:`/`artist:`/`group:`/
/// `character:`/`series:` — see HitomiProvider.fetchIdsBySearch), because
/// that IS how hitomi's own search bar works — there's nothing to
/// structure into separate chip fields.
struct HitomiAdvancedQuery {
    var search: String = ""

    var isEmpty: Bool { search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Called ONLY when !isEmpty (see ExternalSearchView.resolvedQuery) —
    /// no transformation needed, the field's own text IS the query
    /// (fetchIdsBySearch parses the prefix/AND syntax itself).
    func encoded() -> String { search.trimmingCharacters(in: .whitespaces) }
}

/// Client for hitomi.la — its OWN, fully separate implementation (its own
/// URLSession, its own parsing, its own models), not connected to
/// MangaNetworkService/LibSite in any way. All URLs/formats below are confirmed by real
/// HAR data (see /root/.claude/plans/vectorized-chasing-elephant.md — that's also where
/// the reverse-engineering history and what's still NOT confirmed live).
struct HitomiProvider: ExternalSiteProvider {
    let site: ExternalSite = .hitomi
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        hasTagBrowser: true,
        // Not full-text search in the usual sense (that still runs into
        // the unparsed binary B-tree index galleriesindex/*, see the plan,
        // "What's blocked") — but it provides real value: an empty query gives
        // "Recently", a non-empty one is treated as a deliberate namespace:value command (see
        // fetchIdsBySearch) — the same principle the site's own search uses.
        // Space-separated terms are ANDed together (see
        // fetchIdsBySearch/computeMultiTermIntersection), each optionally
        // carrying its own female:/male:/type:/tag:/artist:/group:/
        // character:/series: prefix.
        hasSearch: true,
        // true — opens the "Filters" button/tab (see
        // HitomiAdvancedFieldsPicker): a dedicated Search field using the
        // same prefix syntax as the shared field, per direct request,
        // matching the pattern already used for 3Hentai (see
        // ThreeHentaiProvider.hasCategoryFilter).
        hasCategoryFilter: true,
        // The cursor is a plain byte offset (see fetchIdsByTag below), so
        // "page N" can be computed exactly, without a network call (see cursorForPage below).
        hasPageJump: true,
        // Popular: Today/Week/Month/Year — confirmed by a live curl test
        // (Aug 30, third attempt) against `popular/{period}-all.nozomi` and
        // `{kit}/popular/{period}/{value}-all.nozomi`, see SortOption.
        hasSortOptions: true,
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        hasComments: false
    )

    /// A separate session — not MangaNetworkService.session; headers/cookies/
    /// cache must not accidentally mix with the old code.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://hitomi.la/"
        ]
        return URLSession(configuration: config)
    }()

    // MARK: Alphabetical List (Part 4)

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        let kindSlug: String
        switch kind {
        case .tags: kindSlug = "tags"
        case .series: kindSlug = "series"
        case .characters: kindSlug = "characters"
        case .artists: kindSlug = "artists"
        // hitomi has no groups directory (only 4 kits in the nav — tags/series/
        // characters/artists) — this case was added alongside 3hentai.net, which
        // actually does have such a directory (see ThreeHentaiProvider).
        case .groups: return []
        }
        // "123" is a separate bucket for values starting with a digit (see
        // the hitomi.la nav: /alltags-123.html) — not an actual letter.
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

    /// Format confirmed by HAR (alltags-c.html/allseries-*.html):
    /// `<a href="/tag/SLUG-all.html">NAME</a> (COUNT)` — shared across tag/
    /// series/character/artist (only the first path segment differs).
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

    // MARK: Autocomplete (Part 5)

    func fetchAutocomplete(query: String, namespace: String? = nil) async throws -> [ExternalTagSuggestion] {
        let ns = namespace ?? "global"
        let lowered = query.lowercased()
        // An empty query → the whole root file for the namespace (top entries by count,
        // no prefix filter) — confirmed by HAR (global.json/tag.json).
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
        // 404 is a normal "no matches for this prefix" response, not an error.
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

    // MARK: List of Titles by Tag (.nozomi, Part 6)

    /// The REAL scheme (re-verified live against `ltn.gold-
    /// usergeneratedcontent.net`, plus the live source of `galleryblock.js`/
    /// `galleries/{id}.js` on the same site — see the plan, PART A): hitomi
    /// has exactly 4 "direct" URL kits —
    /// `tag`/`series`/`character`/`artist` (the same 4 as in the nav bar
    /// alltags/allseries/allcharacters/allartists), WITHOUT the `n/` prefix
    /// (my earlier fix that added `n/` was not the cause of the bug — the server accepts
    /// both variants identically, but the canonical form is without it, matching what the
    /// site itself builds). `female`/`male`/`group` are NOT separate kits — they're `tag`,
    /// where the VALUE itself contains the prefix (see `prefixedValue` below) —
    /// confirmed by `galleries/{id}.js`: `tags[].url =
    /// "/tag/female%3Aanal-all.html"`, NOT `"/female/anal-all.html"`.
    private static func nozomiPath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male, .group: return "tag"
        case .character: return "character"
        case .artist: return "artist"
        case .series: return "series"
        }
    }

    /// `female`/`male`/`group` live UNDER the `tag` kit (see nozomiPath above)
    /// — the namespace prefix is added right into the VALUE itself, exactly the way
    /// the site itself does it (`female:anal`, not a separate path). `.group` is
    /// modeled by analogy with female/male and is NOT confirmed by a live request (there isn't
    /// a single `/group/` example in the collected HAR data), flagged below.
    private static func prefixedValue(for namespace: ExternalTagNamespace, value: String) -> String {
        switch namespace {
        case .female: return "female:\(value)"
        case .male: return "male:\(value)"
        case .group: return "group:\(value)" // best-effort, not HAR-confirmed
        case .tag, .character, .artist, .series: return value
        }
    }

    /// Sorting (see ExternalSiteCapabilities.hasSortOptions/SortOption) —
    /// confirmed by a live curl test (Aug 30, third attempt): `popular/{period}-
    /// all.nozomi` (no tag) and `{kit}/popular/{period}/{value}-
    /// all.nozomi` (with a tag) — BOTH return `206` with a real Content-Range,
    /// with no language suffix (an example from a live `search.js` comment
    /// contained `-czech.nozomi`, but that turned out to be OPTIONAL — the path without
    /// a language also works, see the plan).
    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded, popularToday, popularWeek, popularMonth, popularYear
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dateAdded: return "По дате добавления"
            case .popularToday: return "Популярное: сегодня"
            case .popularWeek: return "Популярное: неделя"
            case .popularMonth: return "Популярное: месяц"
            case .popularYear: return "Популярное: год"
            }
        }
        fileprivate var popularPeriod: String? {
            switch self {
            case .dateAdded: return nil
            case .popularToday: return "today"
            case .popularWeek: return "week"
            case .popularMonth: return "month"
            case .popularYear: return "year"
            }
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let prefixed = Self.prefixedValue(for: namespace, value: value)
        return try await fetchIdsByRawKit(kitPath: Self.nozomiPath(for: namespace), value: prefixed, sortKey: sortKey, cursor: cursor, limit: limit)
    }

    /// Same as fetchIdsByTag, but takes the raw nozomi path segment
    /// directly instead of ExternalTagNamespace — needed for `type`
    /// (browsing/searching by type: doujinshi/manga/artistcg/... — a real
    /// hitomi kit, per direct instruction describing the site's own
    /// search-field syntax) which has no ExternalTagNamespace counterpart.
    /// That enum is shared across every provider — adding a `.type` case
    /// there would force an unrelated exhaustive-switch update in every
    /// OTHER provider file for a concept only hitomi has, so it stays
    /// local to this file (see ContinuationKit.type/fetchFullIdsForTerm).
    private func fetchIdsByRawKit(kitPath: String, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let encodedValue = value.lowercased()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value.lowercased()
        let period = sortKey.flatMap(SortOption.init(rawValue:))?.popularPeriod
        let path: String
        if let period {
            path = "\(kitPath)/popular/\(period)/\(encodedValue)-all.nozomi"
        } else {
            path = "\(kitPath)/\(encodedValue)-all.nozomi"
        }
        return try await fetchNozomiList(urlString: "https://\(Self.apiDomain)/\(path)", cursor: cursor, limit: limit)
    }

    /// The REAL host for .nozomi/galleries/{id}.js — confirmed by the LIVE
    /// `common.js` of the site itself (downloaded on Aug 30 through an
    /// alias reachable from the sandbox): `const domain2 = 'gold-usergeneratedcontent.net'; var domain
    /// = 'ltn.' + domain2;` — the site ITSELF talks to `ltn.gold-
    /// usergeneratedcontent.net`, NOT `ltn.hitomi.la` (the latter appears to be
    /// blocked for some providers/ISP-level censorship — exactly the reason the site
    /// has domain-fronting to a second domain at all). This used to literally be
    /// `ltn.hitomi.la` here — the .nozomi scheme itself was correct (as confirmed
    /// by live curl tests IN THIS SESSION, which went through the .net alias
    /// as a workaround for the sandbox's own blocking), but in the actual code the domain
    /// was left as the old one — hence the "0 titles" that persisted even AFTER the scheme fix:
    /// one domain was tested, but a different one was left in the code.
    private static let apiDomain = "ltn.gold-usergeneratedcontent.net"

    /// The shared byte-range request to a .nozomi file — used both by tag
    /// (fetchIdsByTag) and by the general "Recently" index (fetchIdsBySearch,
    /// empty query) — the same response format, only the URL differs.
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
        // Content-Range: bytes X-Y/TOTAL — TOTAL is already in bytes, /4 → number of titles.
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slashIndex = contentRange.lastIndex(of: "/"),
           let totalBytes = Int(contentRange[contentRange.index(after: slashIndex)...]) {
            total = totalBytes / 4
        }
        let nextOffset = offset + ids.count
        let nextCursor = nextOffset < total ? String(nextOffset) : nil
        return (ids, nextCursor)
    }

    /// The cursor here is a plain offset-in-elements (see fetchIdsByTag above:
    /// `Int(cursor ?? "0") ?? 0`, then `* 4` to convert to bytes for the Range header) —
    /// meaning "page N" is computed EXACTLY, with plain arithmetic, with no network call.
    func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return String((page - 1) * limit)
    }

    /// The body of .nozomi is simply an array of big-endian Int32 values (4 bytes per ID), with no
    /// header/wrapper — confirmed by a byte-level breakdown of the HAR data.
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

    /// An empty query gives "Recently" (see the `index-all.nozomi` index, the same
    /// principle as the hitomi.la home page); a non-empty one recognizes a
    /// `namespace:value` prefix (`female:`/`male:`/`series:`/`artist:`/
    /// `group:`/`character:`/`tag:`, following the same pattern the site's own
    /// search uses) and routes into fetchIdsByTag. WITHOUT a prefix (plain input
    /// like "just a tag name") — AUTO-DETECTS the namespace (see below, FIXED
    /// Aug 31). `index-all.nozomi` was verified with a live curl test against apiDomain
    /// (Aug 30, re-checked) — `206`, `Content-Range .../4804324`
    /// (~1.2M titles, plausible for "the entire index").
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// FIXED (Sep 1) — a multi-word query (e.g. "anal horse", neither word
    /// prefixed) used to be sent to the tag lookup as ONE LITERAL VALUE
    /// WITH A SPACE IN IT ("anal horse") — hitomi tag values never
    /// contain a literal space (a multi-word tag uses an underscore, e.g.
    /// "big_breasts"), so every candidate (.tag/.female/.male) 404'd and
    /// the search silently came back with 0 results — the "поиск выпадает
    /// при 2+ словах" complaint. The REAL hitomi.la search field
    /// (confirmed live: `search.html?anal%20horse` in a fresh HAR capture,
    /// which triggers the site's own `/galleriesindex/` B-tree lookups)
    /// treats a space as a separator between INDEPENDENT terms and ANDs
    /// them together — each term can carry its own explicit
    /// `female:`/`male:`/`type:`/`tag:`/`artist:`/`group:`/`character:`/
    /// `series:` prefix (this exact vocabulary — including `type:` — is
    /// how the site's single search field itself works, per direct
    /// instruction), or be a bare word (same auto-detect as a single-term
    /// query, see fetchIdsBySingleTerm). The actual binary
    /// `/galleriesindex/` B-tree format is NOT reimplemented here — its
    /// node layout isn't confirmed by any captured JS source, only opaque
    /// byte ranges — instead every term is resolved through the
    /// already-confirmed `.nozomi` per-kit lists (the same mechanism a
    /// single-term query already used), and the result is a set
    /// INTERSECTION across every term's full id list — functionally
    /// equivalent AND semantics, built entirely from confirmed endpoints.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let period = sortKey.flatMap(SortOption.init(rawValue:))?.popularPeriod
        guard !trimmed.isEmpty else {
            // Empty query + "Popular" sort — the global
            // popular feed (no tag), verified with a live curl test (see SortOption).
            if let period {
                return try await fetchNozomiList(urlString: "https://\(Self.apiDomain)/popular/\(period)-all.nozomi", cursor: cursor, limit: limit)
            }
            return try await fetchNozomiList(urlString: "https://\(Self.apiDomain)/index-all.nozomi", cursor: cursor, limit: limit)
        }

        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard terms.count > 1 else {
            return try await fetchIdsBySingleTerm(trimmed, sortKey: sortKey, cursor: cursor, limit: limit)
        }

        // Multi-term AND (see HitomiSearchCache doc-comment) — the full,
        // intersected id list is computed once (page 1) and cached under
        // the exact query text, so scrolling to page 2/3/... pages
        // through the cached array instead of redoing the network work.
        if let cursor, let decoded = Self.decodeMultiSearchCursor(cursor) {
            let ids = try await HitomiSearchCache.shared.intersection(for: decoded.queryText) {
                try await self.computeMultiTermIntersection(decoded.queryText, sortKey: sortKey)
            }
            return Self.page(ids: ids, offset: decoded.offset, limit: limit, queryText: decoded.queryText)
        }
        let ids = try await HitomiSearchCache.shared.intersection(for: trimmed) {
            try await self.computeMultiTermIntersection(trimmed, sortKey: sortKey)
        }
        return Self.page(ids: ids, offset: 0, limit: limit, queryText: trimmed)
    }

    /// The original single-term algorithm (FIXED Aug 31, see below): a
    /// continuing cursor → an explicit `namespace:` prefix → auto-detected
    /// `.tag`/`.female`/`.male`, in that order.
    ///
    /// (Aug 31 fix) — previously, without an explicit `namespace:` prefix
    /// the query was ALWAYS treated as namespace `.tag` (a lookup straight
    /// against `/tag/{value}-all.nozomi`) — but on hitomi MOST tags are
    /// categorized by gender and don't exist as a "bare" tag at all:
    /// `/tag/anal-all.nozomi` → 404 live, whereas `/tag/female%3Aanal-
    /// all.nozomi` → 206 (verified with curl on Aug 31). Now, without an
    /// explicit command, candidates are tried IN ORDER: as-is (`.tag`) →
    /// `female:` → `male:` — the first non-empty result wins, and the
    /// same (kit, value) is reused for every subsequent page via `cursor`
    /// (see ContinuationKit/encodeSearchCursor).
    private func fetchIdsBySingleTerm(_ trimmed: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        // Continuing an auto-detection that was already resolved (on the first page) —
        // the same (kit, value) is reused as-is, WITHOUT re-running
        // the namespace search.
        if let cursor, let decoded = Self.decodeSearchCursor(cursor) {
            let result = try await fetchIdsByRawKit(kitPath: decoded.kit.kitPath, value: decoded.resolvedValue, sortKey: sortKey, cursor: decoded.offset, limit: limit)
            return (result.ids, result.nextCursor.map { Self.encodeSearchCursor(kit: decoded.kit, resolvedValue: decoded.resolvedValue, offset: $0) })
        }

        let (kind, value, explicit) = Self.parseSearchCommand(trimmed)
        // An explicit command (female:/male:/type:/series:/artist:/group:/
        // character:/tag:) — honor exactly what was requested, no
        // auto-detection; a legacy cursor (e.g. from "go to page N" —
        // that's just a plain number, not our "kit\u{1}value\u{1}offset"
        // format) — is used AS THE STARTING offset for this attempt.
        if explicit {
            let (kit, resolvedValue) = Self.resolveExplicit(kind, value: value)
            let result = try await fetchIdsByRawKit(kitPath: kit.kitPath, value: resolvedValue, sortKey: sortKey, cursor: cursor, limit: limit)
            return (result.ids, result.nextCursor.map { Self.encodeSearchCursor(kit: kit, resolvedValue: resolvedValue, offset: $0) })
        }

        for candidate: ExternalTagNamespace in [.tag, .female, .male] {
            let kit = Self.continuationKit(for: candidate)
            let resolvedValue = Self.prefixedValue(for: candidate, value: value)
            let result = try await fetchIdsByRawKit(kitPath: kit.kitPath, value: resolvedValue, sortKey: sortKey, cursor: cursor, limit: limit)
            guard !result.ids.isEmpty else { continue }
            return (result.ids, result.nextCursor.map { Self.encodeSearchCursor(kit: kit, resolvedValue: resolvedValue, offset: $0) })
        }
        return ([], nil)
    }

    /// One term's FULLY materialized id list, for the AND intersection
    /// (see computeMultiTermIntersection below) — same explicit/
    /// auto-detect resolution as a single term, but instead of one page
    /// it downloads the whole list in one shot (capped, see
    /// maxFullFetchIDs) via a single Range request — fetchNozomiList
    /// already tolerates a file smaller than the requested range.
    private func fetchFullIdsForTerm(_ rawTerm: String, sortKey: String?) async throws -> [Int] {
        let (kind, value, explicit) = Self.parseSearchCommand(rawTerm)
        if explicit {
            let (kit, resolvedValue) = Self.resolveExplicit(kind, value: value)
            return try await fetchIdsByRawKit(kitPath: kit.kitPath, value: resolvedValue, sortKey: sortKey, cursor: "0", limit: Self.maxFullFetchIDs).ids
        }
        for candidate: ExternalTagNamespace in [.tag, .female, .male] {
            let kit = Self.continuationKit(for: candidate)
            let resolvedValue = Self.prefixedValue(for: candidate, value: value)
            let result = try await fetchIdsByRawKit(kitPath: kit.kitPath, value: resolvedValue, sortKey: sortKey, cursor: "0", limit: Self.maxFullFetchIDs)
            guard !result.ids.isEmpty else { continue }
            return result.ids
        }
        return []
    }

    /// Space-separated terms are ANDed (see the fetchIdsBySearch doc
    /// comment) — a term whose own list comes back empty makes the whole
    /// query empty (short-circuit, no point downloading the rest). The
    /// SMALLEST list becomes the "anchor" (its own relative order —
    /// hitomi's `.nozomi` lists are newest-first — is preserved in the
    /// final result), the others are only turned into membership Sets —
    /// minimizes CPU (Set.contains is O(1), no need to sort/merge the big
    /// lists directly).
    private func computeMultiTermIntersection(_ text: String, sortKey: String?) async throws -> [Int] {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var perTerm: [[Int]] = []
        for term in terms {
            let ids = try await fetchFullIdsForTerm(term, sortKey: sortKey)
            guard !ids.isEmpty else { return [] }
            perTerm.append(ids)
        }
        guard let anchorIndex = perTerm.indices.min(by: { perTerm[$0].count < perTerm[$1].count }) else { return [] }
        let anchor = perTerm[anchorIndex]
        let otherSets = perTerm.enumerated().compactMap { idx, arr -> Set<Int>? in idx == anchorIndex ? nil : Set(arr) }
        return anchor.filter { id in otherSets.allSatisfy { $0.contains(id) } }
    }

    /// Cap on how many ids a single term's list is fully materialized to
    /// for an AND-intersection (see fetchFullIdsForTerm) — a deliberate
    /// practical safety bound against downloading a multi-megabyte list
    /// for a very common bare word (each id is 4 bytes, so 200k ids ≈
    /// 800KB), not an API constraint.
    private static let maxFullFetchIDs = 200_000

    /// One page out of an already-materialized/intersected id list (see
    /// computeMultiTermIntersection) — pagination here is purely local
    /// (array slicing, no network) since the full list is already in hand
    /// (cached by HitomiSearchCache).
    private static func page(ids: [Int], offset: Int, limit: Int, queryText: String) -> (ids: [Int], nextCursor: String?) {
        guard offset < ids.count else { return ([], nil) }
        let end = min(offset + limit, ids.count)
        let nextCursor = end < ids.count ? Self.encodeMultiSearchCursor(queryText: queryText, offset: end) : nil
        return (Array(ids[offset..<end]), nextCursor)
    }

    /// female:/male:/series:/artist:/group:/character:/tag: — the
    /// hitomi.la search-syntax vocabulary (see the Aug 31 fix doc comment
    /// above for female/male). `type:` is a hitomi-only concept
    /// (doujinshi/manga/artistcg/gamecg/anime/imageset) — modeled as its
    /// own ContinuationKit case rather than added to ExternalTagNamespace
    /// (see fetchIdsByRawKit doc comment on why it stays local here).
    private static let searchPrefixes: [(String, ExternalTagNamespace)] = [
        ("female:", .female), ("male:", .male), ("series:", .series),
        ("artist:", .artist), ("group:", .group), ("character:", .character), ("tag:", .tag)
    ]

    private enum ExplicitKind {
        case namespace(ExternalTagNamespace)
        case type
    }

    private static func parseSearchCommand(_ text: String) -> (kind: ExplicitKind, value: String, explicit: Bool) {
        let lower = text.lowercased()
        if lower.hasPrefix("type:") {
            return (.type, String(lower.dropFirst("type:".count)).trimmingCharacters(in: .whitespaces), true)
        }
        for (prefix, ns) in searchPrefixes where lower.hasPrefix(prefix) {
            return (.namespace(ns), String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), true)
        }
        return (.namespace(.tag), lower, false)
    }

    /// Turns an explicit command's parsed (kind, value) into the (kit,
    /// resolvedValue) pair fetchIdsByRawKit needs — `.type` maps straight
    /// onto its own kit with the value untouched (no embedded-prefix
    /// trick, unlike female/male, see prefixedValue); everything else
    /// reuses the existing namespace machinery unchanged.
    private static func resolveExplicit(_ kind: ExplicitKind, value: String) -> (kit: ContinuationKit, resolvedValue: String) {
        switch kind {
        case .type: return (.type, value)
        case .namespace(let ns): return (continuationKit(for: ns), prefixedValue(for: ns, value: value))
        }
    }

    /// The REAL REST kit (nozomiPath) to use for continuing pagination —
    /// `.tag`/`.female`/`.male`/`.group` all live UNDER the `tag` kit
    /// (the value itself carries the prefix, see prefixedValue), so for THEM
    /// continuation must go through `.tag` (where prefixedValue is a
    /// no-op, so a repeated call won't double up an already-embedded "female:"/"male:"/
    /// "group:" prefix) — `.character`/`.artist`/`.series` live on
    /// THEIR OWN kits, where prefixedValue is already a no-op, so continuation goes through
    /// the original namespace unchanged. `.type` has no ExternalTagNamespace
    /// counterpart at all (see resolveExplicit) — it never goes through
    /// this function, only through its own ContinuationKit case directly.
    private enum ContinuationKit: String {
        case tag, character, artist, series, type
        /// The raw nozomi path segment for this kit — `type` has no
        /// ExternalTagNamespace counterpart (see fetchIdsByRawKit), hence
        /// a plain string property instead of routing through `.namespace`.
        var kitPath: String {
            switch self {
            case .tag: return "tag"
            case .character: return "character"
            case .artist: return "artist"
            case .series: return "series"
            case .type: return "type"
            }
        }
    }

    private static func continuationKit(for namespace: ExternalTagNamespace) -> ContinuationKit {
        switch namespace {
        case .tag, .female, .male, .group: return .tag
        case .character: return .character
        case .artist: return .artist
        case .series: return .series
        }
    }

    /// "\u{1}" is a technical separator between kit/value/offset:
    /// the value can contain letters/digits/hyphens/spaces/colons (all
    /// actually occur, see prefixedValue) — a control character
    /// is guaranteed not to appear in it, nor in ContinuationKit's rawValue.
    private static func encodeSearchCursor(kit: ContinuationKit, resolvedValue: String, offset: String) -> String {
        "\(kit.rawValue)\u{1}\(resolvedValue)\u{1}\(offset)"
    }

    private static func decodeSearchCursor(_ cursor: String) -> (kit: ContinuationKit, resolvedValue: String, offset: String)? {
        let parts = cursor.split(separator: "\u{1}", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kit = ContinuationKit(rawValue: String(parts[0])) else { return nil }
        return (kit, String(parts[1]), String(parts[2]))
    }

    /// Same idea as encodeSearchCursor/decodeSearchCursor above, but for a
    /// multi-term AND search (see computeMultiTermIntersection) — the
    /// leading "multi" tag keeps it from ever being mistaken for a
    /// single-term cursor (ContinuationKit has no "multi" case, so
    /// decodeSearchCursor safely returns nil for one of these, and vice
    /// versa) — the payload is the ORIGINAL query text (not a resolved
    /// kit/value), since the whole point is to re-key HitomiSearchCache.
    private static func encodeMultiSearchCursor(queryText: String, offset: Int) -> String {
        "multi\u{1}\(queryText)\u{1}\(offset)"
    }

    private static func decodeMultiSearchCursor(_ cursor: String) -> (queryText: String, offset: Int)? {
        let parts = cursor.split(separator: "\u{1}", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "multi", let offset = Int(parts[2]) else { return nil }
        return (String(parts[1]), offset)
    }

    // MARK: Title Detail Card (galleries/{id}.js, Part 6)

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "https://\(Self.apiDomain)/galleries/\(id).js") else {
            throw HitomiError.badResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              var text = String(data: data, encoding: .utf8) else {
            throw HitomiError.badResponse
        }
        // The response is "var galleryinfo = { ... };", not plain JSON.
        if let range = text.range(of: "var galleryinfo = ") {
            text.removeSubrange(text.startIndex..<range.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") { text.removeLast() }
        guard let jsonData = text.data(using: .utf8) else { throw HitomiError.decodingFailed }
        let decoded = try JSONDecoder().decode(HitomiGalleryJSON.self, from: jsonData)
        return decoded.toDetail()
    }

    // MARK: Image URLs

    /// The thumbnail shard path — shared by webpbigtn/webpsmalltn (see coverURL/
    /// pageThumbnailURL below): directory = the LAST character of the hash, subdirectory
    /// = the 2 characters BEFORE it. FIXED (Aug 31) — the sharding used to
    /// be based on the FIRST characters (`hash.first` + `hash[1...2]`,
    /// an unconfirmed guess based on a general convention, the same class of bug
    /// as pageImageURL had with "w"/.webp instead of "a"/.avif) — a live curl test
    /// against `galleryblock/{id}.html` showed real links like
    /// `webpbigtn/3/6c/{hash}.webp` for a hash ending in "...d6c3".
    /// Because of the old formula ALL hitomi thumbnails (the cover in the catalog card,
    /// the title detail card itself) 404'd and stayed stuck as skeletons forever — meanwhile
    /// full-size READER pages loaded fine, since they
    /// use a different formula that had already been fixed earlier (gg.js, see
    /// pageImageURL) — hence the complaint "thumbnails never load, but opening
    /// the page shows the images fine".
    private static func thumbnailShard(forHash hash: String) -> (dir: String, subdir: String)? {
        guard hash.count >= 3 else { return nil }
        return (String(hash.suffix(1)), String(hash.suffix(3).prefix(2)))
    }

    /// The title cover (catalog card / title detail header) —
    /// `webpbigtn`, confirmed live ONLY for the first page
    /// (`files[0]`, the same image that `galleryblock/{id}.html` uses
    /// as the cover) — not for an arbitrary page, see pageThumbnailURL.
    fileprivate static func coverURL(forHash hash: String) -> URL? {
        guard let shard = thumbnailShard(forHash: hash) else { return nil }
        return URL(string: "https://tn.gold-usergeneratedcontent.net/webpbigtn/\(shard.dir)/\(shard.subdir)/\(hash).webp")
    }

    /// The thumbnail for ANY individual page (the preview grid on the title detail card,
    /// see ExternalGalleryDetailView.previewGridSection) — `webpsmalltn`,
    /// NOT `webpbigtn`: a live curl test confirmed that `webpbigtn` is only
    /// actually generated for the cover (see coverURL) — for the REST of a
    /// gallery's pages it 404s, while `webpsmalltn` (the same sharding,
    /// just a smaller size) exists for EVERY page — verified
    /// on several random hashes from one gallery, all 200. This used to
    /// use the SAME coverURL function both for the cover AND for
    /// every page in the preview grid — because of that, the entire preview grid
    /// on the title detail card (except the first page) stayed stuck as skeletons.
    fileprivate static func pageThumbnailURL(forHash hash: String) -> URL? {
        guard let shard = thumbnailShard(forHash: hash) else { return nil }
        return URL(string: "https://tn.gold-usergeneratedcontent.net/webpsmalltn/\(shard.dir)/\(shard.subdir)/\(hash).webp")
    }

    /// The full-size reader page — the gg.js formula: host = "a" (avif) +
    /// (gg.m(Int(gg.s(hash))) + 1), path = gg.b + gg.s(hash) + "/" + hash +
    /// ".avif". `b`/the set of `case` values in `m()` are loaded LIVE via HitomiGGCache
    /// (see its doc comment — both actually change over time). The host prefix
    /// "a"/the ".avif" extension — FIXED (Aug 30, third attempt): this used to
    /// be "w"/".webp" here — an assumption based on the general convention of public
    /// hitomi clients, NOT confirmed by live traffic; fresh HAR data captured
    /// REAL reader URLs (`a1.../*.avif`, `a2.../*.avif`, status 200) —
    /// the bucket/host-selection formula (gg.s/gg.m) was correct, the mistake was specifically
    /// in the host letter and the extension. Verified with a live curl test on several
    /// hashes from the fresh HAR plus one more title separately — all 200
    /// image/avif (Referer: hitomi.la is required — already set in session).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        let hash = page.key
        let (b, caseSet) = try await HitomiGGCache.shared.current(session: session)
        let bucket = HitomiGG.s(hash)
        let g = Int(bucket) ?? 0
        let hostNumber = HitomiGG.m(g, caseSet: caseSet) + 1
        let host = "a\(hostNumber).gold-usergeneratedcontent.net"
        guard let url = URL(string: "https://\(host)/\(b)\(bucket)/\(hash).avif") else {
            throw HitomiError.badResponse
        }
        return url
    }
}

// MARK: - JSON model for galleries/{id}.js

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
    /// Publication date — confirmed live (`"2025-03-08 15:00:00-06"`),
    /// see the plan, PART A/B.2. `date`, not `datepublished` — both fields exist in
    /// the response, but `date` is what is actually shown on the title's own
    /// page (`<span class="date">`).
    let date: String?
    let tags: [TagEntry]?
    let artists: [[String: JSONAnyValue]]?
    let groups: [[String: JSONAnyValue]]?
    let characters: [[String: JSONAnyValue]]?
    let parodys: [[String: JSONAnyValue]]?
    let related: [Int]?
    let files: [FileEntry]

    func toDetail() -> ExternalGalleryDetail {
        // pages[].thumbnailURL — webpsmalltn (see HitomiProvider.
        // pageThumbnailURL, which actually exists for EVERY page), NOT
        // coverURL/webpbigtn (that one is generated only for the cover —
        // page 1 — using it here would mean the entire
        // preview grid on the card, except the first thumbnail, 404s).
        let pages = files.enumerated().map { idx, file in
            ExternalGalleryPage(
                index: idx + 1, key: file.hash, width: file.width, height: file.height,
                thumbnailURL: HitomiProvider.pageThumbnailURL(forHash: file.hash),
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
            // The cover — SEPARATELY, webpbigtn by the first page's hash (not
            // pages.first?.thumbnailURL — that's now webpsmalltn, a smaller
            // size, fine for small preview-grid tiles but not for
            // the large card/catalog cover).
            coverURL: files.first.flatMap { HitomiProvider.coverURL(forHash: $0.hash) },
            posted: date,
            // hitomi simply doesn't have these fields — see the plan, PART B.2,
            // honestly nil/[], we're not making anything up.
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

/// In-memory cache of a multi-term AND search's fully materialized/
/// intersected id list, keyed by the exact query text — computed ONCE on
/// page 1 (see HitomiProvider.computeMultiTermIntersection), reused for
/// every following page via the "multi\u{1}..." cursor (see
/// decodeMultiSearchCursor) so scrolling doesn't repeat the network work.
/// A plain in-memory actor (not persisted across app launches) — same
/// pattern as the gg.js cache used elsewhere in this module.
actor HitomiSearchCache {
    static let shared = HitomiSearchCache()
    private var cache: [String: [Int]] = [:]

    func intersection(for key: String, compute: () async throws -> [Int]) async throws -> [Int] {
        if let cached = cache[key] { return cached }
        let result = try await compute()
        cache[key] = result
        return result
    }
}

/// artists/groups/characters/parodys — arrays of objects with DIFFERENT keys
/// (artist/group/character/parody) mixed in with "url" — handled with a
/// generic wrapper instead of introducing 4 nearly identical Decodable structs.
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
