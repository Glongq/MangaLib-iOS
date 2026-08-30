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
    private var showsCategoryFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter } }
    private var excludedCategories: Set<EHentaiCategory> {
        get { filterStore.combinedExcludedCategories }
        nonmutating set { filterStore.combinedExcludedCategories = newValue }
    }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

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
                if excludedCategories.count > 0 {
                    Text("\(excludedCategories.count)")
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
                EHentaiCategoryPicker(excluded: Binding(
                    get: { excludedCategories },
                    set: { excludedCategories = $0 }
                ))
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
