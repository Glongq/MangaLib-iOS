import Foundation

/// Section of the alphabetical directory (see hitomi.la nav: tags/series/artists/
/// characters) — used by ExternalTagBrowserView. Not every site actually
/// has such a directory — see ExternalSiteCapabilities.hasTagBrowser
/// (e-hentai, for example, doesn't have one, see EHentaiProvider).
/// `.groups` — added together with 3hentai.net (it has `/groups` as a full-fledged
/// nav-bar entry, an `alle-groups-{letter}.html`-style page, see
/// ThreeHentaiProvider.fetchTagIndex); hitomi has no such directory
/// (only the 4 "whales": tags/series/characters/artists, see
/// HitomiProvider.fetchTagIndex — honestly returns [] for .groups), and
/// e-hentai has no directory at all, for anything (hasTagBrowser == false).
enum ExternalTagKind: Hashable {
    case tags, series, characters, artists, groups
}

/// One entry of the alphabetical list (ExternalTagBrowserView) — name + title
/// count + slug for the follow-up listing request (see fetchIdsByTag).
struct ExternalTagEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let slug: String
}

/// One search-autocomplete entry (see HitomiProvider.fetchAutocomplete) —
/// category — exactly as returned by the server ("tag"/"series"/"character"/"group"/
/// "artist"/"language"/"female"/"male"/"type").
struct ExternalTagSuggestion: Hashable {
    let name: String
    let count: Int
    let category: String
}

/// Namespace of a tag/entity for a title listing (fetchIdsByTag) — a GENERAL
/// concept, not tied to any specific site: each provider decides for itself
/// how to turn a given case into ITS OWN URL/parameter (see
/// HitomiProvider/EHentaiProvider — the mapping differs, which is why there's
/// deliberately no .rawValue here tied to any one site's URL scheme).
enum ExternalTagNamespace: Hashable {
    case tag, female, male, character, artist, group, series
}

/// One tag on a title card (ExternalGalleryDetail.tags) — female/male
/// are both false at once for neutral tags (not tied to a gender).
struct ExternalGalleryTag: Hashable {
    let name: String
    let female: Bool
    let male: Bool
}

/// One page of a title. `key` — the identifier of specifically THIS image:
/// for hitomi it's the actual file hash (used in the gg.js formula, see
/// HitomiProvider.pageImageURL); for e-hentai it's the imgkey (needed to obtain
/// a temporary, time-limited link to an H@H node, see
/// EHentaiProvider.pageImageURL — there the link can't be computed ahead of
/// time, only via a live request). `width`/`height` are 0 when the real size
/// isn't known in advance (for e-hentai it's only discovered when a
/// specific page is opened — until then there's simply no data).
/// `thumbnailURL` — a static link to the THUMBNAIL of specifically this page
/// (not the full-size image) — for hitomi it's the same hash-sharding formula
/// as the cover (HitomiProvider.coverURL, applicable to any
/// page, not just the first); for e-hentai it's the real CSS background-image
/// URL of the thumbnail strip, confirmed by HAR directly in the markup of `/g/{id}/{token}/`
/// (`<div style="...url(https://.../{id}-{n}.webp)...">`). Used in the
/// preview grid of the title card (see ExternalGalleryDetailView, plan PART B.3).
struct ExternalGalleryPage: Hashable {
    let index: Int
    let key: String
    let width: Int
    let height: Int
    let thumbnailURL: URL?
    /// Offset (in pixels, X axis) of this page's thumbnail tile within
    /// `thumbnailURL` — for e-hentai thumbnails are NOT delivered as a separate
    /// image per page, but as a shared "sprite" for a batch of pages (~20, the size
    /// of one ?p=N chunk) plus CSS `background-position` (confirmed
    /// byte-for-byte from real markup: `style="width:200px;height:278px;
    /// background:transparent url(.../{id}-{n}.webp) -200px 0 no-repeat"` —
    /// the same link for N consecutive pages, differing only in this
    /// offset, a multiple of the tile width). Without accounting for the offset, all pages of one
    /// batch would show the exact same sprite in full — see
    /// EHentaiProvider.parsePages/ExternalSpriteThumbnail. nil for hitomi
    /// (there thumbnailURL already points to a separate image of exactly that
    /// page, no cropping needed).
    let thumbnailSpriteOffsetX: Int?
}

