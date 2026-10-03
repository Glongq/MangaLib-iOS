import SwiftUI

/// Combined catalog/result set — "All sites" (see ExternalSiteSession.
/// combinedModeActive, chosen in the site switcher — SideMenuView.
/// siteRow). One query is sent to ALL enabled sites AT ONCE
/// (ExternalSiteSession.enabledSites), the results are merged into one grid
/// (see ExternalCatalogGridView, support for multiple `sites`) — each
/// title's card is labeled with its source (ExternalCatalogGridView.
/// showsSourceBadge / ExternalGalleryDetailView "Source").
///
/// Visually — the same 1:1 port of MangaCatalogView as ExternalSearchView
/// (see its doc-comment): "Catalog" in large .large title style, the native
/// `.searchable()`, "Filters" as a glass pill in the shared bottom panel
/// (shown if AT LEAST ONE of the enabled sites supports
/// capabilities.hasCategoryFilter — the rest simply and honestly ignore the
/// bitmask in the result set, see
/// ExternalSiteProvider.fetchIdsBySearch(excludedCategoryBits:)). Titles —
/// no separate navigation, appear right under the field (debounced, see
/// .task(id:)), and the state (query/categories) survives leaving/returning
/// to the tab (see
/// ExternalCatalogFilterStore.combinedQuery/combinedExcludedCategories).
struct ExternalCombinedCatalogView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @ObservedObject private var filterStore = ExternalCatalogFilterStore.shared
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var showFilters = false

    private var sites: [ExternalSite] { ExternalSite.allCases.filter { session.enabledSites.contains($0) } }
    /// Unlike ExternalSearchView (there it's always EXACTLY one site — you
    /// can switch on `site`), here several sites can be enabled at once —
    /// so BOTH category sets (e-hentai/imhentai) are summed, not selected
    /// by one active site.
    private var showsEHentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .ehentai } }
    private var showsImhentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .imhentai } }
    /// Also works when exactly ONE simplyHentai is enabled — `sites`
    /// contains just it, `.contains` is true, the filter is shown (per
    /// direct feedback: "if 1 site is selected, that filtering should also
    /// be there").
    private var showsSimplyHentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .simplyHentai } }
    private var showsThreeHentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .threeHentai } }
    private var showsHentaiPillFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .hentaiPill } }
    private var showsHitomiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .hitomi } }
    private var showsCategoryFilter: Bool {
        showsEHentaiFilter || showsImhentaiFilter || showsSimplyHentaiFilter || showsThreeHentaiFilter || showsHentaiPillFilter || showsHitomiFilter
    }
    /// Sites that currently have something to show in the "Filters" tab —
    /// the source of the switcher chips (see filtersSheet).
    private var filterableSites: [ExternalSite] {
        sites.filter { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter }
    }
    private var excludedCategoriesEH: Set<EHentaiCategory> {
        get { filterStore.combinedExcludedCategories }
        nonmutating set { filterStore.combinedExcludedCategories = newValue }
    }
    private var excludedCategoriesIH: Set<ImhentaiCategory> {
        get { filterStore.combinedExcludedImhentaiCategories }
        nonmutating set { filterStore.combinedExcludedImhentaiCategories = newValue }
    }
    private var excludedLanguagesIH: Set<ImhentaiLanguage> {
        get { filterStore.combinedExcludedImhentaiLanguages }
        nonmutating set { filterStore.combinedExcludedImhentaiLanguages = newValue }
    }
    private var advancedQueryIH: ImhentaiAdvancedQuery {
        get { filterStore.combinedImhentaiAdvancedQuery }
        nonmutating set { filterStore.combinedImhentaiAdvancedQuery = newValue }
    }
    private var advancedQuerySH: SimplyHentaiAdvancedQuery {
        get { filterStore.combinedSimplyHentaiAdvancedQuery }
        nonmutating set { filterStore.combinedSimplyHentaiAdvancedQuery = newValue }
    }
    private var advancedQueryEH: EHentaiAdvancedQuery {
        get { filterStore.combinedEHentaiAdvancedQuery }
        nonmutating set { filterStore.combinedEHentaiAdvancedQuery = newValue }
    }
    private var advancedQuery3H: ThreeHentaiAdvancedQuery {
        get { filterStore.combinedThreeHentaiAdvancedQuery }
        nonmutating set { filterStore.combinedThreeHentaiAdvancedQuery = newValue }
    }
    private var advancedQueryHP: HentaiPillAdvancedQuery {
        get { filterStore.combinedHentaiPillAdvancedQuery }
        nonmutating set { filterStore.combinedHentaiPillAdvancedQuery = newValue }
    }
    private var advancedQueryHT: HitomiAdvancedQuery {
        get { filterStore.combinedHitomiAdvancedQuery }
        nonmutating set { filterStore.combinedHitomiAdvancedQuery = newValue }
    }
    /// The active chip tab in "Filters" — nil means "All" (all sections
    /// stacked, as before). See filtersSheet.
    private var activeFiltersSite: ExternalSite? {
        get { filterStore.combinedFiltersActiveSite }
        nonmutating set { filterStore.combinedFiltersActiveSite = newValue }
    }
    private var excludedCategoryBits: Int {
        excludedCategoriesEH.reduce(0) { $0 | $1.bit }
            | excludedCategoriesIH.reduce(0) { $0 | $1.bit }
            | excludedLanguagesIH.reduce(0) { $0 | $1.bit }
    }
    private var excludedCategoryCount: Int {
        let advanced = advancedQueryIH
        let sh = advancedQuerySH
        let eh = advancedQueryEH
        let th = advancedQuery3H
        return excludedCategoriesEH.count + excludedCategoriesIH.count + excludedLanguagesIH.count
            + advanced.tags.count + advanced.parodies.count + advanced.artists.count + advanced.characters.count + advanced.groups.count
            + sh.tags.count + sh.parodies.count + sh.characters.count + sh.artists.count + sh.translators.count + sh.language.count
            + (sh.seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
            + eh.tags.count + eh.series.count + eh.characters.count + eh.artists.count + eh.groups.count
            + th.tags.count
            + (advancedQueryHP.isEmpty ? 0 : 1)
            + (advancedQueryHT.isEmpty ? 0 : 1)
    }
    /// Active filter count for ONE site — used only by the switcher chips
    /// (see filtersSheet), to show a per-section badge instead of the
    /// overall total.
    private func excludedCategoryCount(for site: ExternalSite) -> Int {
        switch site {
        case .ehentai:
            let eh = advancedQueryEH
            return excludedCategoriesEH.count + eh.tags.count + eh.series.count + eh.characters.count + eh.artists.count + eh.groups.count
        case .imhentai:
            let advanced = advancedQueryIH
            return excludedCategoriesIH.count + excludedLanguagesIH.count
                + advanced.tags.count + advanced.parodies.count + advanced.artists.count + advanced.characters.count + advanced.groups.count
        case .simplyHentai:
            let sh = advancedQuerySH
            return sh.tags.count + sh.parodies.count + sh.characters.count + sh.artists.count + sh.translators.count + sh.language.count
                + (sh.seriesTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
        case .threeHentai:
            return advancedQuery3H.tags.count
        case .hentaiPill:
            return advancedQueryHP.isEmpty ? 0 : 1
        case .hitomi:
            return advancedQueryHT.isEmpty ? 0 : 1
        }
    }
    /// A separate query PER SITE — per direct feedback (Aug 31): imhentai
    /// must not see the shared search field at all (same reason as in
    /// ExternalSearchView.resolvedQuery — `/search/`/`/advsearch/` are two
    /// different parsers for one `key=`, plain text reliably finds
    /// nothing), and the other sites must not see tags/search typed into
    /// imhentai's "Filters". There used to be ONE shared composedQuery for
    /// the whole ExternalCatalogGridView — it leaked into ALL enabled
    /// sites at once (ExternalCatalogGridView.fetchPage used the same
    /// query for every site), now each site has its own independent query
    /// (see ExternalCatalogGridView.queryForSite).
    private func query(for site: ExternalSite) -> ExternalCatalogQuery {
        if site == .imhentai {
            let advanced = advancedQueryIH
            var parts: [String] = []
            let trimmedSearch = advanced.searchText.trimmingCharacters(in: .whitespaces)
            if !trimmedSearch.isEmpty { parts.append(trimmedSearch) }
            parts.append(contentsOf: advanced.clauses())
            return .search(query: parts.joined(separator: " "), excludedCategoryBits: excludedCategoryBits)
        }
        // HentaiPill can't combine dimensions with each other or with free
        // text (see ExternalSearchView.resolvedQuery) — when advancedQueryHP
        // isn't empty this is a separate `.tag(...)`, not `.search(...)`.
        if site == .hentaiPill {
            let advanced = advancedQueryHP
            if !advanced.isEmpty {
                return .tag(namespace: advanced.kind, value: advanced.value.trimmingCharacters(in: .whitespaces))
            }
            return .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits)
        }
        // The EXCLUSIVITY rule (see ExternalSearchView.resolvedQuery, same
        // principle): if a site has at least one advanced field filled in,
        // the shared committedQuery no longer applies to THAT site.
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
        if site == .hitomi {
            let advanced = advancedQueryHT
            let text = advanced.isEmpty ? committedQuery : advanced.encoded()
            return .search(query: text, excludedCategoryBits: excludedCategoryBits)
        }
        return .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits)
    }
    /// A string "fingerprint" of each site's query — only for `.id(...)`
    /// (see body), the actual network call gets query(for:) in full
    /// (including hentaiPill's `.tag`).
    private func queryIdentity(for site: ExternalSite) -> String {
        switch query(for: site) {
        case .tag(let namespace, let value): return "tag:\(namespace)/\(value)"
        case .search(let text, _): return text
        }
    }

    var body: some View {
        // Empty query — the "Recently" feed right away across all enabled
        // sites (see ExternalSearchView — same principle), no need to
        // type something first.
        ExternalCatalogGridView(
            sites: sites,
            queryForSite: query(for:),
            title: committedQuery.isEmpty ? "Recently" : committedQuery,
            embedded: true,
            leadingControls: showsCategoryFilter ? AnyView(filtersButton) : nil
        )
        // .id — the same trick as ExternalSearchView: force a new view
        // instance on any change to any of the independent queries (shared
        // OR imhentai-specific), so the grid's @State resets and .task
        // reloads from scratch.
        .id("\(committedQuery)#\(sites.map { queryIdentity(for: $0) }.joined(separator: "|"))#\(excludedCategoryBits)")
        .navigationTitle("Каталог")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Название, тег, автор…")
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showFilters) {
            filtersSheet
        }
        .onAppear {
            query = filterStore.combinedQuery
            committedQuery = query
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            committedQuery = query.trimmingCharacters(in: .whitespaces)
            filterStore.combinedQuery = committedQuery
        }
    }

    // MARK: Filters — see ExternalSearchView.filtersButton (same style,
    // copied line-for-line — separate views, no shared component just for
    // one pill).

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

    /// The "Filters" sheet — a chip switcher pinned to the BOTTOM of the
    /// sheet, floating over the scrolled content (per direct feedback
    /// 01.09 — the row used to sit at the top, cramped between the nav bar
    /// and the content, where its buttons also tapped unreliably; moved to
    /// a `.safeAreaInset(edge: .bottom)`, the same proven bottom-glass-pill
    /// pattern already used by ExternalCatalogGridView.controlsBar, and
    /// each chip now gets an explicit `.contentShape(Capsule())` so its
    /// whole capsule — not just the glyph bounds — is a reliable tap
    /// target): "All" (all enabled sites' sections stacked, as before) +
    /// one chip per enabled site with filters (shows ONLY that site's
    /// section). The active tab lives in filterStore — it survives
    /// closing/reopening the sheet (see combinedFiltersActiveSite).
    private var filtersSheet: some View {
        NavigationStack {
            ScrollView {
                filterSectionsContent
                    .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Сбросить") { resetFilters() }
                        .disabled(resetDisabled)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showFilters = false }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                filterSiteChips
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filterSiteChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                filterChip(title: "Все", count: excludedCategoryCount, isActive: activeFiltersSite == nil) {
                    activeFiltersSite = nil
                }
                ForEach(filterableSites, id: \.self) { site in
                    filterChip(title: site.displayName, count: excludedCategoryCount(for: site), isActive: activeFiltersSite == site) {
                        activeFiltersSite = site
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    /// Same glass-pill treatment as filtersButton/ExternalCatalogGridView.
    /// controlPill (proven to tap reliably elsewhere in the app) instead of
    /// a plain flat-color capsule — plus an explicit `.contentShape(Capsule())`
    /// so the button's hit area is always the full visible pill, never just
    /// the label glyphs.
    private func filterChip(title: String, count: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.footnote.weight(.medium)).lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isActive ? Theme.background : Theme.accent)
                }
            }
            .foregroundStyle(isActive ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.pillControlHeight)
            .background {
                if isActive { Capsule().fill(Theme.accent) }
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var filterSectionsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let site = activeFiltersSite {
                filterSection(for: site)
            } else {
                if showsEHentaiFilter { filterSection(for: .ehentai) }
                if showsImhentaiFilter { filterSection(for: .imhentai) }
                if showsSimplyHentaiFilter { filterSection(for: .simplyHentai) }
                if showsThreeHentaiFilter { filterSection(for: .threeHentai) }
                if showsHentaiPillFilter { filterSection(for: .hentaiPill) }
                if showsHitomiFilter { filterSection(for: .hitomi) }
            }
        }
    }

    @ViewBuilder
    private func filterSection(for site: ExternalSite) -> some View {
        switch site {
        case .ehentai:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("E-Hentai — категории").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    EHentaiCategoryPicker(excluded: Binding(
                        get: { excludedCategoriesEH },
                        set: { excludedCategoriesEH = $0 }
                    ))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("E-Hentai — расширенный поиск").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    EHentaiAdvancedFieldsPicker(query: Binding(
                        get: { advancedQueryEH },
                        set: { advancedQueryEH = $0 }
                    ))
                }
            }
        case .imhentai:
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("IMHentai — категории").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ImhentaiCategoryPicker(excluded: Binding(
                        get: { excludedCategoriesIH },
                        set: { excludedCategoriesIH = $0 }
                    ))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("IMHentai — языки").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ImhentaiLanguagePicker(excluded: Binding(
                        get: { excludedLanguagesIH },
                        set: { excludedLanguagesIH = $0 }
                    ))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("IMHentai — расширенный поиск").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ImhentaiAdvancedFieldsPicker(query: Binding(
                        get: { advancedQueryIH },
                        set: { advancedQueryIH = $0 }
                    ))
                }
            }
        case .simplyHentai:
            VStack(alignment: .leading, spacing: 8) {
                Text("Simply Hentai").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                SimplyHentaiAdvancedFieldsPicker(query: Binding(
                    get: { advancedQuerySH },
                    set: { advancedQuerySH = $0 }
                ))
            }
        case .threeHentai:
            VStack(alignment: .leading, spacing: 8) {
                Text("3Hentai").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                ThreeHentaiAdvancedFieldsPicker(query: Binding(
                    get: { advancedQuery3H },
                    set: { advancedQuery3H = $0 }
                ))
            }
        case .hentaiPill:
            VStack(alignment: .leading, spacing: 8) {
                Text("HentaiPill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                HentaiPillAdvancedFieldsPicker(query: Binding(
                    get: { advancedQueryHP },
                    set: { advancedQueryHP = $0 }
                ))
            }
        case .hitomi:
            VStack(alignment: .leading, spacing: 8) {
                Text("hitomi.la").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                HitomiAdvancedFieldsPicker(query: Binding(
                    get: { advancedQueryHT },
                    set: { advancedQueryHT = $0 }
                ))
            }
        }
    }

    /// Reset — only the CURRENT section (active chip's tab); on the "All"
    /// tab it clears every site's filters at once (per direct feedback —
    /// "resets the specific section", and "All" is itself a section, just
    /// a composite one).
    private var resetDisabled: Bool {
        if let site = activeFiltersSite { return excludedCategoryCount(for: site) == 0 }
        return excludedCategoryCount == 0
    }

    private func resetFilters() {
        if let site = activeFiltersSite {
            resetFilters(for: site)
        } else {
            for site in filterableSites { resetFilters(for: site) }
        }
    }

    private func resetFilters(for site: ExternalSite) {
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
            advancedQueryHT = HitomiAdvancedQuery()
        }
    }
}

#Preview {
    NavigationStack {
        ExternalCombinedCatalogView()
    }
    .preferredColorScheme(.dark)
}
