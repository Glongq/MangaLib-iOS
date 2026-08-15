import SwiftUI

/// Обёртка над id пользователя для `.sheet(item:)` (открытие чужого профиля).
struct ProfileUserId: Identifiable { let id: Int }

/// Профиль пользователя (свой или чужого — по `userId`): баннер, аватар-обложка
/// слева-сверху, статистика справа (создано тайтлов / загружено глав / кол-во
/// комментариев). Ниже — отдельными подложками статистика по жанрам и по тегам
/// (горизонтальные цветные чипы, зависят от активного сайта через Site-Id) и
/// быстрые кнопки. Данные: GET /user/{id} и /user/{id}/stats.
struct ProfileView: View {
    /// nil — свой профиль (id берётся из AuthSession).
    let userId: Int?

    @ObservedObject private var auth = AuthSession.shared
    @ObservedObject private var site = SiteSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var profile: UserProfile?
    @State private var stats: UserStats?
    @State private var loadingProfile = false

    init(userId: Int? = nil) { self.userId = userId }

    private var resolvedId: Int? { userId ?? auth.userId }
    private var isSelf: Bool { let r = resolvedId; return r != nil && r == auth.userId }
    /// Ключ для перезагрузки статистики при смене профиля ИЛИ активного сайта.
    private var statsKey: String { "\(resolvedId ?? 0)-\(site.activeSite.rawValue)" }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()

