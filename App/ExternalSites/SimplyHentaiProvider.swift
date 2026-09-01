import Foundation

/// Errors for SimplyHentaiProvider.
enum SimplyHentaiError: Error {
    case badResponse
    /// fetchGalleryDetail(id:) was called with an id that this session
    /// has NEVER yet seen in any listing/search result (see the type's
    /// doc-comment about slug addressing) — without an id→slug pair the
    /// card can't be opened.
    case unknownSlug
}

/// Advanced search fields — added by direct request (Aug 31, then refined
/// Sep 1): for simply-hentai, `/search/complex` really does accept
/// `query=` AND `filter[tags][N]=`/`filter[parodies][N]=`/
/// `filter[characters][N]=`/`filter[artists][N]=`/`filter[translators][N]=`/
/// `filter[language][N]=`/`filter[series_title][N]=` all IN ONE request
/// (confirmed by HAR — a real chain from the HAR literally carries all of
/// them at once: `filter[series_title][0]=
/// Danganronpa&filter[tags][0]=Bondage&filter[tags][1]=Ahegao&filter[tags]
/// [2]=Anal&filter[artists][0]=matou&query=scat&page=1`).
///
/// The EXCLUSIVE scheme (by direct request, shared by all sites with
/// advanced fields — see ExternalSearchView.resolvedQuery): if at least
/// one of these fields is filled in (including the field's own search —
/// it REPLACES the screen's general field, it does NOT combine with it),
/// the screen's general search field stops participating for this site at
/// all — the request is built ONLY from these fields. If they're all
/// empty — same as before, the usual general field.
struct SimplyHentaiAdvancedQuery {
    /// The field's own search string — used INSTEAD OF the screen's
    /// general field when at least one field of this struct is filled in
    /// (see isEmpty).
    var search: String = ""
    var tags: [String] = []
    var parodies: [String] = []
    var characters: [String] = []
    var artists: [String] = []
    var translators: [String] = []
    var language: [String] = []
    var seriesTitle: String = ""

    var isEmpty: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty
            && tags.isEmpty && parodies.isEmpty && characters.isEmpty && artists.isEmpty
            && translators.isEmpty && language.isEmpty
            && seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The delimiter — the U+0001 control character, which no user will
    /// ever type by hand into a search string — is NOT the site's own
    /// syntax (unlike `+tag:"..."` for imhentai); it's a PURELY internal
    /// channel between ExternalSearchView/
    /// ExternalCombinedCatalogView.resolvedQuery and
    /// SimplyHentaiProvider.fetchIdsBySearch: the ExternalSiteProvider
    /// protocol carries the query as ONE string (see
    /// ExternalCatalogQuery.search), so this is how the extra fields get
    /// "soldered in" here, and the provider unpacks them right back into
    /// separate `filter[...]=` parameters before the actual request — these
    /// control characters never make it out into the URL.
    fileprivate static let fieldDelimiter = "\u{1}"

    /// Encodes itself entirely into one string for
    /// ExternalCatalogQuery.search(query:) — see the fieldDelimiter
    /// doc-comment. Called ONLY when !isEmpty (see
    /// ExternalSearchView.resolvedQuery) — the field's own search replaces
    /// the screen's general field, it doesn't combine with it.
    func encoded() -> String {
        var parts = [search.trimmingCharacters(in: .whitespaces)]
        func append(_ key: String, _ values: [String]) {
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                parts.append("\(Self.fieldDelimiter)\(key)=\(trimmed)")
            }
        }
        append("tags", tags)
        append("parodies", parodies)
        append("characters", characters)
        append("artists", artists)
        append("translators", translators)
        append("language", language)
        let trimmedSeries = seriesTitle.trimmingCharacters(in: .whitespaces)
        if !trimmedSeries.isEmpty {
            parts.append("\(Self.fieldDelimiter)series_title=\(trimmedSeries)")
        }
        return parts.joined()
    }
}

