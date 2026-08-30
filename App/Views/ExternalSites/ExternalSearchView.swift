import SwiftUI

/// Каталог-экран для внешних сайтов со свободным текстовым поиском вместо
/// алфавитного справочника (capabilities.hasSearch && !hasTagBrowser — см.
/// EHentaiProvider; у hitomi наоборот, см. ExternalTagBrowserView). Поле
/// ввода (+ кнопки категорий у сайтов с capabilities.hasCategoryFilter, см.
/// EHentaiCategoryPicker) — по прямой просьбе БЕЗ отдельного перехода:
/// тайтлы появляются сразу под полем, на том же экране (см.
/// ExternalCatalogGridView(embedded: true)), с небольшой задержкой после
/// последнего нажатия клавиши (debounce), а не по отдельному "Искать".
struct ExternalSearchView: View {
    let site: ExternalSite

    @State private var query = ""
    /// Запрос, который реально сейчас ищется — отдельно от `query` (что
    /// набрано в поле прямо сейчас), чтобы не дёргать сеть на КАЖДОЕ
    /// нажатие клавиши (см. .task(id: query) ниже — debounce).
    @State private var committedQuery = ""
    @State private var excludedCategories: Set<EHentaiCategory> = []
    @FocusState private var isFocused: Bool

    private var capabilities: ExternalSiteCapabilities { ExternalSiteRegistry.provider(for: site).capabilities }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if capabilities.hasCategoryFilter {
                EHentaiCategoryPicker(excluded: $excludedCategories)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if committedQuery.isEmpty {
                StateView(icon: "magnifyingglass", title: "Введите запрос", fillScreen: true)
            } else {
                // .id — принудительно НОВЫЙ экземпляр вью на каждое
                // изменение запроса/категорий, чтобы @State сетки (items/
                // cursors/...) сбрасывался и .task заново запускал загрузку
                // — простая смена параметра `query:` этого не делает, SwiftUI
                // считает это ТЕМ ЖЕ вью на том же месте дерева.
                ExternalCatalogGridView(site: site, query: .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits), title: committedQuery, embedded: true)
                    .id("\(committedQuery)#\(excludedCategoryBits)")
            }
        }
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .task(id: query) {
            // Debounce — 400мс тишины после последнего нажатия, иначе
            // каждая буква била бы отдельным сетевым запросом. .task(id:)
            // сам отменяет предыдущую попытку, когда query меняется снова
            // раньше, чем истекли эти 400мс.
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
        ExternalSearchView(site: .ehentai)
    }
    .preferredColorScheme(.dark)
}
