import SwiftUI

/// Каталог-экран для внешних сайтов со свободным текстовым поиском вместо
/// алфавитного справочника (capabilities.hasSearch && !hasTagBrowser — см.
/// EHentaiProvider; у hitomi наоборот, см. ExternalTagBrowserView). Просто
/// поле ввода + переход в ту же ExternalCatalogGridView, но с
/// `.search(query:)` вместо `.tag(...)`.
struct ExternalSearchView: View {
    let site: ExternalSite

    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                StateView(icon: "magnifyingglass", title: "Введите запрос", fillScreen: true)
            } else {
                NavigationLink(value: query) {
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
        .navigationDestination(for: String.self) { text in
            ExternalCatalogGridView(site: site, query: .search(query: text), title: text)
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
