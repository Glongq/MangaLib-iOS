import Foundation
import Combine

/// A user-named snapshot of the combined catalog's ENTIRE "Filters" state
/// (every site at once) — per direct feedback, saved filters are NOT
/// scoped per site/tab (an earlier version of this feature was); saving
/// from any tab captures ALL sites' current filters together, and applying
/// one restores all of them together, regardless of which tab was active
/// when you tapped either button. Created via the "Save filter" chip (see
/// ExternalCombinedCatalogView.saveCurrentFilterChip) and re-applied by
/// tapping its row (see applySavedFilter). Persisted to disk along with
/// the rest of ExternalCatalogFilterStore (see its doc-comment) — a named
/// preset disappearing on relaunch would defeat the point of "saving" it.
struct ExternalSavedFilter: Identifiable, Codable {
    let id = UUID()
    var name: String
    var excludedCategoriesEH: Set<EHentaiCategory> = []
    var excludedCategoriesIH: Set<ImhentaiCategory> = []
    var excludedLanguagesIH: Set<ImhentaiLanguage> = []
    var advancedQueryEH = EHentaiAdvancedQuery()
    var advancedQueryIH = ImhentaiAdvancedQuery()
    var advancedQuerySH = SimplyHentaiAdvancedQuery()
    var advancedQuery3H = ThreeHentaiAdvancedQuery()
    var advancedQueryHP = HentaiPillAdvancedQuery()
    var advancedQueryHT = HitomiAdvancedQuery()
    var advancedQueryPixiv = PixivAdvancedQuery()

    /// Active-filter count, for the small badge next to the name in the
    /// saved-filters list — same formula as
    /// ExternalCombinedCatalogView.excludedCategoryCount.
    var filterCount: Int {
        excludedCategoriesEH.count + excludedCategoriesIH.count + excludedLanguagesIH.count
            + advancedQueryEH.tags.count + advancedQueryEH.series.count + advancedQueryEH.characters.count + advancedQueryEH.artists.count + advancedQueryEH.groups.count
            + advancedQueryIH.tags.count + advancedQueryIH.parodies.count + advancedQueryIH.artists.count + advancedQueryIH.characters.count + advancedQueryIH.groups.count
            + advancedQuerySH.tags.count + advancedQuerySH.parodies.count + advancedQuerySH.characters.count + advancedQuerySH.artists.count + advancedQuerySH.translators.count + advancedQuerySH.language.count
            + (advancedQuerySH.seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
            + advancedQuery3H.tags.count
            + (advancedQueryHP.isEmpty ? 0 : 1)
            + (advancedQueryHT.isEmpty ? 0 : 1)
            + (advancedQueryPixiv.isEmpty ? 0 : 1)
    }
}

/// Persisted (UserDefaults, JSON-encoded — see PersistedState below) state
/// of external-site catalog filters. Originally (08/30) this only needed to
/// survive leaving/returning to the tab within one app run ("filters should
/// not reset when leaving the tab" — query/excludedCategories used to be
/// plain `@State` on a value-type View, ExternalSearchView/
/// ExternalCombinedCatalogView, and switching tabs recreates those views);
/// per later direct feedback, that wasn't enough — filters (saved presets
/// especially, see ExternalSavedFilter) should survive a full app relaunch
/// too, so this now round-trips through disk instead of living only in
/// memory for the process's lifetime.
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
    /// Pixiv's own "Search options" (Targets/Type of Work/AI filter/Sort/
    /// Posting date/Resolution, see PixivAdvancedQuery/
    /// PixivAdvancedFieldsPicker) — combines ADDITIVELY with the shared
    /// search field rather than replacing it (see PixivAdvancedQuery's
    /// doc-comment), unlike every other entry in this file.
    @Published var pixivAdvancedQueries: [ExternalSite: PixivAdvancedQuery] = [:]

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
    @Published var combinedPixivAdvancedQuery = PixivAdvancedQuery()
    /// Active chip in the combined catalog's "Filters" sheet — which
    /// section is currently shown (see ExternalCombinedCatalogView.
    /// filtersSheet). nil = "All" (all sections at once, the old behavior).
    /// Persistent — the same reason as the rest of the state in this file:
    /// the sheet gets recreated on every open, the chip's position should
    /// not reset.
    @Published var combinedFiltersActiveSite: ExternalSite?

