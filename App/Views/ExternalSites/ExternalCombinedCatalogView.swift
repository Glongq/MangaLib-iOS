import SwiftUI

/// Совместный каталог/выдача — «Все сайты» (см. ExternalSiteSession.
/// combinedModeActive, выбирается в переключателе сайта — SideMenuView.
/// siteRow). Один запрос уходит СРАЗУ на все включённые сайты
/// (ExternalSiteSession.enabledSites), результат мержится в одну сетку
/// (см. ExternalCatalogGridView, поддержка нескольких `sites`) — карточка
/// каждого тайтла подписана источником (ExternalCatalogGridView.
/// showsSourceBadge / ExternalGalleryDetailView "Источник").
///
/// Визуально — тот же 1-в-1 порт MangaCatalogView, что и у ExternalSearchView
/// (см. её doc-comment): "Каталог" крупным .large, родной `.searchable()`,
/// «Фильтры» — стеклянная пилюля в общей нижней панели (показывается, если
/// ХОТЯ БЫ один из включённых сайтов понимает capabilities.hasCategoryFilter
/// — остальные в выдаче честно игнорируют bitmask, см.
/// ExternalSiteProvider.fetchIdsBySearch(excludedCategoryBits:)). Тайтлы —
/// без отдельного перехода, сразу под полем (debounce, см. .task(id:)), а
/// состояние (запрос/категории) переживает уход/возврат на вкладку (см.
/// ExternalCatalogFilterStore.combinedQuery/combinedExcludedCategories).
struct ExternalCombinedCatalogView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @ObservedObject private var filterStore = ExternalCatalogFilterStore.shared
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var showFilters = false

    private var sites: [ExternalSite] { ExternalSite.allCases.filter { session.enabledSites.contains($0) } }
    /// В отличие от ExternalSearchView (там всегда РОВНО один сайт — можно
    /// switch по `site`), здесь одновременно может быть включено несколько
    /// сайтов сразу — поэтому ОБА набора категорий (e-hentai/imhentai)
    /// суммируются, а не выбираются по одному активному сайту.
    private var showsEHentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .ehentai } }
    private var showsImhentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .imhentai } }
    /// Работает и когда включён ровно ОДИН simplyHentai — `sites` тут же
    /// содержит его одного, `.contains` истинен, фильтр показывается (по
    /// прямой просьбе: "если 1 сайт там выбран тоже были эта фильтрация").
    private var showsSimplyHentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .simplyHentai } }
    private var showsThreeHentaiFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .threeHentai } }
    private var showsHentaiPillFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter && $0 == .hentaiPill } }
    private var showsCategoryFilter: Bool {
        showsEHentaiFilter || showsImhentaiFilter || showsSimplyHentaiFilter || showsThreeHentaiFilter || showsHentaiPillFilter
    }
    /// Сайты, у которых сейчас реально есть что показать во вкладке
    /// «Фильтры» — источник чипов переключателя (см. filtersSheet).
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
    /// Активная вкладка чипа во «Фильтрах» — nil означает «Все» (все
    /// разделы стопкой, как раньше). См. filtersSheet.
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
    }
    /// Счётчик активных фильтров ОДНОГО сайта — используется только чипами
    /// переключателя (см. filtersSheet), чтобы показывать badge не общий,
    /// а по разделу.
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
            return 0
        }
    }
    /// Запрос ПО КАЖДОМУ сайту отдельно — по прямой просьбе (31.08):
    /// imhentai не должен видеть общее поле поиска вообще (та же причина,
    /// что и в ExternalSearchView.resolvedQuery — `/search/`/`/advsearch/`
    /// два разных парсера одного `key=`, обычный текст надёжно не
    /// находит ничего), а остальные сайты не должны видеть теги/поиск,
    /// набранные в «Фильтрах» имхентая. Раньше был ОДИН общий
    /// composedQuery на весь ExternalCatalogGridView — он утекал во ВСЕ
    /// включённые сайты разом (ExternalCatalogGridView.fetchPage дёргает
    /// один и тот же query для каждого сайта), теперь у каждого сайта
    /// свой независимый запрос (см. ExternalCatalogGridView.queryForSite).
    private func query(for site: ExternalSite) -> ExternalCatalogQuery {
        if site == .imhentai {
            let advanced = advancedQueryIH
            var parts: [String] = []
            let trimmedSearch = advanced.searchText.trimmingCharacters(in: .whitespaces)
            if !trimmedSearch.isEmpty { parts.append(trimmedSearch) }
            parts.append(contentsOf: advanced.clauses())
            return .search(query: parts.joined(separator: " "), excludedCategoryBits: excludedCategoryBits)
        }
        // HentaiPill не умеет комбинировать измерения ни между собой, ни с
        // текстом (см. ExternalSearchView.resolvedQuery) — при непустом
        // advancedQueryHP это отдельный `.tag(...)`, не `.search(...)`.
        if site == .hentaiPill {
            let advanced = advancedQueryHP
            if !advanced.isEmpty {
                return .tag(namespace: advanced.kind, value: advanced.value.trimmingCharacters(in: .whitespaces))
            }
            return .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits)
        }
        // Правило ЭКСКЛЮЗИВНОСТИ (см. ExternalSearchView.resolvedQuery, тот
        // же принцип): если у сайта заполнено хоть одно расширенное поле —
        // общее committedQuery для ЭТОГО сайта больше не участвует.
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
    /// Строковый "отпечаток" запроса каждого сайта — только для `.id(...)`
    /// (см. body), в саму сеть уходит query(for:) целиком (в т.ч.
    /// hentaiPill's `.tag`).
    private func queryIdentity(for site: ExternalSite) -> String {
        switch query(for: site) {
        case .tag(let namespace, let value): return "tag:\(namespace)/\(value)"
        case .search(let text, _): return text
        }
    }

    var body: some View {
        // Пустой запрос — лента "Recently" сразу по всем включённым
        // сайтам (см. ExternalSearchView — тот же принцип), не
        // требует сначала что-то ввести.
        ExternalCatalogGridView(
            sites: sites,
            queryForSite: query(for:),
            title: committedQuery.isEmpty ? "Recently" : committedQuery,
            embedded: true,
            leadingControls: showsCategoryFilter ? AnyView(filtersButton) : nil
        )
        // .id — тот же приём, что у ExternalSearchView: принудительно
        // новый экземпляр вью при любом изменении хоть одного из
        // независимых запросов (общего ИЛИ imhentai-специфичного), чтобы
        // @State сетки сбрасывался и .task перезапускал загрузку.
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

    // MARK: Фильтры — см. ExternalSearchView.filtersButton (тот же стиль,
    // скопирован построчно — отдельные вью, общий компонент не заводим
    // ради одной пилюли).

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

    /// Лист «Фильтры» — переключалка чипами внизу навбара: «Все» (все
    /// разделы включённых сайтов стопкой, как было раньше) + отдельный чип
    /// на каждый включённый сайт с фильтрами (показывает ТОЛЬКО его
    /// раздел). Активная вкладка хранится в filterStore — переживает
    /// закрытие/повторное открытие листа (см. combinedFiltersActiveSite).
    private var filtersSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterSiteChips
                ScrollView {
                    filterSectionsContent
                        .padding(16)
                }
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
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filterSiteChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "Все", count: excludedCategoryCount, isActive: activeFiltersSite == nil) {
                    activeFiltersSite = nil
                }
                ForEach(filterableSites, id: \.self) { site in
                    filterChip(title: site.displayName, count: excludedCategoryCount(for: site), isActive: activeFiltersSite == site) {
                        activeFiltersSite = site
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.surface)
    }

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
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(isActive ? Theme.accent : Theme.surfaceElevated, in: Capsule())
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
            EmptyView()
        }
    }

    /// Сброс — только ТЕКУЩЕГО раздела (вкладка активного чипа); на вкладке
    /// «Все» чистит фильтры сразу всех сайтов, у которых они есть (по
    /// прямой просьбе — "сбрасывает в конкретном разделе", а «Все» и есть
    /// раздел, просто составной).
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
            break
        }
    }
}

#Preview {
    NavigationStack {
        ExternalCombinedCatalogView()
    }
    .preferredColorScheme(.dark)
}
