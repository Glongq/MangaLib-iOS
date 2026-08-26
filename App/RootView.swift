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

    // «Читают» (см. HomeView) теперь открывается первой — по требованию:
    // "По дефолту оно будет теперь открываться первым при заходе".
    @State private var tab = 2
    @State private var showLogin = false
    @State private var showAccount = false
    @State private var stubRequest: StubRequest?

    // Для всплывающего тоста «Загрузка начата» и т.п. (см. DownloadsManager.banner).
    @ObservedObject private var downloads = DownloadsManager.shared
    // Запрос «открыть каталог по жанру/тегу» из карточки тайтла (см. CatalogNavigator).
    @ObservedObject private var catalogNav = CatalogNavigator.shared
    // Тёмная/белая тема всего приложения (настройка в AppSettingsView),
    // независима от темы читалки. Подписка здесь нужна для .preferredColorScheme
    // ниже — без неё системные элементы (клавиатура, алерты и т.п.) не
    // подхватили бы переключение темы.
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        TabView(selection: $tab) {
            Tab("Закладки", systemImage: "bookmark", value: 0) {
                BookmarksView()
            }
            Tab("Каталог", systemImage: "magnifyingglass", value: 1) {
                MangaCatalogView()
            }
            // Главная лента приложения (см. HomeView) — открывается первой.
            Tab("Читают", systemImage: "book", value: 2) {
                HomeView()
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
                        // Меню «Тайтлы» → тип: кладём фильтр и уходим на Каталог.
                        CatalogNavigator.shared.pendingTypeId = typeId
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = 1 }
                    }
                )
            }
        }
        // ЭКСПЕРИМЕНТ (был .never — см. ниже причину, по которой стоял):
        // проверяем гипотезу, что .never мешает большому заголовку
        // (.navigationBarTitleDisplayMode(.large)) нормально схлопываться на
        // iOS 26 внутри TabView — отсюда раздутый отступ сверху на Каталоге/
        // Закладках/Читают/Уведомлениях/Меню. Если гипотеза не
        // подтвердится — вернуть .never обратно.
        //
        // Была причина держать .never: по умолчанию (.automatic) iOS 26
        // сворачивает панель при скролле контента в маленькую капсулу с
        // ОДНОЙ активной вкладкой, прижатую к левому краю (см.
        // `tabBarMinimizeBehavior` в HIG/WWDC25) — из-за этого любая вкладка
        // при скролле "съезжала" влево вместо центра. Если старый баг
        // вернётся — это подтвердит, что .never был не лишним, и придётся
        // искать другой компромисс.
        .tabBarMinimizeBehavior(.automatic)
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
        .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
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