    /// Saved filter presets for the combined catalog's "Filters" sheet —
    /// see ExternalSavedFilter (NOT scoped per site/tab, per direct
    /// feedback) and ExternalCombinedCatalogView.savedFiltersSheet.
    @Published var savedCombinedFilters: [ExternalSavedFilter] = []

    /// Everything above, mirrored field-for-field — the actual on-disk
    /// shape (see load()/save()). A separate Codable struct rather than
    /// making the class itself Codable: `ObservableObject`/`@Published`
    /// don't play well with synthesized Codable, and this keeps the
    /// persisted shape decoupled from the live property wrappers.
    private struct PersistedState: Codable {
        var queries: [ExternalSite: String] = [:]
        var excludedCategories: [ExternalSite: Set<EHentaiCategory>] = [:]
        var excludedImhentaiCategories: [ExternalSite: Set<ImhentaiCategory>] = [:]
        var excludedImhentaiLanguages: [ExternalSite: Set<ImhentaiLanguage>] = [:]
        var imhentaiAdvancedQueries: [ExternalSite: ImhentaiAdvancedQuery] = [:]
        var simplyHentaiAdvancedQueries: [ExternalSite: SimplyHentaiAdvancedQuery] = [:]
        var ehentaiAdvancedQueries: [ExternalSite: EHentaiAdvancedQuery] = [:]
        var threeHentaiAdvancedQueries: [ExternalSite: ThreeHentaiAdvancedQuery] = [:]
        var hentaiPillAdvancedQueries: [ExternalSite: HentaiPillAdvancedQuery] = [:]
        var hitomiAdvancedQueries: [ExternalSite: HitomiAdvancedQuery] = [:]
        var pixivAdvancedQueries: [ExternalSite: PixivAdvancedQuery] = [:]

        var combinedQuery: String = ""
        var combinedExcludedCategories: Set<EHentaiCategory> = []
        var combinedExcludedImhentaiCategories: Set<ImhentaiCategory> = []
        var combinedExcludedImhentaiLanguages: Set<ImhentaiLanguage> = []
        var combinedImhentaiAdvancedQuery = ImhentaiAdvancedQuery()
        var combinedSimplyHentaiAdvancedQuery = SimplyHentaiAdvancedQuery()
        var combinedEHentaiAdvancedQuery = EHentaiAdvancedQuery()
        var combinedThreeHentaiAdvancedQuery = ThreeHentaiAdvancedQuery()
        var combinedHentaiPillAdvancedQuery = HentaiPillAdvancedQuery()
        var combinedHitomiAdvancedQuery = HitomiAdvancedQuery()
        var combinedPixivAdvancedQuery = PixivAdvancedQuery()
        var combinedFiltersActiveSite: ExternalSite?

        var savedCombinedFilters: [ExternalSavedFilter] = []
    }

    /// Versioned key (not just "external_catalog_filters") — if this
    /// shape ever needs a breaking change, bumping the suffix leaves old
    /// installs decoding cleanly to defaults instead of crashing/silently
    /// dropping fields on a JSONDecoder failure.
    private static let storageKey = "external_catalog_filter_store_v1"
    private let defaults = UserDefaults.standard
    /// Keeps the objectWillChange subscription below alive for the
    /// lifetime of this singleton.
    private var saveSubscription: AnyCancellable?

