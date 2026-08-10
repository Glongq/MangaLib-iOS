import SwiftUI

/// Экран информации об аккаунте — открывается тапом по карточке профиля в
/// меню, когда пользователь уже вошёл. Минимальный: имя аккаунта + "Выйти".
/// Полноценный профиль (аватар с сайта, статистика и т.д.) — отдельная задача.
struct AccountInfoView: View {
    @ObservedObject private var auth = AuthSession.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    Circle()
                        .fill(Theme.surfaceElevated)
                        .frame(width: 84, height: 84)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.textSecondary)
                        )

                    Text(auth.username ?? "Аккаунт MangaLib")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)

                    // ВРЕМЕННЫЙ debug-дубликат кнопки из Настроек (по просьбе,
                    // для удобства — не нужно каждый раз идти в Настройки).
                    // Ведёт на тот же самый экран — см. NetworkLogsView.swift.
                    // Убрать вместе с остальными debug-инструментами перед релизом.
                    NavigationLink {
                        NetworkLogsView()
                    } label: {
                        Text("Логи сети (debug)")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.horizontal, 40)
                    .padding(.top, 12)

                    Button {
                        auth.logout()
                        dismiss()
                    } label: {
                        Text("Выйти")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.horizontal, 40)

                    Spacer()
                }
                .padding(.top, 60)
            }
            .navigationTitle("Аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AccountInfoView()
        .preferredColorScheme(.dark)
}
