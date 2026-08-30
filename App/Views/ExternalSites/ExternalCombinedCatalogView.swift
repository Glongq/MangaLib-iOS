import SwiftUI

/// Совместный каталог/выдача — «Все сайты» (см. ExternalSiteSession.
/// combinedModeActive, выбирается в переключателе сайта — SideMenuView.
/// siteRow). Один запрос уходит СРАЗУ на все включённые сайты
/// (ExternalSiteSession.enabledSites), результат мержится в одну сетку
/// (см. ExternalCatalogGridView, поддержка нескольких `sites`) — карточка
/// каждого тайтла подписана источником (ExternalCatalogGridView.
/// showsSourceBadge / ExternalGalleryDetailView "Источник"). Кнопки
/// категорий (см. EHentaiCategoryPicker) показываются, если ХОТЯ БЫ один
/// из включённых сайтов их понимает (capabilities.hasCategoryFilter) —
/// остальные сайты в выдаче просто честно игнорируют bitmask (см.
/// ExternalSiteProvider.fetchIdsBySearch(excludedCategoryBits:)). Как и у
/// ExternalSearchView — по прямой просьбе БЕЗ отдельного перехода, тайтлы
/// появляются сразу под полем на этом же экране (debounce, см. .task(id:)).
struct ExternalCombinedCatalogView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var excludedCategories: Set<EHentaiCategory> = []
    @FocusState private var isFocused: Bool

    private var sites: [ExternalSite] { ExternalSite.allCases.filter { session.enabledSites.contains($0) } }
    private var showsCategoryFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter } }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if showsCategoryFilter {
                EHentaiCategoryPicker(excluded: $excludedCategories)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if committedQuery.isEmpty {
                StateView(
                    icon: "square.grid.2x2",
                    title: "Введите запрос",
                    description: "Ищет сразу по всем включённым сайтам: \(sites.map(\.displayName).joined(separator: ", ")).",
                    fillScreen: true
                )
            } else {
                ExternalCatalogGridView(sites: sites, query: .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits), title: committedQuery, embedded: true)
                    .id("\(committedQuery)#\(excludedCategoryBits)")
            }
        }
        .navigationTitle("Все сайты")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            committedQuery = query.trimmingCharacters(in: .whitespaces)
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
}

#Preview {
    NavigationStack {
        ExternalCombinedCatalogView()
    }
    .preferredColorScheme(.dark)
}
