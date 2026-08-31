import Foundation

/// "Other sites" — sites with a FUNDAMENTALLY different API, not part of
/// the Lib.social ecosystem (see LibSite.swift — mangalib/slashlib/ranobelib/
/// hentailib, a single REST/JSON API across two hosts). Per a direct
/// request, the new code barely overlaps with the old networking layer —
/// see this whole file and the rest of App/ExternalSites/: nothing here
/// gets imported into MangaNetworkService.swift/LibSite.swift, and vice versa.
enum ExternalSite: String, CaseIterable, Identifiable, Codable {
    case hitomi
    case ehentai
    case threeHentai
    case imhentai
    case hentaiPill
    case simplyHentai
    // Further sites get added here as their HAR captures are analyzed (see the plan).

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hitomi: return "Hitomi.la"
        case .ehentai: return "E-Hentai"
        case .threeHentai: return "3Hentai"
        case .imhentai: return "IMHentai"
        case .hentaiPill: return "HentaiPill"
        case .simplyHentai: return "Simply Hentai"
        }
    }
}

/// Capabilities of a specific external site — screens ask THIS (via
/// ExternalSiteProvider.capabilities) instead of trying to guess from the
/// site's type: each provider honestly declares what it can actually do,
/// and screens show everything else as "Unavailable" (see
/// ExternalScreenContent).
///
/// Unlike hitomi.la, e-hentai.org DOES have accounts and bookmarks/
/// favorites on the actual site — but this integration doesn't wire them up
/// (no login), so hasBookmarks etc. is still false here — this means
/// "unavailable IN THIS CLIENT", not "the site fundamentally has no such
/// thing" (as is honestly the case for hitomi). If account login for
/// e-hentai is ever added, this just flips to true, with no rework of
/// anything else needed.
struct ExternalSiteCapabilities {
    var hasCatalog: Bool
    var hasTagBrowser: Bool
    /// Free-text search (see ExternalSiteProvider.fetchIdsBySearch) —
    /// hitomi formally has none (blocked by an unparsed binary index),
    /// e-hentai does (a plain `?f_search=`). The catalog screen
    /// (see MangaCatalogView) picks the alphabetical browser OR search
    /// based on this flag — if neither is available, the catalog is also
    /// "Unavailable", like the other screens with no equivalent.
    var hasSearch: Bool
    /// Category filter (Doujinshi/Manga/Artist CG/... — see
    /// EHentaiCategory) on top of hasSearch — only e-hentai has it (buttons
    /// right on the site's home page). false for sites with no such
    /// categorization in this sense (hitomi has a similar "type" concept in
    /// its tags, but there's no dedicated UI filter for it in this client).
    var hasCategoryFilter: Bool
    /// "Jump to page N" (see ExternalSiteProvider.cursorForPage,
    /// ExternalCatalogGridView) — exact for hitomi (offset is a plain
    /// number), approximate for e-hentai (see EHentaiProvider — `range=`,
    /// confirmed by HAR as a real jump, but without an exact formula).
    var hasPageJump: Bool
    /// Sorting of results (see ExternalSiteProvider.fetchIdsByTag(sortKey:)/
    /// fetchIdsBySearch(sortKey:), ExternalCatalogGridView) — confirmed by
    /// live HAR ONLY for hitomi (`popular/{period}[-{...}]-all.nozomi`,
    /// see HitomiProvider.SortOption) — no confirmation for e-hentai,
    /// honestly false, the sort button isn't shown there.
    var hasSortOptions: Bool
    var hasBookmarks: Bool
    var hasHistory: Bool
    var hasNotifications: Bool
    var hasComments: Bool
}