/// Client for simply-hentai.com — its OWN, fully separate implementation.
/// All endpoints below are confirmed by the user's real HAR (evening of
/// Aug 31, `ProxyPin8-31_22_33_54.har`) — NOT double-checked with a live
/// curl: `api-v3.simply-hentai.com` responds from this sandbox with a
/// Cloudflare-JS challenge ("Just a moment...", 403) on any path, exactly
/// the same picture as ImhentaiProvider (see its doc-comment about the
/// difference between a plain `URLSession` and a real browser — the same
/// principle applies here too, not repeated separately).
///
/// Unlike all four other sites, this one has a REAL versioned JSON REST
/// API (`/v3/...`, a Next.js frontend on www on top of it), not HTML pages
/// to parse with regexes — the response structure was taken from the
/// decoded Codable models below, matching the real fields from HAR one to
/// one.
///
/// IMPORTANT about addressing: an album has BOTH a numeric `id` AND a
/// `slug`, but `/v3/manga/{slug}` (the card) and `/v3/manga/{slug}/pages`
/// (the pages) are addressed ONLY by slug — NOT A SINGLE request by
/// numeric id turned up in HAR, and it wasn't double-checked live, so we
/// honestly don't risk assuming that `/v3/manga/{id}` would work too.
/// `fetchIdsByTag`/`fetchIdsBySearch` are required by the protocol
/// contract to return `[Int]` (see ExternalSiteProvider) — so
/// SimplyHentaiSlugCache remembers the id→slug pair on EVERY album parse
/// from any response (listing/search/tag/similar), and
/// fetchGalleryDetail(id:) takes the slug from there. This works reliably
/// as long as the card is opened from a listing/similar-titles list (as it
/// always is in this app) — the only case where this wouldn't work is an
/// id obtained from OUTSIDE the app (that doesn't happen here).
struct SimplyHentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .simplyHentai
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // The alphabetical index — Tags/Parodies/Characters are confirmed
        // by HAR (`/v3/tags?type={tags|parodies|characters}&letter=...`,
        // letters `a`...`z` were really enumerated). Artists/Translators —
        // the site DOES KNOW such entities (the `artists`/`translators`
        // fields in the album card, and `filter[artists][]`/
        // `filter[translators][]` in /search/complex are confirmed), but
        // an alphabetical list for them was never requested — honestly []
        // in fetchTagIndex, we don't make up a letter request that
        // doesn't exist in HAR.
        hasTagBrowser: true,
        // /v3/search/complex?query=... — confirmed by HAR (plain text,
        // real relevant results on "scat"/"genshin"-like queries).
        // The multi-filter is separately confirmed too (filter[tags][]/
        // filter[parodies][]/filter[characters][]/filter[artists][]/
        // filter[translators][]/filter[language][]/filter[series_title][]
        // — all of them showed up in HAR as real combinations TOGETHER
        // with query=, see SimplyHentaiAdvancedQuery/
        // SimplyHentaiAdvancedFieldsPicker).
        hasSearch: true,
        // There's no EHentaiCategory-like bitmask category switcher —
        // but the flag is reused (the same trick as imhentai) as the
        // general "there's a Filters sheet" gate in ExternalSearchView/
        // ExternalCombinedCatalogView: here it opens
        // SimplyHentaiAdvancedFieldsPicker (Tags/Parodies/Characters/
        // Artists/Translators/Language/Series title), not categories.
        hasCategoryFilter: true,
        // Pagination is HONEST, server-driven: `pagination.current/next/
        // pages/count` in every response (not our guess based on the
        // presence of a "next" button, like the HTML sites) — confirmed
        // on /tags, /tag/{slug}, /search/complex, /mangas.
        hasPageJump: true,
        // Not once did a `sort=` parameter show up in HAR either on
        // /search/complex or on /tag/{slug} (only on separate endpoints
        // unrelated to search/tag — /mangas?sort=spotlight,
        // /tags?sort=popularity — that sorts the tag list ITSELF, not an
        // album listing) — honestly false, we don't make up a
        // combination that doesn't exist.
        hasSortOptions: false,
        // Same as the other external sites in this client — no account
        // login (see the doc-comment on ImhentaiProvider.capabilities).
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // `comment_count` is just a number right on the album, not a
        // single separate endpoint with a LIST of comments turned up in
        // HAR — honestly false, we don't make it up.
        hasComments: false
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://www.simply-hentai.com",
            "Referer": "https://www.simply-hentai.com/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://api-v3.simply-hentai.com/v3"

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: id→slug cache (see the type's doc-comment)

    private actor SlugCache {
        static let shared = SlugCache()
        private var map: [Int: String] = [:]
        func store(id: Int, slug: String) { map[id] = slug }
        func slug(for id: Int) -> String? { map[id] }
    }

    // MARK: Codable models — matching the real `/v3/...` responses from HAR one to one.

    private struct SizesDTO: Decodable {
        let full: String
        let thumb: String?
        let smallThumb: String?
        let giantThumb: String?
    }

    private struct PageDTO: Decodable {
        let id: Int
        let pageNum: Int?
        let sizes: SizesDTO
    }

    private struct LanguageDTO: Decodable {
        let name: String
        let slug: String?
        let flagCode: String?
    }

    /// A single Tags/Parodies/Characters/Artists/Series tag element — the
    /// same shape as the nested `tags`/`parodies`/`characters`/`artists`/
    /// `series` in the album card, see TagRefDTO.
    private struct TagRefDTO: Decodable {
        let id: Int
        let slug: String
        let title: String
        let letter: String?
        let objectCount: Int?
        let type: String?
    }

    private struct InteractionsDTO: Decodable {
        let upvotes: Int?
        let downvotes: Int?
        let favorites: Int?
    }

    /// The shared album model — used both in listings (where `related`/
    /// `pages`/the full `tags` are usually absent, just nil) and in the
    /// detailed `/v3/manga/{slug}` response (where everything is already
    /// filled in, except `pages` — which lives in a SEPARATE
    /// `/v3/manga/{slug}/pages` response, see fetchGalleryDetail).
    private struct AlbumDTO: Decodable {
        let id: Int
        let slug: String
        let title: String
        let description: String?
        let imageCount: Int?
        let commentCount: Int?
        let language: LanguageDTO?
        let preview: PageDTO?
        let series: TagRefDTO?
        let tags: [TagRefDTO]?
        let parodies: [TagRefDTO]?
        let characters: [TagRefDTO]?
        let artists: [TagRefDTO]?
        // The site has no separate notion of "groups" (scanlation
        // groups) — it has translators instead, see the doc-comment on
        // ExternalGalleryDetail about where they land in the app's
        // shared model.
        let translators: [TagRefDTO]?
        let related: [AlbumDTO]?
        let createdAt: String?
        let interactions: InteractionsDTO?
    }

    private struct SearchResultItemDTO: Decodable {
        let object: AlbumDTO
    }

    private struct PaginationDTO: Decodable {
        let current: Int?
        let next: Int?
    }

    private struct ListResponseDTO<T: Decodable>: Decodable {
        let data: [T]
        let pagination: PaginationDTO?
    }

    private struct DetailResponseDTO<T: Decodable>: Decodable {
        let data: T
    }

    private struct TagDetailDataDTO: Decodable {
        let albums: [AlbumDTO]
    }

    private struct TagDetailResponseDTO: Decodable {
        let data: TagDetailDataDTO
        let pagination: PaginationDTO?
    }

    private struct PagesDataDTO: Decodable {
        let pages: [PageDTO]
    }

    // MARK: Alphabetical index (Tags/Parodies/Characters)

    private static func tagsListType(for kind: ExternalTagKind) -> String? {
        switch kind {
        case .tags: return "tags"
        case .series: return "parodies"
        case .characters: return "characters"
        // Not confirmed by HAR — the site never requested an
        // alphabetical list of artists/translators, see the
        // capabilities.hasTagBrowser doc-comment.
        case .artists: return nil
        case .groups: return nil
        }
    }

    /// The letter — only a...z (confirmed by HAR); a separate bucket for
    /// digits/symbols never turned up — honestly [] on letter.isNumber,
    /// we don't guess the signal. Pagination is real, server-driven
    /// (`pagination.next`), not a guess based on the presence of content.
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        guard !letter.isNumber, let typeValue = Self.tagsListType(for: kind) else { return [] }
        let letterParam = String(letter).lowercased()
        var result: [ExternalTagEntry] = []
        var page = 1
        while page <= 30 {
            let urlString = "\(Self.baseURL)/tags?type=\(typeValue)&letter=\(letterParam)&page=\(page)"
            guard let url = URL(string: urlString) else { break }
            let decoded: ListResponseDTO<TagRefDTO>
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { break }
                decoded = try Self.decoder.decode(ListResponseDTO<TagRefDTO>.self, from: data)
            } catch {
                break
            }
            for tag in decoded.data {
                result.append(ExternalTagEntry(id: tag.slug, name: tag.title, count: tag.objectCount ?? 0, slug: tag.slug))
            }
            guard let next = decoded.pagination?.next, next > page else { break }
            page = next
        }
        return result
    }

    /// Autocomplete is REAL, confirmed by HAR (`/v3/search/autocomplete?
    /// q=scat` → a live array of relevant suggestion strings). It returns
    /// plain text (titles/tags mixed together), with no title count/
    /// category — honestly `count: 0`/`category: "search"`, we don't make
    /// up what the site didn't send.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.baseURL)/search/autocomplete?q=\(encoded)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let suggestions = try Self.decoder.decode([String].self, from: data)
            return suggestions.map { ExternalTagSuggestion(name: $0, count: 0, category: "search") }
        } catch {
            return []
        }
    }

    // MARK: Title list by tag/parody/character/artist

    /// `type=tag` is confirmed live by HAR (`/v3/tag/females-only?type=tag`).
    /// `parody`/`character`/`artist`/`translator` — BY SYMMETRY with that
    /// same endpoint (the same URL shape, the same `type` parameter as
    /// the `/v3/tags?type={tags|parodies|characters}` listing) — not
    /// separately double-checked with a live request for each variant.
    private static func tagDetailType(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male: return "tag"
        case .series: return "parody"
        case .character: return "character"
        case .artist: return "artist"
        case .group: return "translator"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `value` is either a ready-made slug (from
    /// ExternalTagBrowserView/entry.slug — used AS-IS, reliably), or a
    /// plain display name from a chip on the title card
    /// (ExternalGalleryDetailView) — in which case we slugify it ourselves
    /// with the shared formula (see slugify). IMPORTANT: for some of the
    /// site's tags the slug carries an unpredictable numeric
    /// disambiguating prefix (a real example from HAR: the tag "Ahegao" →
    /// slug "1-ahegao", not just "ahegao") — this CANNOT be recovered from
    /// the display name alone. The same class of imperfection already
    /// accepted for the other providers' chip-tap flow (see the
    /// doc-comment on ThreeHentaiProvider.slugify) — navigating from the
    /// alphabetical index (where the slug is real) is always reliable,
    /// navigating via a chip on the card is the best possible
    /// approximation, and will occasionally miss.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let type = Self.tagDetailType(for: namespace)
        let slug = Self.slugify(value)
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let page = Int(cursor ?? "1") ?? 1
        let urlString = "\(Self.baseURL)/tag/\(encodedSlug)?type=\(type)&page=\(page)"
        guard let url = URL(string: urlString) else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        let decoded = try Self.decoder.decode(TagDetailResponseDTO.self, from: data)
        var ids: [Int] = []
        for album in decoded.data.albums {
            await SlugCache.shared.store(id: album.id, slug: album.slug)
            ids.append(album.id)
        }
        return (ids, decoded.pagination?.next.map(String.init))
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

    /// `query` may carry embedded `filter[...]` tokens on top of the free
    /// text (see SimplyHentaiAdvancedQuery.encoded/fieldDelimiter
    /// doc-comment — ExternalSearchView/ExternalCombinedCatalogView solder
    /// them in there) — here they're unpacked back into real
    /// `filter[key][N]=value` parameters for `/search/complex`.
    /// A fully empty query (no text, no filters) → `/v3/mangas?
    /// sort=spotlight` (the only confirmed HAR "default feed"; the site
    /// honestly paginates it — 415 pages in the response, real
    /// pagination, not a one-page stub like HentaiPill). Otherwise →
    /// `/v3/search/complex?query=...&filter[...]=...` — the query+filter
    /// combination itself is confirmed by HAR (see the doc-comment on
    /// SimplyHentaiAdvancedQuery with the exact parameter chain from a
    /// live user request).
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let (freeText, filters) = Self.decodeQuery(query)
        let trimmedFreeText = freeText.trimmingCharacters(in: .whitespaces)
        let page = Int(cursor ?? "1") ?? 1
        let isSpotlight = trimmedFreeText.isEmpty && filters.isEmpty
        let urlString: String
        if isSpotlight {
            urlString = "\(Self.baseURL)/mangas?sort=spotlight&page=\(page)"
        } else {
            var items: [String] = []
            if !trimmedFreeText.isEmpty {
                let encoded = trimmedFreeText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedFreeText
                items.append("query=\(encoded)")
            }
            for (key, values) in filters {
                for (index, value) in values.enumerated() {
                    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                    items.append("filter[\(key)][\(index)]=\(encodedValue)")
                }
            }
            items.append("page=\(page)")
            urlString = "\(Self.baseURL)/search/complex?" + items.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        var ids: [Int] = []
        let nextCursor: String?
        if isSpotlight {
            let decoded = try Self.decoder.decode(ListResponseDTO<AlbumDTO>.self, from: data)
            for album in decoded.data {
                await SlugCache.shared.store(id: album.id, slug: album.slug)
                ids.append(album.id)
            }
            nextCursor = decoded.pagination?.next.map(String.init)
        } else {
            let decoded = try Self.decoder.decode(ListResponseDTO<SearchResultItemDTO>.self, from: data)
            for item in decoded.data {
                await SlugCache.shared.store(id: item.object.id, slug: item.object.slug)
                ids.append(item.object.id)
            }
            nextCursor = decoded.pagination?.next.map(String.init)
        }
        return (ids, nextCursor)
    }

    /// Unpacks the embedded tokens from SimplyHentaiAdvancedQuery.encoded()
    /// back into (free text, [filter key: values]) — see its
    /// fieldDelimiter doc-comment. The dictionary's key order is
    /// unpredictable — that's OK, `/search/complex` doesn't document the
    /// order of filter fields, each key goes with its own separate set of
    /// `[N]` indices.
    private static func decodeQuery(_ raw: String) -> (freeText: String, filters: [String: [String]]) {
        let pieces = raw.components(separatedBy: SimplyHentaiAdvancedQuery.fieldDelimiter)
        let freeText = pieces.first ?? ""
        var filters: [String: [String]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<eq])
            let value = String(piece[piece.index(after: eq)...])
            guard !value.isEmpty else { continue }
            filters[key, default: []].append(value)
        }
        return (freeText, filters)
    }

    // MARK: Title card

    /// Two separate requests — `/v3/manga/{slug}` (metadata + a preview of
    /// the first pages + similar titles) and `/v3/manga/{slug}/pages` (the
    /// FULL page list, confirmed by HAR: the detail response's `images`
    /// only has 12 out of the stated 173 — the full list is only in the
    /// separate /pages) — run in parallel (async let), not sequentially.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let slug = await SlugCache.shared.slug(for: id) else { throw SimplyHentaiError.unknownSlug }
        async let detailTask = Self.fetchAlbum(slug: slug, session: session)
        async let pagesTask = Self.fetchPages(slug: slug, session: session)
        let (detail, pages) = try await (detailTask, pagesTask)
        for rel in detail.related ?? [] {
            await SlugCache.shared.store(id: rel.id, slug: rel.slug)
        }
        return Self.buildGalleryDetail(id: id, detail: detail, pages: pages)
    }

    private static func fetchAlbum(slug: String, session: URLSession) async throws -> AlbumDTO {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "\(baseURL)/manga/\(encoded)") else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        return try decoder.decode(DetailResponseDTO<AlbumDTO>.self, from: data).data
    }

    private static func fetchPages(slug: String, session: URLSession) async throws -> [PageDTO] {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard let url = URL(string: "\(baseURL)/manga/\(encoded)/pages") else { throw SimplyHentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw SimplyHentaiError.badResponse }
        return try decoder.decode(DetailResponseDTO<PagesDataDTO>.self, from: data).data.pages
    }

    /// `width`/`height` — the site doesn't provide these for pages
    /// (unlike HentaiPill) — honestly 0 (see the doc-comment on
    /// ExternalGalleryPage — this is the standard "not known in advance"
    /// value). `key` is already a ready-made absolute URL of the
    /// full-size image (`sizes.full`), with no formula/CDN sharding at
    /// all, see pageImageURL.
    private static func buildGalleryDetail(id: Int, detail: AlbumDTO, pages: [PageDTO]) -> ExternalGalleryDetail {
        let tags = (detail.tags ?? []).map { ExternalGalleryTag(name: $0.title, female: false, male: false) }
        let pageModels = pages.enumerated().map { offset, page in
            ExternalGalleryPage(
                index: offset + 1,
                key: page.sizes.full,
                width: 0, height: 0,
                thumbnailURL: URL(string: page.sizes.thumb ?? page.sizes.full),
                thumbnailSpriteOffsetX: nil
            )
        }
        return ExternalGalleryDetail(
            id: id,
            site: .simplyHentai,
            title: detail.title,
            // The site has no confirmed notion of a "title category"
            // (Manga/Doujinshi/...) — `type` in the JSON is always
            // literally "Album", not a useful category — honestly
            // empty, we don't make it up.
            type: "",
            language: detail.language?.name,
            tags: tags,
            artists: (detail.artists ?? []).map(\.title),
            // Translators are the closest semantic equivalent to
            // "groups" in the app's shared model (see the doc-comment
            // on AlbumDTO.translators) — the site has no concept of a
            // "group" of its own.
            groups: (detail.translators ?? []).map(\.title),
            characters: (detail.characters ?? []).map(\.title),
            series: (detail.parodies ?? []).map(\.title),
            related: (detail.related ?? []).map(\.id),
            pages: pageModels,
            coverURL: (detail.preview?.sizes.full).flatMap(URL.init(string:)),
            posted: detail.createdAt,
            parentId: nil, visible: nil, fileSize: nil,
            favoritedCount: detail.interactions?.favorites.map(String.init),
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    // MARK: Image URLs

    /// No network — `page.key` already carries a ready-made absolute
    /// `sizes.full` URL straight from the `/manga/{slug}/pages` response
    /// (see buildGalleryDetail).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: page.key) else { throw SimplyHentaiError.badResponse }
        return url
    }
}
