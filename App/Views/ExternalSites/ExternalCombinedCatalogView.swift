import SwiftUI

/// Совместный каталог/выдача — «Все сайты» (см. ExternalSiteSession.
/// combinedModeActive, выбирается в переключателе сайта — SideMenuView.
/// siteRow). Один запрос уходит СРАЗУ на все включённые сайты
/// (ExternalSiteSession.enabledSites), результат мержится в одну сетку
/// (см. ExternalCatalogGridView, поддержка нескольких `sites`) — карточка
/// каждого тайтла подписана источником (ExternalCatalogGridView.
/// showsSourceBadge / ExternalGalleryDetailView "Источник").
struct ExternalCombinedCatalogView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @State private var query = ""
    @FocusState private var isFocused: Bool

    private var sites: [ExternalSite] { ExternalSite.allCases.filter { session.enabledSites.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                StateView(
                    icon: "square.grid.2x2",
                    title: "Введите запрос",
                    description: "Ищет сразу по всем включённым сайтам: \(sites.map(\.displayName).joined(separator: ", ")).",
                    fillScreen: true
                )
            } else {
                NavigationLink(value: query) {
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
        .navigationDestination(for: String.self) { text in
            ExternalCatalogGridView(sites: sites, query: .search(query: text), title: text)
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