                if let profile, !profile.canViewProfile {
                    closedState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            infoBlock

                            if profile?.canViewStatistics ?? true {
                                statsSection("Статистика по жанрам", stats?.genres ?? [])
                                statsSection("Статистика по тегам", stats?.tags ?? [])
                            }

                            quickButtons

                            if isSelf { actions }
                        }
                        .padding(.bottom, 40)
                    }
                    .scrollIndicators(.hidden)
                    // Баннер уходит в самый верх (под статус-бар), как hero на
                    // карточке тайтла.
                    .ignoresSafeArea(edges: .top)
                }

                // Своя кнопка «Готово» поверх баннера (навбар скрыт) —
                // остаётся в safe area, не заезжает под статус-бар.
                Button { dismiss() } label: {
                    Text("Готово")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14).frame(height: 36)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .padding(.leading, 16)
                .padding(.top, 4)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: resolvedId) { await loadProfile() }
        .task(id: statsKey) { await loadStats() }
    }

    // MARK: Закрытый профиль

    private var closedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text("Профиль закрыт").font(.headline).foregroundStyle(Theme.textPrimary)
            Text(profile?.username ?? "").font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
    }

    // MARK: Шапка (баннер + аватар + топ-статистика)

    private var header: some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(url: profile?.backgroundURL) { img in
                img.resizable().scaledToFill()
            } placeholder: { Theme.surfaceElevated } failure: { Theme.surfaceElevated }
            .frame(height: 184)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom))

            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    statLine("Создано тайтлов", stats?.mangaCreated)
                    statLine("Загружено глав", stats?.chaptersUploaded)
                    statLine("Кол-во комментариев", stats?.comments)
                }
                .padding(10)
                // Матовая подложка — чтобы статистика читалась поверх баннера.
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.trailing, 12)
                .padding(.top, 54)
            }

            RemoteImage(url: profile?.avatarURL ?? (isSelf ? auth.avatarURL : nil)) { img in
                img.resizable().scaledToFill()
            } placeholder: { avatarPlaceholder } failure: { avatarPlaceholder }
            .frame(width: 92, height: 122)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .padding(.leading, 16).padding(.top, 50)
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
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.85))
            Text(value.map { "\($0)" } ?? "—").font(.caption.weight(.bold)).foregroundStyle(.white)
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile?.username ?? (isSelf ? auth.username : nil) ?? "Профиль")
                .font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                if let lvl = profile?.level { Text("Уровень \(lvl)").font(.subheadline).foregroundStyle(Theme.textSecondary) }
                if let g = profile?.genderLabel, !g.isEmpty { Text("· \(g)").font(.subheadline).foregroundStyle(Theme.textSecondary) }
            }
            if let about = profile?.about, !about.isEmpty {
                Text(about).font(.subheadline).foregroundStyle(Theme.textPrimary).padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Статистика жанров/тегов (цветные чипы, горизонтально)

    @ViewBuilder
    private func statsSection(_ title: String, _ entries: [UserStatEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            statChip(e, color: Self.hueColor(i, entries.count))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func statChip(_ e: UserStatEntry, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(e.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(e.value)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(color, in: Capsule())
    }

    /// Цвет по индексу: тон идёт по кругу от красного (0) к сине-фиолетовому,
    /// так что соседние чипы отличаются буквально на пол-тона, а весь ряд —
    /// радуга в порядке тона.
    static func hueColor(_ index: Int, _ count: Int) -> Color {
        let t = count <= 1 ? 0 : Double(index) / Double(count - 1)
        let hue = t * 0.78            // 0 — красный, 0.78 — сине-фиолетовый
        return Color(hue: hue, saturation: 0.72, brightness: 0.82)
    }

    // MARK: Быстрые кнопки (каждая своей подложкой)

    private var quickButtons: some View {
        VStack(spacing: 10) {
            // «Списки тайтлов» — переход на вкладку Закладки, папка «Читаю»
            // (только для своего профиля; чужие списки недоступны).
            if isSelf {
                Button {
                    CatalogNavigator.shared.openBookmarks(folderId: BookmarkFolder.reading.id)
                    dismiss()
                } label: {
                    quickRow("Списки тайтлов", "square.stack.3d.up")
                }.buttonStyle(.plain)
            } else {
                NavigationLink { StubListView(title: "Списки тайтлов") } label: {
                    quickRow("Списки тайтлов", "square.stack.3d.up")
                }.buttonStyle(.plain)
            }

            NavigationLink { MyCommentsView(userId: resolvedId) } label: {
                quickRow("Комментарии", "text.bubble")
            }.buttonStyle(.plain)

            NavigationLink { StubListView(title: "Коллекции") } label: {
                quickRow("Коллекции", "square.stack")
            }.buttonStyle(.plain)

            NavigationLink { StubListView(title: "Друзья") } label: {
                quickRow("Друзья", "person.2")
            }.buttonStyle(.plain)

            NavigationLink { StubListView(title: "Избранное") } label: {
                quickRow("Избранное", "heart")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private func quickRow(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.accent).frame(width: 24)
            Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Действия (только свой профиль)

    private var actions: some View {
        VStack(spacing: 14) {
            NavigationLink { NetworkLogsView() } label: {
                Text("Логи сети (debug)")
                    .font(.headline).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .glassEffect(.regular.interactive(), in: Capsule())

            Button {
                auth.logout(); dismiss()
            } label: {
                Text("Выйти")
                    .font(.headline).foregroundStyle(.red)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
    }

    // MARK: Загрузка

    private func loadProfile() async {
        guard let id = resolvedId else { return }
        loadingProfile = true
        profile = try? await MangaNetworkService.shared.fetchUserProfile(id: id)
        loadingProfile = false
    }

    private func loadStats() async {
        guard let id = resolvedId else { return }
        stats = try? await MangaNetworkService.shared.fetchUserStats(id: id)
    }
}

/// Заглушка для ещё не реализованных разделов профиля.
private struct StubListView: View {
    let title: String
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "hammer").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                Text("«\(title)» скоро").font(.headline).foregroundStyle(Theme.textPrimary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Свой профиль (пункт меню) — тонкая обёртка над ProfileView.
struct AccountInfoView: View {
    var body: some View { ProfileView(userId: nil) }
}

#Preview {
    ProfileView(userId: nil).preferredColorScheme(.dark)
}
