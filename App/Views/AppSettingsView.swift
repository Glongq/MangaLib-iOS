import SwiftUI

/// Версия приложения для отображения в настройках.
///
/// Берём CFBundleShortVersionString из Info.plist (заполняется автоматически
/// из MARKETING_VERSION в project.yml, см. GENERATE_INFOPLIST_FILE: YES) —
/// единый источник правды, чтобы номер версии на экране и в самой сборке
/// никогда не расходились.
///
/// Формат отображения — "beta-version X.Y.Z" (по просьбе): первую (мажорную)
/// цифру НЕ трогать, пока приложение реально не готово к первому релизу
/// (0 = всё ещё бета) — она станет 1 только на настоящем релизе 1.0. Второе
/// и третье число (minor/patch) обновлять по мере выхода новых версий —
/// т.е. при следующих сколько-нибудь заметных раундах правок стоит бампнуть
/// MARKETING_VERSION в project.yml (например 0.1.0 → 0.2.0).
enum AppVersionInfo {
    static var raw: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    static var display: String { "beta-version \(raw)" }
}

/// Экран настроек — реальный, вместо прежней generic-заглушки StubView.
/// Минимальный набор для старта: версия приложения + активный сайт +
/// короткое "о приложении". Дальше можно добавлять реальные настройки
/// (тема, уведомления и т.д.) сюда же, по мере появления.
struct AppSettingsView: View {
    /// true — экран открыт PUSH-переходом внутри вкладки «Меню» (свой
    /// NavigationStack не нужен, «Готово» убираем — есть системная «назад»).
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var siteSession = SiteSession.shared
    @ObservedObject private var authSession = AuthSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var specialFilterStore = SpecialFilterStore.shared
    @State private var debugTokenInput = ""
    /// Фокус поля Bearer-токена (см. debugAuthCard) — только чтобы понять,
    /// что клавиатура открыта, и свернуть её тапом по пустому месту экрана
    /// (см. content.onTapGesture), по аналогии с MangaDetailView.
    @FocusState private var debugTokenFocused: Bool
    @State private var showLogoutConfirm = false
    // Сворачиваемые разделы ("Профиль"/"Приложение"/"Помощь"/"Прочее") — та же
    // система, что и в боковом меню (см. SideMenuView.expandedSections). По
    // умолчанию все развёрнуты.
    @State private var expandedSections: Set<String> = ["Профиль", "Приложение", "Помощь", "Прочее"]

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                // 20→40 — вдвое больше отступ между карточками-разделами, по
                // прямой просьбе (тот же принцип, что и в SideMenuView).
                VStack(spacing: 40) {
                    card {
                        infoRow(title: "Версия", value: AppVersionInfo.display)
                        infoRow(title: "Активный сайт", value: siteSession.activeSite.displayName, showDivider: false)
                    }

                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("О приложении")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Неофициальный клиент экосистемы MangaLib. Приложение находится в активной разработке — часть разделов и функций ещё дорабатывается.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(16)
                    }

                    // Пункты ниже — ПОЛНОЦЕННЫЙ пункт меню с переходом внутрь,
                    // но сам раздел внутри пока заглушка (StubView, тот же
                    // приём, что и у остальных ещё не реализованных разделов
                    // приложения) — реальное наполнение добавим по мере
                    // готовности. Единственное исключение — "Выход из
                    // аккаунта" ниже: он настоящий, реально разлогинивает.
                    settingsSection("Профиль") {
                        profileInfoRow
                        settingsRow(icon: "bell", title: "Уведомления")
                        settingsRow(icon: "eye.slash", title: "Игнор-лист")
                        settingsRow(icon: "lock.shield", title: "Безопасность и вход")
                        settingsRow(icon: "slider.horizontal.3", title: "Фильтр контента")
                        settingsRow(icon: "hand.raised", title: "Приватность")
                        settingsRow(icon: "creditcard", title: "Платежи", showDivider: false)
                    }

                    settingsSection("Приложение") {
                        storageSettingsRow
                        personalizationRow
                        specialFilterRow
                        settingsRow(icon: "arrow.triangle.2.circlepath", title: "Проверить обновления", showDivider: false)
                    }

