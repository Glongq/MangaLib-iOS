import SwiftUI

/// Каталог-экран для внешних сайтов со свободным текстовым поиском вместо
/// алфавитного справочника (capabilities.hasSearch && !hasTagBrowser — см.
/// EHentaiProvider; у hitomi наоборот, см. ExternalTagBrowserView).
///
/// Визуально — ПОЛНОСТЬЮ 1-в-1 MangaCatalogView (по прямой просьбе 30.08):
/// заголовок "Каталог" крупным .large (не "Поиск"/.inline, как было),
/// родной `.searchable()` вместо самодельного TextField+HStack-бокса
/// (тот же приём, что и в самом MangaCatalogView — не отдельная позиция
/// поля, а системная строка поиска под навбаром), «Фильтры» — стеклянная
/// пилюля в общей нижней панели (см. ExternalCatalogGridView.controlsBar,
/// куда передаётся через leadingControls) вместо того, чтобы категории
/// всегда торчали на экране. Без отдельного перехода: тайтлы появляются
/// сразу под полем (см. ExternalCatalogGridView(embedded: true)), с
/// небольшой задержкой после последнего нажатия клавиши (debounce).
struct ExternalSearchView: View {
    let site: ExternalSite

    @ObservedObject private var filterStore = ExternalCatalogFilterStore.shared
    @State private var query = ""
    /// Запрос, который реально сейчас ищется — отдельно от `query` (что
    /// набрано в поле прямо сейчас), чтобы не дёргать сеть на КАЖДОЕ
    /// нажатие клавиши (см. .task(id: query) ниже — debounce).
    @State private var committedQuery = ""
    @State private var showFilters = false

    private var capabilities: ExternalSiteCapabilities { ExternalSiteRegistry.provider(for: site).capabilities }
    /// Два РАЗНЫХ набора категорий (e-hentai — EHentaiCategory, imhentai —
    /// ImhentaiCategory, свои значения/количество у каждого сайта, см.
    /// ImhentaiProvider.swift) — храним отдельно в ExternalCatalogFilterStore,
    /// переключаемся по `site` (см. excludedCategoryBits/filtersSheet ниже).
    /// hitomi/3hentai сюда не попадают вообще — hasCategoryFilter у них
    /// false, filtersButton не показывается.
    private var excludedCategoriesEH: Set<EHentaiCategory> {
        get { filterStore.excludedCategories[site] ?? [] }
        nonmutating set { filterStore.excludedCategories[site] = newValue }
    }
    private var excludedCategoriesIH: Set<ImhentaiCategory> {
        get { filterStore.excludedImhentaiCategories[site] ?? [] }
        nonmutating set { filterStore.excludedImhentaiCategories[site] = newValue }
    }
    /// Языки imhentai (см. ImhentaiLanguage.bit doc-comment) — отдельное
    /// измерение фильтра, тот же общий bitmask-канал, что и категории.
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
    /// Расширенные поля (Tags/Parodies/Artists/Characters/Groups, см.
    /// ImhentaiAdvancedQuery) — только у imhentai, только внутри «Фильтры».
    private var advancedQueryIH: ImhentaiAdvancedQuery {
        get { filterStore.imhentaiAdvancedQueries[site] ?? ImhentaiAdvancedQuery() }
        nonmutating set { filterStore.imhentaiAdvancedQueries[site] = newValue }
    }
    private var excludedCategoryCount: Int {
        switch site {
        case .ehentai: return excludedCategoriesEH.count
        case .imhentai:
            let advanced = advancedQueryIH
            return excludedCategoriesIH.count + excludedLanguagesIH.count
                + advanced.tags.count + advanced.parodies.count + advanced.artists.count + advanced.characters.count + advanced.groups.count
        default: return 0
        }
    }
    /// Итоговая строка, реально уходящая в `key=` — свободный текст из
    /// строки поиска + расширенные поля (см. ImhentaiAdvancedQuery.
    /// clauses() doc-comment насчёт того, что комбинация нескольких значений
    /// не подтверждена отдельным HAR, собрана по аналогии). У сайтов без
    /// расширенных полей (всё, кроме imhentai) — просто committedQuery как
    /// есть, поведение не меняется.
    private var composedQuery: String {
        guard site == .imhentai else { return committedQuery }
        let clauses = advancedQueryIH.clauses()
        guard !clauses.isEmpty else { return committedQuery }
        var parts: [String] = []
        if !committedQuery.isEmpty { parts.append(committedQuery) }
        parts.append(contentsOf: clauses)
        return parts.joined(separator: " ")
    }

    var body: some View {
        // Пустой запрос — не "Введите запрос", а лента "Recently" (см.
        // HitomiProvider/EHentaiProvider.fetchIdsBySearch с пустым query)
        // — тайтлы видны сразу, без необходимости сначала что-то ввести.
        // .id — принудительно НОВЫЙ экземпляр вью на каждое изменение
        // запроса/категорий, чтобы @State сетки (items/cursors/...)
        // сбрасывался и .task заново запускал загрузку — простая смена
        // параметра `query:` этого не делает, SwiftUI считает это ТЕМ ЖЕ
        // вью на том же месте дерева.
        ExternalCatalogGridView(
            site: site,
            query: .search(query: composedQuery, excludedCategoryBits: excludedCategoryBits),
            title: committedQuery.isEmpty ? "Recently" : committedQuery,
            embedded: true,
            leadingControls: capabilities.hasCategoryFilter ? AnyView(filtersButton) : nil
        )
        .id("\(composedQuery)#\(excludedCategoryBits)")
        .navigationTitle("Каталог")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Название, тег, автор…")
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showFilters) {
            filtersSheet
        }
        .onAppear {
            // Восстанавливаем то, что реально набрано/выбрано в прошлый раз
            // (см. ExternalCatalogFilterStore) — экран пересоздаётся при
            // уходе/возврате на вкладку Каталог, query/committedQuery как
            // обычный @State иначе сбрасывались бы каждый раз.
            query = filterStore.queries[site] ?? ""
            committedQuery = query
        }
        .task(id: query) {
            // Debounce — 400мс тишины после последнего нажатия, иначе
            // каждая буква била бы отдельным сетевым запросом. .task(id:)
            // сам отменяет предыдущую попытку, когда query меняется снова
            // раньше, чем истекли эти 400мс.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            committedQuery = query.trimmingCharacters(in: .whitespaces)
            filterStore.queries[site] = committedQuery
        }
    }

    // MARK: Фильтры — стеклянная пилюля (см. ExternalCatalogGridView.
    // controlPill), тап открывает лист с переключателями (EHentaiCategoryPicker).

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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showFilters = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var categoryPicker: some View {
        switch site {
        case .ehentai:
            EHentaiCategoryPicker(excluded: Binding(
                get: { excludedCategoriesEH },
                set: { excludedCategoriesEH = $0 }
            ))
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
        case .hitomi, .threeHentai:
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
