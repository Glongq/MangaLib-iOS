import SwiftUI

/// Native tab navigation. External discovery occupies the Reading tab in external mode.
struct RootView: View {

    // Reading is the user's requested launch tab.
    @State private var tab = 2
    @State private var showLogin = false
    @State private var showAccount = false
    @State private var stubRequest: StubRequest?

    // Shared download notifications are displayed above the active tab.
    @ObservedObject private var downloads = DownloadsManager.shared
    // Catalog navigation requests originate from title and menu screens.
    @ObservedObject private var catalogNav = CatalogNavigator.shared
    // System controls follow changes to the app's preferred theme.
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var externalSites = ExternalSiteSession.shared

    var body: some View {
        TabView(selection: $tab) {
            Tab("Закладки", systemImage: "bookmark", value: 0) {
                BookmarksView()
            }
            Tab("Каталог", systemImage: "magnifyingglass", value: 1) {
                MangaCatalogView()
            }
            Tab("Читают", systemImage: "book", value: 2) {
                if externalSites.isExternalModeActive {
                    ExternalRecommendationFeedView(onBack: { tab = 4 })
                } else {
                    HomeView()
                }
            }
            Tab("Новое", systemImage: "bell", value: 3) {
                NotificationsView()
            }
            Tab("Меню", systemImage: "line.3.horizontal", value: 4) {
                SideMenuView(
                    onSelect: { title in stubRequest = StubRequest(title: title) },
                    onOpenLogin: { showLogin = true },
                    onOpenAccount: { showAccount = true },
                    onOpenCatalog: { typeId in
                        // Apply the selected type before switching to the catalog.
                        CatalogNavigator.shared.pendingTypeId = typeId
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 1 }
                    }
                )
            }
        }
        // Keep all five tabs expanded instead of collapsing them to one side.
        .tabBarMinimizeBehavior(.never)
        // Present the shared toast above the active screen.
        .overlay(alignment: .top) {
            if let banner = downloads.banner {
                DownloadToast(text: banner.text)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: downloads.banner)
        // The catalog applies pending genre/tag filters when it appears.
        .onChange(of: catalogNav.switchRequest) { _, req in
            if req != nil { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 1 } }
        }
        .onChange(of: catalogNav.openBookmarksRequest) { _, req in
            if req != nil {
                showAccount = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 0 }
            }
        }
        .preferredColorScheme((tab == 2 && externalSites.isExternalModeActive) || themeManager.isDarkTheme ? .dark : .light)
        .tint(Theme.accent)
        .sheet(isPresented: $showLogin) { LoginView() }
        .sheet(isPresented: $showAccount) { AccountInfoView() }
        .sheet(item: $stubRequest) { request in
            NavigationStack { StubView(title: request.title) }
        }
    }
}

private struct StubRequest: Identifiable {
    let id = UUID()
    let title: String
}

/// Shared glass toast; its presentation animation belongs to RootView.
private struct DownloadToast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

#Preview {
    RootView()
}
