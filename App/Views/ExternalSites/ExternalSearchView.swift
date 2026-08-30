import SwiftUI

/// Каталог-экран для внешних сайтов со свободным текстовым поиском вместо
/// алфавитного справочника (capabilities.hasSearch && !hasTagBrowser — см.
/// EHentaiProvider; у hitomi наоборот, см. ExternalTagBrowserView). Просто
/// поле ввода (+ кнопки категорий у сайтов с capabilities.hasCategoryFilter,
/// см. EHentaiCategoryPicker) + переход в ту же ExternalCatalogGridView, но
/// с `.search(query:excludedCategoryBits:)` вместо `.tag(...)`.
struct ExternalSearchView: View {
    let site: ExternalSite

    @State private var query = ""
    @State private var excludedCategories: Set<EHentaiCategory> = []
    @FocusState private var isFocused: Bool

    private var capabilities: ExternalSiteCapabilities { ExternalSiteRegistry.provider(for: site).capabilities }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

    private struct SearchRequest: Hashable {
        let query: String
        let excludedCategoryBits: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if capabilities.hasCategoryFilter {
                EHentaiCategoryPicker(excluded: $excludedCategories)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                StateView(icon: "magnifyingglass", title: "Введите запрос", fillScreen: true)
            } else {
                NavigationLink(value: SearchRequest(query: query, excludedCategoryBits: excludedCategoryBits)) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Искать «\(query)»")
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
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .navigationDestination(for: SearchRequest.self) { request in
            ExternalCatalogGridView(site: site, query: .search(query: request.query, excludedCategoryBits: request.excludedCategoryBits), title: request.query)
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
        ExternalSearchView(site: .ehentai)
    }
    .preferredColorScheme(.dark)
}