/// One comment on a title (see ExternalGalleryDetail.comments) — currently
/// confirmed by HAR only for e-hentai (`<div id="cdiv">`, see plan PART
/// B.5); hitomi has no concept of comments at all (not a single
/// comment-related request in any HAR) — there `comments` is always `[]`.
struct ExternalComment: Identifiable, Hashable {
    let id: Int
    let author: String
    let postedAt: String
    let text: String
}

/// Full title metadata (see HitomiProvider/EHentaiProvider.
/// fetchGalleryDetail) — used both for the card and for building the reading
/// page list. `coverURL` — the READY-MADE cover/preview link built by
/// the provider itself (for hitomi — via the hash-sharding formula, for e-hentai —
/// simply the ready-made link straight from the HTML) — this used to be a separate
/// protocol function (thumbnailURL(hash:)), but the formula turned out to be
/// hitomi-specific (e-hentai doesn't use it at all), so now
/// each provider decides for itself where to get the cover from and just
/// puts the finished URL here.
struct ExternalGalleryDetail: Identifiable {
    let id: Int
    /// Which specific site returned this title — needed for the combined
    /// catalog/listing (see ExternalCombinedCatalogView, ExternalCatalogItem)
    /// and for the label on the card (ExternalGalleryDetailView), where the title could
    /// have come either from the single active site, or (in combined mode)
    /// from any one of several enabled at once.
    let site: ExternalSite
    let title: String
    let type: String
    let language: String?
    let tags: [ExternalGalleryTag]
    let artists: [String]
    let groups: [String]
    let characters: [String]
    let series: [String]
    let related: [Int]
    let pages: [ExternalGalleryPage]
    let coverURL: URL?
    /// Posted — for hitomi it's `date` from galleries/{id}.js, for
    /// e-hentai it's the string from `gdt1"Posted:"`/`gdt2` — both sites genuinely
    /// have it, see plan PART B.2.
    let posted: String?
    /// Below — metadata that hitomi physically DOES NOT HAVE (we don't make it up,
    /// see plan PART B.2) — filled in only by EHentaiProvider; for
    /// HitomiProvider it's always nil/[].
    let parentId: Int?
    let visible: String?
    let fileSize: String?
    let favoritedCount: String?
    let ratingAverage: Double?
    let ratingCount: Int?
    let comments: [ExternalComment]
}

/// Shared protocol for one external site — implemented by a separate type for
/// each site (see HitomiProvider/EHentaiProvider). Has nothing in common with
/// MangaNetworkService — each provider has its own session/parsing/models.
protocol ExternalSiteProvider {
    var site: ExternalSite { get }
    var capabilities: ExternalSiteCapabilities { get }

    /// Alphabetical list (letter A-Z/123) — see ExternalTagBrowserView.
    /// The implementation is required to exist (the protocol demands it), but if
    /// the site has no such directory (capabilities.hasTagBrowser == false)
    /// — it just returns [] and is never actually called by the real UI (which
    /// checks capabilities itself before showing the screen).
    /// `Swift.Character`, not bare `Character` — this module declares
    /// ITS OWN `Character` type (see MangaModels.swift — the model of a title's
    /// character), which otherwise shadows the standard single-character type and
    /// breaks compilation (not caught by the local brace-balance check,
    /// only by an actual build — see .github/workflows/ios.yml).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry]

    /// Autocomplete while typing in search. Like fetchTagIndex — it's fine to
    /// honestly return [] if the site has no such endpoint / it isn't confirmed.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion]

