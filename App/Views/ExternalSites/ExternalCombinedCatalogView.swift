import SwiftUI

/// Совместный каталог/выдача — «Все сайты» (см. ExternalSiteSession.
/// combinedModeActive, выбирается в переключателе сайта — SideMenuView.
/// siteRow). Один запрос уходит СРАЗУ на все включённые сайты
/// (ExternalSiteSession.enabledSites), результат мержится в одну сетку
/// (см. ExternalCatalogGridView, поддержка нескольких `sites`) — карточка
/// каждого тайтла подписана источником (ExternalCatalogGridView.
/// showsSourceBadge / ExternalGalleryDetailView "Источник"). «Фильтры» (см.
/// EHentaiCategoryPicker) показываются, если ХОТЯ БЫ один из включённых
/// сайтов их понимает (capabilities.hasCategoryFilter) — остальные сайты в
/// выдаче просто честно игнорируют bitmask (см. ExternalSiteProvider.
/// fetchIdsBySearch(excludedCategoryBits:)). Визуально пилюля «Фильтры» —
/// 1-в-1 MangaCatalogView.controlsBar (см. ExternalSearchView). Как и у
/// ExternalSearchView — по прямой просьбе БЕЗ отдельного перехода, тайтлы
/// появляются сразу под полем на этом же экране (debounce, см. .task(id:)),
/// а состояние (запрос/категории) переживает уход/возврат на вкладку (см.
/// ExternalCatalogFilterStore.combinedQuery/combinedExcludedCategories).
struct ExternalCombinedCatalogView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @ObservedObject private var filterStore = ExternalCatalogFilterStore.shared
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var showFilters = false
    @FocusState private var isFocused: Bool

    private var sites: [ExternalSite] { ExternalSite.allCases.filter { session.enabledSites.contains($0) } }
    private var showsCategoryFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter } }
    private var excludedCategories: Set<EHentaiCategory> {
        get { filterStore.combinedExcludedCategories }
        nonmutating set { filterStore.combinedExcludedCategories = newValue }
    }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if showsCategoryFilter {
                controlsBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            // Пустой запрос — лента "Recently" сразу по всем включённым
            // сайтам (см. ExternalSearchView — тот же принцип), не
            // требует сначала что-то ввести.
            ExternalCatalogGridView(sites: sites, query: .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits), title: committedQuery.isEmpty ? "Recently" : committedQuery, embedded: true)
                .id("\(committedQuery)#\(excludedCategoryBits)")
        }
        .navigationTitle("Все сайты")
        .navigationBarTitleDisplayMode(.inline)
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Название, тег, автор…", text: $query)
                .focused($isFocused)
                .foregroundStyle(Theme.textPrimary)
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
    }

    // MARK: Фильтры — см. ExternalSearchView.controlsBar/controlLabel (тот
    // же стиль, скопирован построчно — отдельные вью, общий компонент не
    // заводим ради одной пилюли).

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                showFilters = true
            } label: {
                controlLabel(icon: "slider.horizontal.3", text: "Фильтры", badge: excludedCategories.count)
            }
            Spacer(minLength: 0)
        }
    }

    private func controlLabel(icon: String, text: String, badge: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
            if badge > 0 {
                Text("\(badge)")
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
