import Foundation

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
    /// Active chip in the combined catalog's "Filters" sheet — which
    /// section is currently shown (see ExternalCombinedCatalogView.
    /// filtersSheet). nil = "All" (all sections at once, the old behavior).
    /// Persistent — the same reason as the rest of the state in this file:
    /// the sheet gets recreated on every open, the chip's position should
    /// not reset.
    @Published var combinedFiltersActiveSite: ExternalSite?

    private init() {}
}
