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
    /// "Saved filters" screen — opened by tapping the filters sheet's own
    /// title (see filtersSheet's .principal toolbar item / savedFiltersSheet).
    @State private var showSavedFilters = false
    /// Name-entry alerts for the "Save filter" chip (see
    /// saveCurrentFilterChip) — ONE PER SHEET rather than a single shared
    /// flag. SwiftUI presents `.alert` from the view instance it's actually
    /// attached to; with a single flag shared between filtersSheet's own
    /// chip and savedFiltersSheet's (a sheet nested one level deeper), the
    /// alert only reliably showed up from whichever sheet the modifier
    /// happened to be declared on, and intermittently failed to appear at
    /// all from the other (SwiftUI trying to present over an
    /// already-transitioning nested-sheet stack). Two independent flags,
    /// each with its own `.alert` declared directly on its own sheet, means
    /// every presentation happens from the sheet that's ACTUALLY topmost.
    @State private var showSaveFilterPrompt = false
    @State private var showSaveFilterPromptInSavedFilters = false
    @State private var newFilterName = ""
    /// "Found ~N titles" banner — same mechanism as ExternalSearchView (see
    /// its doc-comments): shown only right after Return, summing every
    /// enabled site's own total where the site states one (currently only
    /// e-hentai, see ExternalSiteProvider.lastKnownEstimatedTotal) and
    /// falling back to page-count math for the rest (see
    /// ExternalCatalogGridView.estimatedTotalCount).
    @State private var searchResultCount: Int?
    @State private var searchResultIsExact = false
    @State private var searchJustSubmitted = false
    /// Pixiv tag suggestions for the shared search field (see
    /// pixivSearchSuggestions) — "original (translation)", exactly the
    /// real app's own search-bar behavior (per direct request), only
    /// fetched/shown when pixiv is one of the enabled sites.
    @State private var pixivSuggestions: [ExternalTagSuggestion] = []

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
    private var showsPixivFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .pixiv } }
    private var showsCategoryFilter: Bool {
        showsEHentaiFilter || showsImhentaiFilter || showsSimplyHentaiFilter || showsThreeHentaiFilter || showsHentaiPillFilter || showsHitomiFilter || showsPixivFilter
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
    private var advancedQueryPixiv: PixivAdvancedQuery {
        get { filterStore.combinedPixivAdvancedQuery }
        nonmutating set { filterStore.combinedPixivAdvancedQuery = newValue }
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
            + (advancedQueryPixiv.isEmpty ? 0 : 1)
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
        case .pixiv:
            return advancedQueryPixiv.isEmpty ? 0 : 1
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
        // Pixiv's "Search options" combine ADDITIVELY with the shared
        // field instead of replacing it (see PixivAdvancedQuery's
        // doc-comment) — no exclusivity branch here, always
        // committedQuery + whatever filters are set.
        if site == .pixiv {
            return .search(query: advancedQueryPixiv.encoded(word: committedQuery), excludedCategoryBits: 0)
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
        VStack(spacing: 0) {
            foundCountBanner
            ExternalCatalogGridView(
                sites: sites,
                queryForSite: query(for:),
                title: committedQuery.isEmpty ? "Recently" : committedQuery,
                embedded: true,
                leadingControls: showsCategoryFilter ? AnyView(filtersButton) : nil
            )
            .onResultsCount { summary in
                guard searchJustSubmitted else { return }
                searchResultCount = summary.estimatedTotal
                searchResultIsExact = summary.isEstimateExact
            }
            // .id — the same trick as ExternalSearchView: force a new view
            // instance on any change to any of the independent queries (shared
            // OR imhentai-specific), so the grid's @State resets and .task
            // reloads from scratch.
            .id("\(committedQuery)#\(sites.map { queryIdentity(for: $0) }.joined(separator: "|"))#\(excludedCategoryBits)")
        }
        .navigationTitle("Каталог")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Название, тег, автор…")
        // Commits immediately on Return (see ExternalSearchView.commitSearch
        // — same "found ~N titles specifically on Enter" request), rather
        // than waiting out the debounce below.
        .onSubmit(of: .search) { commitSearch() }
        .searchSuggestions {
            if sites.contains(.pixiv) {
                ForEach(pixivSuggestions, id: \.name) { suggestion in
                    Text(suggestion.category.isEmpty ? suggestion.name : "\(suggestion.name) (\(suggestion.category))")
                        .searchCompletion(suggestion.name)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showFilters) {
            filtersSheet
        }
        .onAppear {
            query = filterStore.combinedQuery
            committedQuery = query
        }
        .onChange(of: query) { _, _ in searchJustSubmitted = false }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            committedQuery = query.trimmingCharacters(in: .whitespaces)
            filterStore.combinedQuery = committedQuery
        }
        .task(id: query) { await updatePixivSuggestions() }
    }

    /// Pixiv's own `/v2/search/autocomplete` — see PixivProvider.
    /// fetchAutocomplete's doc-comment for the translated-tag behavior.
    /// Runs as its OWN separate `.task(id: query)` (not merged into the
    /// debounce above) so a slow/failed autocomplete call can never delay
    /// committing the actual search text.
    private func updatePixivSuggestions() async {
        guard sites.contains(.pixiv) else { pixivSuggestions = []; return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else { pixivSuggestions = []; return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespaces) else { return }
        let provider = ExternalSiteRegistry.provider(for: .pixiv)
        guard let results = try? await provider.fetchAutocomplete(query: trimmed, namespace: nil) else {
            pixivSuggestions = []
            return
        }
        guard !Task.isCancelled else { return }
        pixivSuggestions = Array(results.prefix(10))
    }

    private func commitSearch() {
        searchJustSubmitted = true
        committedQuery = query.trimmingCharacters(in: .whitespaces)
        filterStore.combinedQuery = committedQuery
    }

    @ViewBuilder
    private var foundCountBanner: some View {
        if searchJustSubmitted, let searchResultCount {
            Text(searchResultIsExact ? "Найдено \(searchResultCount) тайтлов" : "Найдено ≈\(searchResultCount) тайтлов")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 4)
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
                // A tappable stand-in for the plain title — per direct
                // request, tapping "Filters" opens the saved-presets
                // screen (savedFiltersSheet). A .principal toolbar item
                // replaces the default title view entirely, so the
                // .navigationTitle above stays only for the back-button/
                // accessibility label, never actually drawn here.
                ToolbarItem(placement: .principal) {
                    Button {
                        showSavedFilters = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Фильтры").font(.headline)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
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
        .sheet(isPresented: $showSavedFilters) {
            savedFiltersSheet
        }
        // Declared directly on THIS sheet (not hoisted to the root — see
        // showSaveFilterPrompt's doc-comment) so it reliably presents when
        // the chip in filterSiteChips (this sheet's own bottom row) is
        // tapped.
        .alert("Сохранить фильтр", isPresented: $showSaveFilterPrompt) {
            TextField("Название", text: $newFilterName)
            Button("Отмена", role: .cancel) { newFilterName = "" }
            Button("Сохранить") { saveCurrentFilter() }
        }
    }

    /// "Saved filters" — opened by tapping the "Filters" sheet's own title.
    /// Per direct feedback, NOT scoped per site/tab (an earlier version of
    /// this screen was, with its own All/site chip switcher) — one flat
    /// list, saving/applying always covers every site's filters together
    /// (see ExternalSavedFilter/snapshotCurrentFilters/applySavedFilter),
    /// regardless of which tab was active in filtersSheet when you opened
    /// this or tapped "Save filter".
    private var savedFiltersSheet: some View {
        NavigationStack {
            ScrollView {
                savedFiltersList
                    .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Сохранённые фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showSavedFilters = false }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveCurrentFilterChip(isPresented: $showSaveFilterPromptInSavedFilters)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Declared directly on THIS sheet — see showSaveFilterPrompt's
        // doc-comment: a shared alert hoisted to the root intermittently
        // failed to present from here, since this sheet sits nested two
        // levels deep (root → filtersSheet → savedFiltersSheet) and the
        // root was often mid-transition presenting/dismissing one of the
        // two sheets above it when the flag flipped.
        .alert("Сохранить фильтр", isPresented: $showSaveFilterPromptInSavedFilters) {
            TextField("Название", text: $newFilterName)
            Button("Отмена", role: .cancel) { newFilterName = "" }
            Button("Сохранить") { saveCurrentFilter() }
        }
    }

    private func saveCurrentFilterChip(isPresented: Binding<Bool>) -> some View {
        Button {
            newFilterName = ""
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.footnote.weight(.semibold))
                Text("Сохранить фильтр").font(.footnote.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.pillControlHeight)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var savedFiltersList: some View {
        let items = filterStore.savedCombinedFilters
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bookmark").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                Text("Нет сохранённых фильтров").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Text("Настройте фильтры и нажмите «Сохранить фильтр» внизу")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            VStack(spacing: 10) {
                ForEach(items) { preset in
                    savedFilterRow(preset)
                }
            }
        }
    }

    private func savedFilterRow(_ preset: ExternalSavedFilter) -> some View {
        HStack {
            Button {
                applySavedFilter(preset)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        Text("Активных фильтров: \(preset.filterCount)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                deleteSavedFilter(preset)
            } label: {
                Image(systemName: "trash").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Captures the CURRENT state of every site's filters at once into a
    /// new unnamed preset — the name is filled in by saveCurrentFilter
    /// right after the alert. NOT scoped to `activeFiltersSite` (see
    /// ExternalSavedFilter's doc-comment) — saving from any tab captures
    /// everything the same way.
    private func snapshotCurrentFilters() -> ExternalSavedFilter {
        var snapshot = ExternalSavedFilter(name: "")
        snapshot.excludedCategoriesEH = excludedCategoriesEH
        snapshot.advancedQueryEH = advancedQueryEH
        snapshot.excludedCategoriesIH = excludedCategoriesIH
        snapshot.excludedLanguagesIH = excludedLanguagesIH
        snapshot.advancedQueryIH = advancedQueryIH
        snapshot.advancedQuerySH = advancedQuerySH
        snapshot.advancedQuery3H = advancedQuery3H
        snapshot.advancedQueryHP = advancedQueryHP
        snapshot.advancedQueryHT = advancedQueryHT
        snapshot.advancedQueryPixiv = advancedQueryPixiv
        return snapshot
    }

    private func saveCurrentFilter() {
        let trimmed = newFilterName.trimmingCharacters(in: .whitespaces)
        newFilterName = ""
        guard !trimmed.isEmpty else { return }
        var snapshot = snapshotCurrentFilters()
        snapshot.name = trimmed
        filterStore.savedCombinedFilters.append(snapshot)
    }

    /// Restores a saved preset back into every site's live filter state at
    /// once (see ExternalSavedFilter's doc-comment).
    private func applySavedFilter(_ preset: ExternalSavedFilter) {
        excludedCategoriesEH = preset.excludedCategoriesEH
        advancedQueryEH = preset.advancedQueryEH
        excludedCategoriesIH = preset.excludedCategoriesIH
        excludedLanguagesIH = preset.excludedLanguagesIH
        advancedQueryIH = preset.advancedQueryIH
        advancedQuerySH = preset.advancedQuerySH
        advancedQuery3H = preset.advancedQuery3H
        advancedQueryHP = preset.advancedQueryHP
        advancedQueryHT = preset.advancedQueryHT
        advancedQueryPixiv = preset.advancedQueryPixiv
        showSavedFilters = false
    }

    private func deleteSavedFilter(_ preset: ExternalSavedFilter) {
        filterStore.savedCombinedFilters.removeAll { $0.id == preset.id }
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
                // Per direct feedback: visible right here, in every tab
                // (All/site) of THIS bar — not only inside the separate
                // "Saved filters" screen (savedFiltersSheet, opened via the
                // title) — saves whatever's currently set for the active
                // tab (activeFiltersSite) under a new name.
                saveCurrentFilterChip(isPresented: $showSaveFilterPrompt)
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
                if showsPixivFilter { filterSection(for: .pixiv) }
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
        case .pixiv:
            VStack(alignment: .leading, spacing: 8) {
                Text("Pixiv — параметры поиска").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                PixivAdvancedFieldsPicker(query: Binding(
                    get: { advancedQueryPixiv },
                    set: { advancedQueryPixiv = $0 }
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
        case .pixiv:
            advancedQueryPixiv = PixivAdvancedQuery()
        }
    }
}

#Preview {
    NavigationStack {
        ExternalCombinedCatalogView()
    }
    .preferredColorScheme(.dark)
}
