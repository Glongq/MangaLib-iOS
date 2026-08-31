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
    /// Расширенные поля Simply Hentai (Поиск/Tags/Parodies/Characters/
    /// Artists/Translators/Language/Series title, см.
    /// SimplyHentaiAdvancedQuery) — ЭКСКЛЮЗИВНО по отношению к общему
    /// committedQuery (см. resolvedQuery doc-comment: правило одно для
    /// всех сайтов с расширенными полями, кроме imhentai/hentaiPill).
    private var advancedQuerySH: SimplyHentaiAdvancedQuery {
        get { filterStore.simplyHentaiAdvancedQueries[site] ?? SimplyHentaiAdvancedQuery() }
        nonmutating set { filterStore.simplyHentaiAdvancedQueries[site] = newValue }
    }
    /// Расширенные поля E-Hentai (Поиск/Tags/Parodies/Characters/Artists/
    /// Groups, см. EHentaiAdvancedQuery) — работают ВМЕСТЕ с bitmask-
    /// категориями (excludedCategoriesEH, отдельный канал), но эксклюзивно
    /// по отношению к committedQuery.
    private var advancedQueryEH: EHentaiAdvancedQuery {
        get { filterStore.ehentaiAdvancedQueries[site] ?? EHentaiAdvancedQuery() }
        nonmutating set { filterStore.ehentaiAdvancedQueries[site] = newValue }
    }
    /// Расширенные поля 3Hentai (Поиск/Tags, см. ThreeHentaiAdvancedQuery).
    private var advancedQuery3H: ThreeHentaiAdvancedQuery {
        get { filterStore.threeHentaiAdvancedQueries[site] ?? ThreeHentaiAdvancedQuery() }
        nonmutating set { filterStore.threeHentaiAdvancedQueries[site] = newValue }
    }
    /// Одно измерение + значение HentaiPill (см. HentaiPillAdvancedQuery —
    /// сайт не комбинирует измерения между собой и не сочетается с общим
    /// текстовым поиском ни при каких условиях, см. resolvedQuery).
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
    /// Итоговый запрос, реально уходящий в ExternalCatalogGridView.
    ///
    /// Правило — ЭКСКЛЮЗИВНОЕ (по прямой просьбе 01.09): если у сайта
    /// заполнено хоть одно расширенное поле («Фильтры»), общее верхнее
    /// поле `.searchable()` (committedQuery) для этого сайта перестаёт
    /// участвовать вообще — ищем строго по тому, что набрано в самих
    /// полях. Если расширенные поля пусты — как раньше, обычный
    /// committedQuery.
    ///
    /// imhentai — частный случай этого же правила: своя строка
    /// (advancedQueryIH.searchText) заменяет committedQuery БЕЗУСЛОВНО
    /// (committedQuery у него даже не показывается, см. body), поэтому
    /// отдельная ветка, как и раньше.
    ///
    /// hentaiPill — тоже частный случай: сайт не умеет комбинировать
    /// измерения, поэтому при непустом advancedQueryHP запрос — не
    /// `.search(...)`, а `.tag(namespace:value:)` напрямую; при пустом —
    /// обычный `.search(committedQuery, ...)`, как у всех.
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
    /// Строковая часть resolvedQuery — только для `.id(...)` (принудительный
    /// сброс @State сетки, см. content) и displayTitle; в саму сеть уходит
    /// resolvedQuery целиком (в т.ч. .tag-случай hentaiPill).
    private var resolvedQueryIdentity: String {
        switch resolvedQuery {
        case .tag(let namespace, let value): return "tag:\(namespace)/\(value)"
        case .search(let query, _): return query
        }
    }

    /// Заголовок ленты результатов — у сайтов с активными расширенными
    /// полями отражает ИХ (общее committedQuery для этого сайта уже ни на
    /// что не влияет, см. resolvedQuery).
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
        // Верхнее общее .searchable() — только у сайтов, которые реально
        // его слушают (см. resolvedQuery); у imhentai оно бы просто ничего
        // не делало (искало бы в никуда), путая пользователя тем самым
        // багом, из-за которого его вообще убрали — поэтому для imhentai
        // не показываем совсем, вместо него — своя строка в «Фильтрах»
        // (ImhentaiAdvancedFieldsPicker).
        if site == .imhentai {
            content
        } else {
            content.searchable(text: $query, prompt: "Название, тег, автор…")
        }
    }

    private var content: some View {
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
            // Восстанавливаем то, что реально набрано/выбрано в прошлый раз
            // (см. ExternalCatalogFilterStore) — экран пересоздаётся при
            // уходе/возврате на вкладку Каталог, query/committedQuery как
            // обычный @State иначе сбрасывались бы каждый раз. У imhentai
            // это всё равно ни на что не влияет (нет .searchable()), но
            // безобидно оставить как есть — проще, чем городить ветвление.
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

    /// Сброс фильтров ТЕКУЩЕГО сайта (этот экран всегда про один сайт, в
    /// отличие от ExternalCombinedCatalogView — там сброс ограничен
    /// активной вкладкой чипа).
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
