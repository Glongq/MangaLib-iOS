import Foundation

/// A user-named snapshot of one "Filters" tab's state in
/// ExternalCombinedCatalogView — either the whole "All" tab (every site's
/// filters together, `site == nil`) or one specific site's own section.
/// Created via the "Save filter" chip in the "Saved filters" screen
/// (ExternalCombinedCatalogView.savedFiltersSheet) and re-applied by
/// tapping its row (see applySavedFilter). Same in-memory-only lifetime as
/// the rest of ExternalCatalogFilterStore — doesn't need to survive a
/// relaunch.
struct ExternalSavedFilter: Identifiable {
    let id = UUID()
    var name: String
    let site: ExternalSite?
    var excludedCategoriesEH: Set<EHentaiCategory> = []
    var excludedCategoriesIH: Set<ImhentaiCategory> = []
    var excludedLanguagesIH: Set<ImhentaiLanguage> = []
    var advancedQueryEH = EHentaiAdvancedQuery()
    var advancedQueryIH = ImhentaiAdvancedQuery()
    var advancedQuerySH = SimplyHentaiAdvancedQuery()
    var advancedQuery3H = ThreeHentaiAdvancedQuery()
    var advancedQueryHP = HentaiPillAdvancedQuery()
    var advancedQueryHT = HitomiAdvancedQuery()

    /// Active-filter count, for the small badge next to the name in the
    /// saved-filters list — same formula as
    /// ExternalCombinedCatalogView.excludedCategoryCount(for:).
    var filterCount: Int {
        excludedCategoriesEH.count + excludedCategoriesIH.count + excludedLanguagesIH.count
            + advancedQueryEH.tags.count + advancedQueryEH.series.count + advancedQueryEH.characters.count + advancedQueryEH.artists.count + advancedQueryEH.groups.count
            + advancedQueryIH.tags.count + advancedQueryIH.parodies.count + advancedQueryIH.artists.count + advancedQueryIH.characters.count + advancedQueryIH.groups.count
            + advancedQuerySH.tags.count + advancedQuerySH.parodies.count + advancedQuerySH.characters.count + advancedQuerySH.artists.count + advancedQuerySH.translators.count + advancedQuerySH.language.count
            + (advancedQuerySH.seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
            + advancedQuery3H.tags.count
            + (advancedQueryHP.isEmpty ? 0 : 1)
            + (advancedQueryHT.isEmpty ? 0 : 1)
    }
}

/// Persistent (in memory for the app's runtime — not UserDefaults, does not
/// need to survive a relaunch) state of external-site catalog filters — per
/// a direct request (08/30): "filters should not reset when leaving the
/// tab". Previously query/excludedCategories were plain `@State` on a
/// value-type View (ExternalSearchView/ExternalCombinedCatalogView) —
/// switching tabs Catalog → another → back recreates these views, and all
/// input/selected categories were lost.
@MainActor
final class ExternalCatalogFilterStore: ObservableObject {
    static let shared = ExternalCatalogFilterStore()

