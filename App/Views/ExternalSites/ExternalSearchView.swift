import SwiftUI

/// Catalog screen for external sites with free-text search instead of
/// an alphabetical index (capabilities.hasSearch && !hasTagBrowser — see
/// EHentaiProvider; hitomi is the opposite case, see ExternalTagBrowserView).
///
/// Visually — COMPLETELY 1-to-1 with MangaCatalogView (per a direct
/// request on 08/30): the "Каталог" title is large .large (not
/// "Поиск"/.inline as it used to be), the native `.searchable()` instead
/// of a hand-rolled TextField+HStack box (the same trick as in
/// MangaCatalogView itself — not a separate field position, but the
/// system search bar under the nav bar), "Фильтры" is a glass pill in
/// the shared bottom bar (see ExternalCatalogGridView.controlsBar, passed
/// in via leadingControls) instead of categories always sticking out on
/// screen. No separate navigation: titles appear right below the field
/// (see ExternalCatalogGridView(embedded: true)), with a short delay
/// after the last keypress (debounce).
struct ExternalSearchView: View {
    let site: ExternalSite

    @ObservedObject private var filterStore = ExternalCatalogFilterStore.shared
    @State private var query = ""
    /// The query that is actually being searched right now — kept
    /// separate from `query` (what's currently typed in the field) so we
    /// don't hit the network on EVERY keypress (see .task(id: query)
    /// below — debounce).
    @State private var committedQuery = ""
    @State private var showFilters = false