                    settingsSection("Помощь") {
                        settingsRow(icon: "questionmark.circle", title: "Вопросы и ответы")
                        settingsRow(icon: "envelope", title: "Обратная связь")
                        settingsRow(icon: "doc.text", title: "Пользовательское соглашение", showDivider: false)
                    }

                    settingsSection("Прочее") {
                        settingsRow(icon: "flask", title: "Стать тестировщиком")
                        settingsRow(icon: "ladybug", title: "Сообщить об ошибке", showDivider: false)
                    }

                    // Отдельная красная плашка, а не строка внутри "Прочее" —
                    // по прямой просьбе. Показывается только если реально
                    // залогинены (выходить не из чего иначе). Настоящее
                    // действие (не заглушка) — тот же authSession.logout(),
                    // что и в AccountInfoView, с подтверждением (необратимое
                    // без повторного входа действие).
                    if authSession.isLoggedIn {
                        logoutRow
                    }

                    debugAuthCard
                    debugNetworkLogsCard

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
                // Тап по пустому месту — свернуть клавиатуру, если сейчас
                // вводим debug-токен (см. debugAuthCard/debugTokenFocused).
                .contentShape(Rectangle())
                .onTapGesture {
                    if debugTokenFocused { debugTokenFocused = false }
                }
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        // Жест «назад» из левой половины на pushed-экране.
        .background { if embedded { InteractivePopGesture() } }
    }

    // Радиус — тот же, что и у карточек в разделе "Меню" (см.
    // SideMenuView.cardCornerRadius) — это эталон, под него выравниваем.
    private static let cardCornerRadius: CGFloat = 24

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
    }

    /// Сворачиваемая группа пунктов ("Профиль"/"Приложение"/"Помощь"/"Прочее")
    /// — та же система, что и в боковом меню (см. SideMenuView.collapsibleCard/
    /// sectionHeader): заголовок с стрелкой вверх/вниз внутри самой card, а
    /// не отдельной подписью над ней, по прямой просьбе сделать одинаково.
    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        let expanded = expandedSections.contains(title)
        return card {
            sectionHeader(title, expanded: expanded)
            if expanded {
                sectionDivider
                content()
            }
        }
    }

    private func sectionHeader(_ title: String, expanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expanded { expandedSections.remove(title) } else { expandedSections.insert(title) }
            }
        } label: {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sectionDivider: some View {
        Divider().overlay(Theme.separator).padding(.horizontal, 16)
    }

    /// Один пункт настроек — переход внутрь пока ведёт на StubView (тот же
    /// приём, что и у остальных ещё не реализованных разделов приложения,
    /// см. RootView.stubRequest/SideMenuView) — заменим на реальный экран,
    /// когда раздел будет готов. Размер/цвет иконки, отступы и текст — как у
    /// row() в SideMenuView (иконка вторичного цвета, без акцента — акцент
    /// там используется только для реально активных/выбранных состояний).
    private func settingsRow(icon: String, title: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                StubView(title: title)
            } label: {
                settingsRowLabel(icon: icon, title: title)
            }
            .buttonStyle(.plain)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14)
            }
        }
    }

    /// "Информация" — реальный экран (ProfileInfoEditView), а не StubView:
    /// аватар/ник/пол/о себе, PATCH-эндпоинт профиля подтверждён перехватом.
    private var profileInfoRow: some View {
        VStack(spacing: 0) {
            NavigationLink {
                ProfileInfoEditView()
            } label: {
                settingsRowLabel(icon: "info.circle", title: "Информация")
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14)
        }
    }

    /// "Данные и память" — единственный пункт из этого раздела с реальным
    /// экраном (StorageSettingsView), а не StubView — та же вёрстка строки,
    /// что и у settingsRow(), но с переходом на конкретный тип вместо общего.
    private var storageSettingsRow: some View {
        VStack(spacing: 0) {
            NavigationLink {
                StorageSettingsView()
            } label: {
                settingsRowLabel(icon: "internaldrive", title: "Данные и память")
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14)
        }
    }

    /// "Персонализация" — реальный экран с переехавшим сюда тумблером тёмной
    /// темы (остальное наполнение экрана — позже).
    private var personalizationRow: some View {
        VStack(spacing: 0) {
            NavigationLink {
                PersonalizationSettingsView()
            } label: {
                settingsRowLabel(icon: "paintbrush", title: "Персонализация")
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14)
        }
    }

    /// "Спец фильтр" — реальный экран (SpecialFilterSettingsView), с "Вкл"
    /// справа вместо привычной стрелки, когда флаг включён (сам выбор
    /// жанров/тегов — по-прежнему в Фильтрах каталога, см.
    /// SpecialFilterStore), чтобы не забыть, что каталог сейчас может
    /// работать не как обычно.
    private var specialFilterRow: some View {
        VStack(spacing: 0) {
            NavigationLink {
                SpecialFilterSettingsView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                    Text("Спец фильтр").foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if specialFilterStore.isEnabled {
                        Text("Вкл")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14)
        }
    }

    /// Содержимое строки пункта настроек — вынесено отдельно, чтобы обычные
    /// (StubView) и особые (StorageSettingsView/PersonalizationSettingsView)
    /// пункты выглядели гарантированно идентично.
    private func settingsRowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    /// "Выход из аккаунта" — ОТДЕЛЬНАЯ красная плашка (не строка внутри
    /// "Прочее"), по прямой просьбе. Настоящее действие, не заглушка — тот
    /// же authSession.logout(), что и в AccountInfoView.actions, но с
    /// подтверждением (необратимо без повторного входа).
    private var logoutRow: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.title3)
                    .frame(width: 24)
                Text("Выход из аккаунта")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
        .confirmationDialog("Выйти из аккаунта?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Выйти из аккаунта", role: .destructive) { authSession.logout() }
            Button("Отмена", role: .cancel) {}
        }
    }

    /// ВРЕМЕННЫЙ debug-инструмент (по просьбе, на время тестирования) — вставить
    /// свой Bearer-токен вручную вместо входа через WebView (см. LoginWebView),
    /// чтобы не логиниться заново при каждой новой тестовой сборке. Специально
    /// сделан МАКСИМАЛЬНО безопасно: под капотом вызывает ТОТ ЖЕ
    /// AuthSession.login(token:username:), что и обычный вход через WebView —
    /// то есть не заводит отдельный, параллельный путь авторизации, который
    /// мог бы разойтись с основным и что-то сломать, а просто даёт токену
    /// другой источник. Убрать перед релизом (см. просьбу — "в финале удалим").
    private var debugAuthCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Debug: вход по токену")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Временно, только для тестирования — вставь Bearer-токен вручную вместо входа через WebView. Уберём перед релизом.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if authSession.isLoggedIn {
                    Text("Уже авторизован: \(authSession.username ?? "—")")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                TextField("", text: $debugTokenInput,
                          prompt: Text("Вставить токен").foregroundColor(Theme.textSecondary))
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($debugTokenFocused)

                let trimmed = debugTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                Button {
                    guard !trimmed.isEmpty else { return }
                    AuthSession.shared.login(token: trimmed, username: nil)
                    debugTokenInput = ""
                    debugTokenFocused = false
                } label: {
                    Text("Войти по токену").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(trimmed.isEmpty)
            }
            .padding(16)
        }
    }

    /// ВРЕМЕННЫЙ debug-инструмент (по просьбе) — вход в живой журнал ВСЕХ
    /// сетевых запросов приложения (см. NetworkLogsView.swift/NetworkLogger.swift).
    /// Убрать перед релизом вместе с debugAuthCard выше.
    private var debugNetworkLogsCard: some View {
        NavigationLink {
            NetworkLogsView()
        } label: {
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Логи сети (debug)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Все запросы/ответы приложения, с фильтром по ошибкам")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
            }
        }
        .buttonStyle(.plain)
    }

    private func infoRow(title: String, value: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(value).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.horizontal, 16)
            }
        }
    }
}

#Preview {
    AppSettingsView()
        .preferredColorScheme(.dark)
}