    /// Single-site view (ExternalSearchView) — keyed by ExternalSite, since
    /// different sites have different current queries/categories.
    @Published var queries: [ExternalSite: String] = [:]
    @Published var excludedCategories: [ExternalSite: Set<EHentaiCategory>] = [:]
    /// Same idea, but for ImhentaiCategory (its own, non-overlapping category
    /// scheme — see the ImhentaiCategory.bit doc-comment) — kept separate
    /// because e-hentai and imhentai can both be selected at the same time
    /// (see combinedExcludedImhentaiCategories) and each has its own set.
    @Published var excludedImhentaiCategories: [ExternalSite: Set<ImhentaiCategory>] = [:]
    /// imhentai languages (see the ImhentaiLanguage.bit doc-comment) — the
    /// same principle as excludedImhentaiCategories, a separate filter
    /// dimension over the same shared bitmask channel.
    @Published var excludedImhentaiLanguages: [ExternalSite: Set<ImhentaiLanguage>] = [:]
    /// Advanced search fields (Tags/Parodies/Artists/Characters/Groups,
    /// see ImhentaiAdvancedQuery/ImhentaiAdvancedFieldsPicker) — the same
    /// persistence principle as everything else in this file.
    @Published var imhentaiAdvancedQueries: [ExternalSite: ImhentaiAdvancedQuery] = [:]
    /// Advanced search fields for Simply Hentai (Tags/Parodies/Characters/
    /// Artists/Translators/Language/Series title, see
    /// SimplyHentaiAdvancedQuery/SimplyHentaiAdvancedFieldsPicker) — the
    /// same principle as imhentaiAdvancedQueries.
    @Published var simplyHentaiAdvancedQueries: [ExternalSite: SimplyHentaiAdvancedQuery] = [:]
    /// Advanced fields for E-Hentai (Tags/Parodies/Characters/Artists/Groups +
    /// its own search, see EHentaiAdvancedQuery/EHentaiAdvancedFieldsPicker).
    @Published var ehentaiAdvancedQueries: [ExternalSite: EHentaiAdvancedQuery] = [:]
    /// Advanced field for 3Hentai (Tags + its own search, see
    /// ThreeHentaiAdvancedQuery/ThreeHentaiAdvancedFieldsPicker).
    @Published var threeHentaiAdvancedQueries: [ExternalSite: ThreeHentaiAdvancedQuery] = [:]
    /// Selection of ONE dimension+value for HentaiPill (Tags/Parodies/
    /// Characters/Artists — the site can't combine them, see
    /// HentaiPillAdvancedQuery/HentaiPillAdvancedFieldsPicker).
    @Published var hentaiPillAdvancedQueries: [ExternalSite: HentaiPillAdvancedQuery] = [:]
    /// hitomi's own Search field (see HitomiAdvancedQuery/
    /// HitomiAdvancedFieldsPicker) — a single free-text field using the
    /// site's own female:/male:/type:/tag:/... prefix syntax directly,
    /// unlike every other site's structured chip fields.
    @Published var hitomiAdvancedQueries: [ExternalSite: HitomiAdvancedQuery] = [:]

    /// Combined "All sites" catalog (ExternalCombinedCatalogView) — its own
    /// separate state, not mixed in with the single-site ones.
    @Published var combinedQuery: String = ""
    @Published var combinedExcludedCategories: Set<EHentaiCategory> = []
    @Published var combinedExcludedImhentaiCategories: Set<ImhentaiCategory> = []
    @Published var combinedExcludedImhentaiLanguages: Set<ImhentaiLanguage> = []
    @Published var combinedImhentaiAdvancedQuery = ImhentaiAdvancedQuery()
    @Published var combinedSimplyHentaiAdvancedQuery = SimplyHentaiAdvancedQuery()
    @Published var combinedEHentaiAdvancedQuery = EHentaiAdvancedQuery()
    @Published var combinedThreeHentaiAdvancedQuery = ThreeHentaiAdvancedQuery()
    @Published var combinedHentaiPillAdvancedQuery = HentaiPillAdvancedQuery()
    @Published var combinedHitomiAdvancedQuery = HitomiAdvancedQuery()
    /// Active chip in the combined catalog's "Filters" sheet — which
    /// section is currently shown (see ExternalCombinedCatalogView.
    /// filtersSheet). nil = "All" (all sections at once, the old behavior).
    /// Persistent — the same reason as the rest of the state in this file:
    /// the sheet gets recreated on every open, the chip's position should
    /// not reset.
    @Published var combinedFiltersActiveSite: ExternalSite?

    /// Saved filter presets for the combined catalog's "Filters" sheet —
    /// see ExternalSavedFilter and ExternalCombinedCatalogView.
    /// savedFiltersSheet. One flat list for every tab (`site == nil` for
    /// "All" + one entry per site); each screen filters it down to its own
    /// tab (see savedFilters(for:)).
    @Published var savedCombinedFilters: [ExternalSavedFilter] = []

    private init() {}
}