    private var capabilities: ExternalSiteCapabilities { ExternalSiteRegistry.provider(for: site).capabilities }
    /// Two DIFFERENT category sets (e-hentai — EHentaiCategory, imhentai —
    /// ImhentaiCategory, each site has its own values/count, see
    /// ImhentaiProvider.swift) — stored separately in
    /// ExternalCatalogFilterStore, switched on `site` (see
    /// excludedCategoryBits/filtersSheet below). hitomi/3hentai never
    /// reach this at all — hasCategoryFilter is false for them, so
    /// filtersButton is not shown.
    private var excludedCategoriesEH: Set<EHentaiCategory> {
        get { filterStore.excludedCategories[site] ?? [] }
        nonmutating set { filterStore.excludedCategories[site] = newValue }
    }
    private var excludedCategoriesIH: Set<ImhentaiCategory> {
        get { filterStore.excludedImhentaiCategories[site] ?? [] }
        nonmutating set { filterStore.excludedImhentaiCategories[site] = newValue }
    }
    /// imhentai languages (see ImhentaiLanguage.bit doc-comment) — a
    /// separate filter dimension, using the same shared bitmask channel
    /// as categories.
    private var excludedLanguagesIH: Set<ImhentaiLanguage> {
        get { filterStore.excludedImhentaiLanguages[site] ?? [] }
        nonmutating set { filterStore.excludedImhentaiLanguages[site] = newValue }
    }
    private var excludedCategoryBits: Int {
        switch site {
        case .ehentai: return excludedCategoriesEH.reduce(0) { $0 | $1.bit }
        case .imhentai:
            return excludedCategoriesIH.reduce(0) { $0 | $1.bit } | excludedLanguagesIH.reduce(0) { $0 | $1.bit }
        default: return 0
        }
    }
    /// Advanced fields (Tags/Parodies/Artists/Characters/Groups, see
    /// ImhentaiAdvancedQuery) — imhentai only, only inside "Фильтры".
    private var advancedQueryIH: ImhentaiAdvancedQuery {
        get { filterStore.imhentaiAdvancedQueries[site] ?? ImhentaiAdvancedQuery() }
        nonmutating set { filterStore.imhentaiAdvancedQueries[site] = newValue }
    }
    /// Simply Hentai advanced fields (Поиск/Tags/Parodies/Characters/
    /// Artists/Translators/Language/Series title, see
    /// SimplyHentaiAdvancedQuery) — EXCLUSIVE with respect to the shared
    /// committedQuery (see the resolvedQuery doc-comment: one rule
    /// applies to all sites with advanced fields, except
    /// imhentai/hentaiPill).
    private var advancedQuerySH: SimplyHentaiAdvancedQuery {
        get { filterStore.simplyHentaiAdvancedQueries[site] ?? SimplyHentaiAdvancedQuery() }
        nonmutating set { filterStore.simplyHentaiAdvancedQueries[site] = newValue }
    }
    /// E-Hentai advanced fields (Поиск/Tags/Parodies/Characters/Artists/
    /// Groups, see EHentaiAdvancedQuery) — work TOGETHER with the
    /// bitmask categories (excludedCategoriesEH, a separate channel), but
    /// are exclusive with respect to committedQuery.
    private var advancedQueryEH: EHentaiAdvancedQuery {
        get { filterStore.ehentaiAdvancedQueries[site] ?? EHentaiAdvancedQuery() }
        nonmutating set { filterStore.ehentaiAdvancedQueries[site] = newValue }
    }
    /// 3Hentai advanced fields (Поиск/Tags, see ThreeHentaiAdvancedQuery).
    private var advancedQuery3H: ThreeHentaiAdvancedQuery {
        get { filterStore.threeHentaiAdvancedQueries[site] ?? ThreeHentaiAdvancedQuery() }
        nonmutating set { filterStore.threeHentaiAdvancedQueries[site] = newValue }
    }
    /// A single dimension + value for HentaiPill (see
    /// HentaiPillAdvancedQuery — this site never combines dimensions with
    /// each other and never combines with the shared text search under
    /// any condition, see resolvedQuery).
    private var advancedQueryHP: HentaiPillAdvancedQuery {
        get { filterStore.hentaiPillAdvancedQueries[site] ?? HentaiPillAdvancedQuery() }
        nonmutating set { filterStore.hentaiPillAdvancedQueries[site] = newValue }
    }
    private var excludedCategoryCount: Int {
        switch site {
        case .ehentai:
            let advanced = advancedQueryEH
            return excludedCategoriesEH.count + advanced.tags.count + advanced.series.count
                + advanced.characters.count + advanced.artists.count + advanced.groups.count
        case .imhentai:
            let advanced = advancedQueryIH
            return excludedCategoriesIH.count + excludedLanguagesIH.count
                + advanced.tags.count + advanced.parodies.count + advanced.artists.count + advanced.characters.count + advanced.groups.count
        case .simplyHentai:
            let advanced = advancedQuerySH
            return advanced.tags.count + advanced.parodies.count + advanced.characters.count
                + advanced.artists.count + advanced.translators.count + advanced.language.count
                + (advanced.seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
        case .threeHentai:
            return advancedQuery3H.tags.count
        case .hentaiPill:
            return advancedQueryHP.isEmpty ? 0 : 1
        default: return 0
        }
    }
    /// The final query that actually goes to ExternalCatalogGridView.
    ///
    /// The rule is EXCLUSIVE (per a direct request on 09/01): if a site
    /// has even one advanced field filled in ("Фильтры"), the shared top
    /// `.searchable()` field (committedQuery) stops applying to that site
    /// entirely — search is done strictly on what's typed into the
    /// advanced fields themselves. If the advanced fields are empty —
    /// same as before, plain committedQuery.
    ///
    /// imhentai is a special case of this same rule: its own field
    /// (advancedQueryIH.searchText) replaces committedQuery
    /// UNCONDITIONALLY (committedQuery isn't even shown for it, see
    /// body), hence the separate branch, same as before.
    ///
    /// hentaiPill is also a special case: this site can't combine
    /// dimensions, so when advancedQueryHP is non-empty the query is not
    /// `.search(...)` but `.tag(namespace:value:)` directly; when empty —
    /// plain `.search(committedQuery, ...)`, like everyone else.
    private var resolvedQuery: ExternalCatalogQuery {
        if site == .imhentai {
            let advanced = advancedQueryIH
            var parts: [String] = []
            let trimmedSearch = advanced.searchText.trimmingCharacters(in: .whitespaces)
            if !trimmedSearch.isEmpty { parts.append(trimmedSearch) }
            parts.append(contentsOf: advanced.clauses())
            return .search(query: parts.joined(separator: " "), excludedCategoryBits: excludedCategoryBits)
        }
        if site == .hentaiPill {
            let advanced = advancedQueryHP
            if !advanced.isEmpty {
                return .tag(namespace: advanced.kind, value: advanced.value.trimmingCharacters(in: .whitespaces))
            }
            return .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits)
        }
        if site == .simplyHentai {
            let advanced = advancedQuerySH
            let text = advanced.isEmpty ? committedQuery : advanced.encoded()
            return .search(query: text, excludedCategoryBits: excludedCategoryBits)
        }
        if site == .ehentai {
            let advanced = advancedQueryEH
            let text = advanced.isEmpty ? committedQuery : advanced.encoded()
            return .search(query: text, excludedCategoryBits: excludedCategoryBits)
        }
        if site == .threeHentai {
            let advanced = advancedQuery3H
            let text = advanced.isEmpty ? committedQuery : advanced.encoded()
            return .search(query: text, excludedCategoryBits: excludedCategoryBits)
        }
        return .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits)
    }
    /// The string portion of resolvedQuery — used only for `.id(...)`
    /// (forced @State reset of the grid, see content) and displayTitle;
    /// the network call gets resolvedQuery in full (including
    /// hentaiPill's .tag case).
    private var resolvedQueryIdentity: String {
        switch resolvedQuery {
        case .tag(let namespace, let value): return "tag:\(namespace)/\(value)"
        case .search(let query, _): return query
        }
    }

    /// The title above the results feed — for sites with active advanced
    /// fields it reflects THEM (the shared committedQuery no longer
    /// affects anything for that site, see resolvedQuery).
    private var displayTitle: String {
        if site == .imhentai {
            let text = advancedQueryIH.searchText.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "Recently" : text
        }
        if site == .hentaiPill, !advancedQueryHP.isEmpty {
            return advancedQueryHP.value.trimmingCharacters(in: .whitespaces)
        }
        if site == .simplyHentai, !advancedQuerySH.isEmpty {
            let text = advancedQuerySH.search.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "Recently" : text
        }
        if site == .ehentai, !advancedQueryEH.isEmpty {
            let text = advancedQueryEH.search.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "Recently" : text
        }
        if site == .threeHentai, !advancedQuery3H.isEmpty {
            let text = advancedQuery3H.search.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "Recently" : text
        }
        return committedQuery.isEmpty ? "Recently" : committedQuery
    }

    var body: some View {
        // The shared top .searchable() — only for sites that actually
        // listen to it (see resolvedQuery); for imhentai it would just do
        // nothing (search into the void), confusing the user with the
        // exact same bug that got it removed in the first place — so for
        // imhentai we don't show it at all, and instead there's its own
        // field inside "Фильтры" (ImhentaiAdvancedFieldsPicker).
        if site == .imhentai {
            content
        } else {
            content.searchable(text: $query, prompt: "Название, тег, автор…")
        }
    }

    private var content: some View {
        // An empty query is not "Enter a query" but a "Recently" feed
        // (see HitomiProvider/EHentaiProvider.fetchIdsBySearch with an
        // empty query) — titles are visible right away, with no need to
        // type anything first.
        // .id — forces a NEW view instance on every change to the
        // query/categories, so the grid's @State (items/cursors/...) gets
        // reset and .task restarts loading — simply changing the
        // `query:` parameter doesn't do this, SwiftUI treats it as the
        // SAME view at the same place in the tree.
        ExternalCatalogGridView(
            site: site,
            query: resolvedQuery,
            title: displayTitle,
            embedded: true,
            leadingControls: capabilities.hasCategoryFilter ? AnyView(filtersButton) : nil
        )
        .id("\(resolvedQueryIdentity)#\(excludedCategoryBits)")
        .navigationTitle("Каталог")
        .navigationBarTitleDisplayMode(.large)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showFilters) {
            filtersSheet
        }
        .onAppear {
            // Restore what was actually typed/selected last time (see
            // ExternalCatalogFilterStore) — the screen is recreated when
            // leaving/returning to the Catalog tab, and query/committedQuery
            // as plain @State would otherwise reset every time. For
            // imhentai this doesn't affect anything anyway (no
            // .searchable()), but it's harmless to leave it as-is —
            // simpler than adding a branch for it.
            query = filterStore.queries[site] ?? ""
            committedQuery = query
        }
        .task(id: query) {
            // Debounce — 400ms of silence after the last keypress,
            // otherwise every letter would trigger a separate network
            // request. .task(id:) itself cancels the previous attempt
            // when query changes again before these 400ms have elapsed.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            committedQuery = query.trimmingCharacters(in: .whitespaces)
            filterStore.queries[site] = committedQuery
        }
    }

    // MARK: Filters — a glass pill (see ExternalCatalogGridView.
    // controlPill); a tap opens a sheet with toggles (EHentaiCategoryPicker).

    private var filtersButton: some View {
        Button {
            showFilters = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.footnote.weight(.semibold))
                Text("Фильтры").font(.footnote.weight(.medium)).lineLimit(1)
                if excludedCategoryCount > 0 {
                    Text("\(excludedCategoryCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.background)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Circle())
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.pillControlHeight)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

    private var filtersSheet: some View {
        NavigationStack {
            ScrollView {
                categoryPicker
                    .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Сбросить") { resetFilters() }
                        .disabled(excludedCategoryCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showFilters = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    /// Resets the filters for the CURRENT site (this screen is always
    /// about a single site, unlike ExternalCombinedCatalogView — there
    /// reset is scoped to the active chip tab).
    private func resetFilters() {
        switch site {
        case .ehentai:
            excludedCategoriesEH = []
            advancedQueryEH = EHentaiAdvancedQuery()
        case .imhentai:
            excludedCategoriesIH = []
            excludedLanguagesIH = []
            advancedQueryIH = ImhentaiAdvancedQuery()
        case .simplyHentai:
            advancedQuerySH = SimplyHentaiAdvancedQuery()
        case .threeHentai:
            advancedQuery3H = ThreeHentaiAdvancedQuery()
        case .hentaiPill:
            advancedQueryHP = HentaiPillAdvancedQuery()
        case .hitomi:
            break
        }
    }

    @ViewBuilder
    private var categoryPicker: some View {
        switch site {
        case .ehentai:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Категории").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    EHentaiCategoryPicker(excluded: Binding(
                        get: { excludedCategoriesEH },
                        set: { excludedCategoriesEH = $0 }
                    ))
                }
                EHentaiAdvancedFieldsPicker(query: Binding(
                    get: { advancedQueryEH },
                    set: { advancedQueryEH = $0 }
                ))
            }
        case .imhentai:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Категории").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ImhentaiCategoryPicker(excluded: Binding(
                        get: { excludedCategoriesIH },
                        set: { excludedCategoriesIH = $0 }
                    ))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Языки").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ImhentaiLanguagePicker(excluded: Binding(
                        get: { excludedLanguagesIH },
                        set: { excludedLanguagesIH = $0 }
                    ))
                }
                ImhentaiAdvancedFieldsPicker(query: Binding(
                    get: { advancedQueryIH },
                    set: { advancedQueryIH = $0 }
                ))
            }
        case .simplyHentai:
            SimplyHentaiAdvancedFieldsPicker(query: Binding(
                get: { advancedQuerySH },
                set: { advancedQuerySH = $0 }
            ))
        case .threeHentai:
            ThreeHentaiAdvancedFieldsPicker(query: Binding(
                get: { advancedQuery3H },
                set: { advancedQuery3H = $0 }
            ))
        case .hentaiPill:
            HentaiPillAdvancedFieldsPicker(query: Binding(
                get: { advancedQueryHP },
                set: { advancedQueryHP = $0 }
            ))
        case .hitomi:
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        ExternalSearchView(site: .ehentai)
    }
    .preferredColorScheme(.dark)
}
