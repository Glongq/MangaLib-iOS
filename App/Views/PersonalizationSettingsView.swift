import SwiftUI

/// "Персонализация" — по прямой просьбе сюда переехал тумблер тёмной темы
/// (раньше жил прямо в AppSettingsView отдельной карточкой). Остальное
/// наполнение экрана — позже, пока это единственный реальный пункт здесь.
struct PersonalizationSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
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
                        .frame(minHeight: 52)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Персонализация")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Радиус — тот же, что и у карточек в разделе "Меню" (см.
    // SideMenuView.cardCornerRadius) — это эталон, под него выравниваем.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    NavigationStack { PersonalizationSettingsView() }
        .preferredColorScheme(.dark)
}
