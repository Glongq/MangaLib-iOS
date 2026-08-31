import SwiftUI

/// Catalog menu for ONE external site (see MangaCatalogView) — the
/// "Catalog" tab used to jump straight into a specific screen (either the
/// tag list OR search); per a direct request this is now a separate little
/// menu with entries: "Tag list" shows up only if the site actually has an
/// alphabetical index (capabilities.hasTagBrowser), "Search" — if it has
/// free-text search (capabilities.hasSearch). Neither entry leads to
/// anything related to MangaLib.
struct ExternalCatalogMenuView: View {
    let site: ExternalSite

    private var capabilities: ExternalSiteCapabilities { ExternalSiteRegistry.provider(for: site).capabilities }

    var body: some View {
        content
            .navigationTitle(site.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        if !capabilities.hasTagBrowser && !capabilities.hasSearch {
            ExternalScreenContent(site: site, featureTitle: "Каталог")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if capabilities.hasTagBrowser {
                        NavigationLink {
                            ExternalTagBrowserView(site: site)
                        } label: {
                            row(icon: "tag", title: "Список тегов")
                        }
                        .buttonStyle(.plain)
                        if capabilities.hasSearch {
                            Divider().overlay(Theme.separator).padding(.leading, 16 + 28 + 14)
                        }
                    }
                    if capabilities.hasSearch {
                        NavigationLink {
                            ExternalSearchView(site: site)
                        } label: {
                            row(icon: "magnifyingglass", title: "Поиск")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28)
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        ExternalCatalogMenuView(site: .hitomi)
    }
    .preferredColorScheme(.dark)
}