    private init() {
        load()
        // Autosave — ANY change to ANY @Published property above funnels
        // through objectWillChange, so one subscription here covers all
        // of them instead of a save() call at every individual mutation
        // site (dozens, across ExternalSearchView/
        // ExternalCombinedCatalogView/PixivAdvancedFieldsPicker/...).
        // objectWillChange fires BEFORE the value is actually updated, so
        // save() is dispatched to the next main-thread runloop turn,
        // where the mutation has already landed.
        saveSubscription = objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.save() }
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        queries = state.queries
        excludedCategories = state.excludedCategories
        excludedImhentaiCategories = state.excludedImhentaiCategories
        excludedImhentaiLanguages = state.excludedImhentaiLanguages
        imhentaiAdvancedQueries = state.imhentaiAdvancedQueries
        simplyHentaiAdvancedQueries = state.simplyHentaiAdvancedQueries
        ehentaiAdvancedQueries = state.ehentaiAdvancedQueries
        threeHentaiAdvancedQueries = state.threeHentaiAdvancedQueries
        hentaiPillAdvancedQueries = state.hentaiPillAdvancedQueries
        hitomiAdvancedQueries = state.hitomiAdvancedQueries
        pixivAdvancedQueries = state.pixivAdvancedQueries
        combinedQuery = state.combinedQuery
        combinedExcludedCategories = state.combinedExcludedCategories
        combinedExcludedImhentaiCategories = state.combinedExcludedImhentaiCategories
        combinedExcludedImhentaiLanguages = state.combinedExcludedImhentaiLanguages
        combinedImhentaiAdvancedQuery = state.combinedImhentaiAdvancedQuery
        combinedSimplyHentaiAdvancedQuery = state.combinedSimplyHentaiAdvancedQuery
        combinedEHentaiAdvancedQuery = state.combinedEHentaiAdvancedQuery
        combinedThreeHentaiAdvancedQuery = state.combinedThreeHentaiAdvancedQuery
        combinedHentaiPillAdvancedQuery = state.combinedHentaiPillAdvancedQuery
        combinedHitomiAdvancedQuery = state.combinedHitomiAdvancedQuery
        combinedPixivAdvancedQuery = state.combinedPixivAdvancedQuery
        combinedFiltersActiveSite = state.combinedFiltersActiveSite
        savedCombinedFilters = state.savedCombinedFilters
    }

    private func save() {
        let state = PersistedState(
            queries: queries,
            excludedCategories: excludedCategories,
            excludedImhentaiCategories: excludedImhentaiCategories,
            excludedImhentaiLanguages: excludedImhentaiLanguages,
            imhentaiAdvancedQueries: imhentaiAdvancedQueries,
            simplyHentaiAdvancedQueries: simplyHentaiAdvancedQueries,
            ehentaiAdvancedQueries: ehentaiAdvancedQueries,
            threeHentaiAdvancedQueries: threeHentaiAdvancedQueries,
            hentaiPillAdvancedQueries: hentaiPillAdvancedQueries,
            hitomiAdvancedQueries: hitomiAdvancedQueries,
            pixivAdvancedQueries: pixivAdvancedQueries,
            combinedQuery: combinedQuery,
            combinedExcludedCategories: combinedExcludedCategories,
            combinedExcludedImhentaiCategories: combinedExcludedImhentaiCategories,
            combinedExcludedImhentaiLanguages: combinedExcludedImhentaiLanguages,
            combinedImhentaiAdvancedQuery: combinedImhentaiAdvancedQuery,
            combinedSimplyHentaiAdvancedQuery: combinedSimplyHentaiAdvancedQuery,
            combinedEHentaiAdvancedQuery: combinedEHentaiAdvancedQuery,
            combinedThreeHentaiAdvancedQuery: combinedThreeHentaiAdvancedQuery,
            combinedHentaiPillAdvancedQuery: combinedHentaiPillAdvancedQuery,
            combinedHitomiAdvancedQuery: combinedHitomiAdvancedQuery,
            combinedPixivAdvancedQuery: combinedPixivAdvancedQuery,
            combinedFiltersActiveSite: combinedFiltersActiveSite,
            savedCombinedFilters: savedCombinedFilters
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
