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
    @State private var debugTokenInput = ""

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
                VStack(spacing: 20) {
                    card {
                        infoRow(title: "Версия", value: AppVersionInfo.display)
                        infoRow(title: "Активный сайт", value: siteSession.activeSite.displayName, showDivider: false)
                    }

                    card {
                        Toggle(isOn: $themeManager.isDarkTheme) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Тёмная тема").foregroundStyle(Theme.textPrimary)
                                Text("Выключи для белой темы. Не влияет на тему читалки — она настраивается отдельно.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
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

                    debugAuthCard
                    debugNetworkLogsCard

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
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

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

                let trimmed = debugTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                Button {
                    guard !trimmed.isEmpty else { return }
                    AuthSession.shared.login(token: trimmed, username: nil)
                    debugTokenInput = ""
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
            .frame(minHeight: 48)

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
