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
    private var showsCategoryFilter: Bool { showsEHentaiFilter || showsImhentaiFilter }
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
    private var excludedCategoryBits: Int {
        excludedCategoriesEH.reduce(0) { $0 | $1.bit }
            | excludedCategoriesIH.reduce(0) { $0 | $1.bit }
            | excludedLanguagesIH.reduce(0) { $0 | $1.bit }
    }
    private var excludedCategoryCount: Int { excludedCategoriesEH.count + excludedCategoriesIH.count + excludedLanguagesIH.count }

    var body: some View {
        // Пустой запрос — лента "Recently" сразу по всем включённым
        // сайтам (см. ExternalSearchView — тот же принцип), не
        // требует сначала что-то ввести.
        ExternalCatalogGridView(
            sites: sites,
            query: .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits),
            title: committedQuery.isEmpty ? "Recently" : committedQuery,
            embedded: true,
            leadingControls: showsCategoryFilter ? AnyView(filtersButton) : nil
        )
        .id("\(committedQuery)#\(excludedCategoryBits)")
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

    private var filtersSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if showsEHentaiFilter {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("E-Hentai").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            EHentaiCategoryPicker(excluded: Binding(
                                get: { excludedCategoriesEH },
                                set: { excludedCategoriesEH = $0 }
                            ))
                        }
                    }
                    if showsImhentaiFilter {
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
                    }
                }
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
}

#Preview {
    NavigationStack {
        ExternalCombinedCatalogView()
    }
    .preferredColorScheme(.dark)
}
