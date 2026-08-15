import SwiftUI

/// Профиль пользователя: сзади баннер (background), слева-сверху аватар в виде
/// обложки (как на карточке тайтла), справа на баннере — статистика (создано
/// тайтлов / загружено глав / кол-во комментариев). Ниже — имя, уровень и
/// действия аккаунта. Данные: GET /user/{id} и /user/{id}/stats.
struct AccountInfoView: View {
    @ObservedObject private var auth = AuthSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var profile: UserProfile?
    @State private var stats: UserStats?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile?.username ?? auth.username ?? "Аккаунт MangaLib")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            HStack(spacing: 10) {
                                if let lvl = profile?.level {
                                    Text("Уровень \(lvl)")
                                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                                if let g = profile?.genderLabel, !g.isEmpty {
                                    Text("· \(g)")
                                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        if let about = profile?.about, !about.isEmpty {
                            Text(about)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                        }

                        actions
                            .padding(.top, 24)
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }.tint(Theme.accent)
                }
            }
            .task(id: auth.userId) { await load() }
        }
    }

    // MARK: Шапка (баннер + аватар + статистика)

    private var header: some View {
        ZStack(alignment: .topLeading) {
            // Баннер.
            RemoteImage(url: profile?.backgroundURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Theme.surfaceElevated
            } failure: {
                Theme.surfaceElevated
            }
            .frame(height: 184)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            )

            // Статистика справа на баннере.
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    statLine("Создано тайтлов", stats?.mangaCreated)
                    statLine("Загружено глав", stats?.chaptersUploaded)
                    statLine("Кол-во комментариев", stats?.comments)
                }
                .padding(.top, 14)
                .padding(.trailing, 14)
            }

            // Аватар слева-сверху как обложка тайтла.
            RemoteImage(url: profile?.avatarURL ?? auth.avatarURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                avatarPlaceholder
            } failure: {
                avatarPlaceholder
            }
            .frame(width: 92, height: 122)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .padding(.leading, 16)
            .padding(.top, 16)
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Theme.surfaceElevated
            Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(Theme.textSecondary)
        }
    }

    private func statLine(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Text(value.map { "\($0)" } ?? "—")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    // MARK: Действия

    private var actions: some View {
        VStack(spacing: 14) {
            // ВРЕМЕННЫЙ debug-доступ к логам сети (как было) — убрать перед релизом.
            NavigationLink {
                NetworkLogsView()
            } label: {
                Text("Логи сети (debug)")
                    .font(.headline).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .glassEffect(.regular.interactive(), in: Capsule())

            Button {
                auth.logout()
                dismiss()
            } label: {
                Text("Выйти")
                    .font(.headline).foregroundStyle(.red)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.horizontal, 40)
    }

    private func load() async {
        guard let id = auth.userId else { return }
        async let p = try? MangaNetworkService.shared.fetchUserProfile(id: id)
        async let s = try? MangaNetworkService.shared.fetchUserStats(id: id)
        let (prof, st) = await (p, s)
        if let prof { profile = prof }
        if let st { stats = st }
    }
}

#Preview {
    AccountInfoView()
        .preferredColorScheme(.dark)
}
