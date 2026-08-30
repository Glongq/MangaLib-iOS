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
/// ExternalSiteProvider.fetchIdsBySearch(excludedCategoryBits:)).
struct ExternalCombinedCatalogView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @State private var query = ""
    @State private var excludedCategories: Set<EHentaiCategory> = []
    @FocusState private var isFocused: Bool

    private var sites: [ExternalSite] { ExternalSite.allCases.filter { session.enabledSites.contains($0) } }
    private var showsCategoryFilter: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasCategoryFilter } }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

    private struct SearchRequest: Hashable {
        let query: String
        let excludedCategoryBits: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if showsCategoryFilter {
                EHentaiCategoryPicker(excluded: $excludedCategories)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                StateView(
                    icon: "square.grid.2x2",
                    title: "Введите запрос",
                    description: "Ищет сразу по всем включённым сайтам: \(sites.map(\.displayName).joined(separator: ", ")).",
                    fillScreen: true
                )
            } else {
                NavigationLink(value: SearchRequest(query: query, excludedCategoryBits: excludedCategoryBits)) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Искать «\(query)» везде")
                        Spacer()
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .navigationTitle("Все сайты")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .navigationDestination(for: SearchRequest.self) { request in
            ExternalCatalogGridView(sites: sites, query: .search(query: request.query, excludedCategoryBits: request.excludedCategoryBits), title: request.query)
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
