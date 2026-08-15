import SwiftUI

/// Корень приложения — снова самодельная SwiftUI-панель (не системный
/// UITabBarController).
///
/// ИСТОРИЯ: раньше здесь была ровно такая же панель. Затем мигрировали на
/// настоящий `UITabBarController` (см. `TabBarController.swift`, теперь
/// неиспользуемый — см. комментарий там) ради системного Liquid Glass "из
/// коробки". Но кнопка аватарки рядом с таббаром там требовала вручную
/// ужимать `tabBar.frame` — а видимая плавающая капсула нового стиля iOS 26,
/// похоже, рисуется отдельным системным слоем и/или переигрывается системой
/// уже ПОСЛЕ нашей записи (внутренние анимации сворачивания и т.п.), из-за
/// чего аватарка регулярно "отклеивалась" от реальной панели — семь попыток
/// подряд не дали стабильного результата, потому что мы боролись с
/// недокументированным приватным поведением системного компонента.
///
/// Здесь — обычный SwiftUI `HStack` (капсула таббара + отдельный кружок
/// аватарки рядом), где расположение полностью в наших руках, без каких-либо
/// системных сюрпризов.
struct RootView: View {

    @State private var tab = 1 // Каталог выбран по умолчанию
    @State private var showLogin = false
    @State private var showAccount = false
    @State private var stubRequest: StubRequest?

    // Для всплывающего тоста «Загрузка начата» и т.п. (см. DownloadsManager.banner).
    @ObservedObject private var downloads = DownloadsManager.shared
    // Запрос «открыть каталог по жанру/тегу» из карточки тайтла (см. CatalogNavigator).
    @ObservedObject private var catalogNav = CatalogNavigator.shared

    // Высота панели + отступ от низа — те же числа, что уже "зашиты" в
    // .safeAreaInset(edge: .bottom) внутри MangaCatalogView/BookmarksView
    // (см. комментарии там: "84 = высота панели"). Резервируем именно эту
    // зону снаружи, чтобы контент не оказывался под панелью.
    private let tabBarHeight: CGFloat = 64
    private let tabBarBottomMargin: CGFloat = 20

    private let tabs: [(icon: String, label: String)] = [
        ("bookmark", "Закладки"),
        ("magnifyingglass", "Каталог"),
        ("bell", "Уведомления"),
        ("line.3.horizontal", "Меню")
    ]

    var body: some View {
        screen
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: tabBarHeight + tabBarBottomMargin)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    FloatingTabBar(tabs: tabs, height: tabBarHeight, selection: $tab)
                    AvatarButton {
                        if AuthSession.shared.isLoggedIn {
                            showAccount = true
                        } else {
                            showLogin = true
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, tabBarBottomMargin)
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

    @ViewBuilder
    private var screen: some View {
        switch tab {
        case 0:
            BookmarksView()
        case 1:
            MangaCatalogView()
        case 2:
            NotificationsView()
        default:
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

/// Плавающая капсула с 4 вкладками — тот же `.glassEffect`, что используется
/// по всему приложению (нижняя панель ридера, Фильтры/Сортировка в
/// каталоге и т.д.), а не `.ultraThinMaterial` — для визуальной
/// согласованности со всеми остальными стеклянными элементами.
///
/// Раньше здесь стоял `LiquidGlassTabBar` (эффект "жидкой капли" через
/// Canvas/metaball, см. `LiquidGlassTabBar.swift` — теперь неиспользуемый)
/// — попросили вернуть как было, без эффекта.
private struct FloatingTabBar: View {
    let tabs: [(icon: String, label: String)]
    let height: CGFloat
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { index in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = index
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tabs[index].icon)
                            .font(.system(size: 21))
                        Text(tabs[index].label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(index == selection ? Theme.accent : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: height)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Кнопка аватарки — та же логика отрисовки (реальное фото профиля или
/// плейсхолдер), что раньше жила в `TabBarController.ProfileAccessoryView`,
/// перенесена сюда один в один.
private struct AvatarButton: View {
    @ObservedObject private var auth = AuthSession.shared
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let avatarURL = auth.avatarURL {
                    RemoteImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var placeholder: some View {
        Circle()
            .fill(Theme.surfaceElevated)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
            )
    }
}

#Preview {
    RootView()
}
