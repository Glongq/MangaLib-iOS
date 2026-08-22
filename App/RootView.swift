import SwiftUI

/// Корень приложения — настоящий системный SwiftUI `TabView` + `Tab` (не
/// UIKit `UITabBarController`, не самодельная капсула).
///
/// ИСТОРИЯ: сначала была самодельная SwiftUI-панель, имитирующая Liquid
/// Glass вручную (см. неиспользуемый `BottomBar.swift`). Потом попробовали
/// настоящий `UITabBarController` + `UITab` (см. неиспользуемый
/// `TabBarController.swift`) — сам таббар работал отлично, но кнопка
/// аватарки РЯДОМ с ним (акцессуар сбоку) — нет: семь техник ручной
/// подгонки frame/constraints не дали стабильного результата, боролись с
/// недокументированным поведением приватного системного слоя. Вернулись к
/// самодельному `HStack` (капсула + кружок аватарки рядом) как к компромиссу.
///
/// Теперь кнопку аватарки убрали из этой панели совсем (доступ к профилю —
/// через раздел «Меню», см. `SideMenuView`) — ровно та причина, из-за
/// которой в прошлый раз отказались от системного таббара, больше не
/// применима. Поэтому здесь снова настоящий системный компонент — чистый
/// SwiftUI `TabView`/`Tab` (доступен с iOS 18, автоматически получает
/// Liquid Glass на iOS 26 — деплоймент-таргет проекта и так уже 26.0 из-за
/// `.glassEffect`, используемого по всему приложению). Никаких вручную
/// подобранных отступов/высот — весь внешний вид, отступы от края экрана,
/// сворачивание при скролле и т.п. рисует сама система, ровно по HIG.
struct RootView: View {

    @State private var tab = 1 // Каталог выбран по умолчанию
    @State private var showLogin = false
    @State private var showAccount = false
    @State private var stubRequest: StubRequest?

    // Для всплывающего тоста «Загрузка начата» и т.п. (см. DownloadsManager.banner).
    @ObservedObject private var downloads = DownloadsManager.shared
    // Запрос «открыть каталог по жанру/тегу» из карточки тайтла (см. CatalogNavigator).
    @ObservedObject private var catalogNav = CatalogNavigator.shared

    var body: some View {
        TabView(selection: $tab) {
            Tab("Закладки", systemImage: "bookmark", value: 0) {
                BookmarksView()
            }
            Tab("Каталог", systemImage: "magnifyingglass", value: 1) {
                MangaCatalogView()
            }
            // Заглушка — раздел в разработке (см. StubView).
            Tab("Читают", systemImage: "book", value: 2) {
                NavigationStack { StubView(title: "Читают") }
            }
            Tab("Уведомления", systemImage: "bell", value: 3) {
                NotificationsView()
            }
            Tab("Меню", systemImage: "line.3.horizontal", value: 4) {
                SideMenuView(
                    onSelect: { title in stubRequest = StubRequest(title: title) },
                    onOpenLogin: { showLogin = true },
                    onOpenAccount: { showAccount = true },
                    onOpenCatalog: { typeId in
                        // Меню «Тайтлы» → тип: кладём фильтр и уходим на Каталог.
                        CatalogNavigator.shared.pendingTypeId = typeId
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 1 }
                    }
                )
            }
        }
        // Тост сверху: выезжает вниз из-под верхней кромки и уезжает обратно
        // вверх (transition .move(edge: .top)). Полупрозрачная стеклянная
        // подложка (glassEffect), как у остальных элементов приложения.
        .overlay(alignment: .top) {
            if let banner = downloads.banner {
                DownloadToast(text: banner.text)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: downloads.banner)
        // Тап по жанру/тегу в карточке → переключаемся на вкладку Каталог
        // (сам фильтр применяется в MangaCatalogView.onAppear).
        .onChange(of: catalogNav.switchRequest) { _, req in
            if req != nil { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 1 } }
        }
        .onChange(of: catalogNav.openBookmarksRequest) { _, req in
            if req != nil {
                showAccount = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 0 }
            }
        }
        .preferredColorScheme(.dark)
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

/// Небольшой тост со стеклянной полупрозрачной подложкой — короткий текст
/// вроде «Загрузка начата». Анимация появления/исчезновения задаётся снаружи
/// (см. RootView.overlay).
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