    /// Title IDs for one tag/series/character/group/artist, paginated.
    /// `cursor` — an OPAQUE page token (not a number!) — for hitomi it's a
    /// byte offset as a string, for e-hentai — the id of the last title on
    /// the current page (the site's actual real pagination scheme, `&next=...`) —
    /// hence not a uniform "offset: Int", just "whatever the
    /// previous call returned". nil — first page. `nextCursor == nil` in the response
    /// means there are no more titles.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Same, but with sorting (see ExternalSiteCapabilities.
    /// hasSortOptions) — `sortKey` is OPAQUE, site-specific
    /// (see HitomiProvider.SortOption.rawValue) — the same principle as
    /// excludedCategoryBits in fetchIdsBySearch below (Int/String, not a shared
    /// enum, so the protocol isn't tied to one site's type). nil/"" — default
    /// sorting. A REAL protocol requirement for the same reason as
    /// the other optional parameters below — otherwise an
    /// override in HitomiProvider wouldn't be picked up through `any
    /// ExternalSiteProvider`. The default implementation (see the extension below)
    /// simply ignores sortKey — so EHentaiProvider doesn't have to know
    /// anything about sorting (it has capabilities.hasSortOptions == false).
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Free-text search (see ExternalSiteCapabilities.hasSearch) —
    /// hitomi formally doesn't have one (see HitomiProvider — an honest empty
    /// stub); e-hentai has an ordinary sitewide `?f_search=`.
    /// Same opaque-cursor pagination as fetchIdsByTag.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Same, but with a category filter (see
    /// ExternalSiteCapabilities.hasCategoryFilter, EHentaiCategory) —
    /// `excludedCategoryBits` — a bitmask of EXCLUDED categories (0 — no
    /// restriction). A real protocol requirement (not just an extension
    /// method) — otherwise an override in EHentaiProvider wouldn't be picked up
    /// when called through `any ExternalSiteProvider` (dispatch for extension
    /// methods that aren't part of the protocol's requirement list is static,
    /// not polymorphic). The default implementation (see the extension below) just
    /// ignores the bitmask and falls back to the plain fetchIdsBySearch — so
    /// HitomiProvider doesn't have to know anything about categories.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Same, but with both categories and sorting at once (see sortKey
    /// in fetchIdsByTag above) — a REAL protocol requirement for the same
    /// reason.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// The cursor corresponding to the start of PAGE `page` (1-based, by `limit`
    /// items per page) — for the "Jump to page" button (see
    /// ExternalSiteCapabilities.hasPageJump, ExternalCatalogGridView). For
    /// hitomi this is an EXACT jump (offset is just a plain item count, always
    /// available); for e-hentai it's an APPROXIMATE one (see EHentaiProvider —
    /// `range=`, confirmed by HAR, but the exact page-number→range formula
    /// isn't documented by the site). `page <= 1` — nil (the first page
    /// opens without a cursor anyway). Synchronous — a pure computation, no
    /// network, for both current providers. The default implementation (see the
    /// extension below) — always nil, for a site without
    /// capabilities.hasPageJump; a REAL protocol requirement for the same reason
    /// as fetchIdsBySearch(excludedCategoryBits:) above — otherwise an override
    /// wouldn't be picked up through `any ExternalSiteProvider`.
    func cursorForPage(_ page: Int, limit: Int) -> String?

    /// Full title metadata — for the card and for reading.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail

    /// URL of the full-size page for reading. For hitomi — a pure formula
    /// (gg.js), no network, just wrapped in async for the sake of the shared protocol; for
    /// e-hentai — a REAL network request every time (the link to the H@H node is
    /// temporary, with an expiring keystamp — it can't be computed ahead of time and
    /// can't be cached for long).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL
}

extension ExternalSiteProvider {
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, cursor: cursor, limit: limit)
    }

    func cursorForPage(_ page: Int, limit: Int) -> String? { nil }
}

/// Simple static provider registry — no DI magic, there isn't any
/// anywhere in the project (see plan).
enum ExternalSiteRegistry {
    static let providers: [ExternalSite: any ExternalSiteProvider] = [
        .hitomi: HitomiProvider(),
        .ehentai: EHentaiProvider(),
        .threeHentai: ThreeHentaiProvider(),
        .imhentai: ImhentaiProvider(),
        .hentaiPill: HentaiPillProvider(),
        .simplyHentai: SimplyHentaiProvider()
    ]

    static func provider(for site: ExternalSite) -> any ExternalSiteProvider {
        providers[site] ?? HitomiProvider()
    }
}
