import SwiftUI

/// Меню каталога ОДНОГО внешнего сайта (см. MangaCatalogView) — раньше
/// вкладка «Каталог» сразу прыгала в конкретный экран (список тегов ИЛИ
/// поиск), по прямой просьбе теперь это отдельная менюшка с пунктами:
/// «Список тегов» появляется только если у сайта реально есть алфавитный
/// справочник (capabilities.hasTagBrowser), «Поиск» — если есть свободный
/// поиск (capabilities.hasSearch). Ни один пункт не ведёт ни во что
/// связанное с MangaLib.
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
