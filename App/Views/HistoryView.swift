import SwiftUI

/// Экран «История»: НАСТОЯЩАЯ история чтения аккаунта —
/// `GET /user/chapters/history` (см. BookmarksStore.syncHistoryFromServer).
/// Дедуп по тайтлу — самая свежая запись сверху, сервер и так отдаёт от
/// новых к старым.
///
/// Шапка — НЕ общий бар: заголовок "История" отдельно плавает по центру в
/// своём стекле, кнопка закрытия — отдельный кружок слева, каждый в своём
/// материале (тот же принцип, что и в остальных экранах приложения). Поиск —
/// отдельное плавающее поле снизу, над главной панелью.
struct HistoryView: View {
    /// true — открыт PUSH-переходом внутри вкладки «Меню» (без своего
    /// NavigationStack; у экрана своя плавающая шапка с кнопкой «назад»).
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BookmarksStore.shared
    @ObservedObject private var siteSession = SiteSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Дедуп по media.id — сервер отдаёт КАЖДЫЙ просмотр главы отдельной
    /// записью, а не одну запись на тайтл (см. пример ответа в чате: два
    /// подряд идущих view_at для одного и того же тайтла, разные главы).
    ///
    /// Плюс фильтр по активному сайту: `/user/chapters/history` отдаёт
    /// историю на весь аккаунт разом, не только по активному Site-Id — если
    /// зайти на тайтл ДРУГОГО сайта через "Похожее"/"Связанное" (site
    /// активным при этом не переключается, см. MangaItem.site), прочитанная
    /// там глава всё равно попадала в общий список. media.site отсутствует
    /// только в очень старых кэшах — в этом случае запись не прячем.
    private var deduped: [HistoryEntry] {
        var seen = Set<Int>()
        return store.historyEntries.filter { entry in
            guard entry.media.site == nil || entry.media.site == siteSession.activeSite.rawValue else { return false }
            guard !seen.contains(entry.media.id) else { return false }
            seen.insert(entry.media.id)
            return true
        }
    }

    private var results: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deduped }
        return deduped.filter { $0.media.displayTitle.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .tint(Theme.accent)
        .task { await store.syncHistoryFromServer() }
    }

    private var content: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            list
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        // У экрана своя плавающая шапка — системный навбар скрываем всегда.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: HistoryEntry.self) { entry in
            MangaDetailView(slug: entry.media.apiSlug, fallbackTitle: entry.media.displayTitle,
                             coverURL: entry.media.cover?.bestURL, item: entry.media)
        }
        .background { if embedded { InteractivePopGesture() } }
    }

    // MARK: Шапка — заголовок и кнопка закрытия плавают раздельно

    private var header: some View {
        ZStack {
            // Без стекла под текстом — просто заголовок, ничем не подложенный.
            Text("История")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            HStack {
                // Стрелка назад вместо крестика — экран открывается ПОВЕРХ
                // меню (см. SideMenuView.showHistory), а не как отдельный
                // самостоятельный лист, так что "назад" точнее по смыслу, чем "закрыть".
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: Поиск (снизу, над главной панелью)

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("", text: $query,
                      prompt: Text("Поиск по названию").foregroundColor(Theme.textSecondary))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: Список

    @ViewBuilder
    private var list: some View {
        if store.isSyncingHistory && results.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "Пока пусто" : "Ничего не найдено",
                systemImage: "clock.arrow.circlepath",
                description: Text(query.isEmpty
                    ? (AuthSession.shared.isLoggedIn
                       ? "Здесь появятся тайтлы, которые вы уже начали читать."
                       : "Войдите в аккаунт, чтобы видеть историю чтения.")
                    : "Попробуйте другой запрос.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(results) { entry in
                        NavigationLink(value: entry) { row(entry) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.syncHistoryFromServer() }
        }
    }

    /// 1в1 как в Закладках/Новое (см. BookmarksView.row/NotificationsView.row)
    /// по прямой просьбе — тот же размер/соотношение/радиус обложки (эталон
    /// Каталога, 2:3/16, общая константа BookmarksView.bookmarkCoverWidth/
    /// Height), обложка вплотную к краю подложки (не по центру с отступом
    /// 10 со всех сторон, как было), тот же радиус подложки (16, было 18),
    /// тот же размер текста (.subheadline/.caption2, было
    /// .subheadline.weight(.medium)/.caption/.caption2 — крупнее и другой
    /// шрифт), центрирование по высоте вместо .padding(10) со всех сторон.
    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: entry.media.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: BookmarksView.bookmarkCoverWidth, height: BookmarksView.bookmarkCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.media.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text("Том \(entry.item.volume), Глава \(entry.item.number)")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                Text(Self.dateFormatter.string(from: entry.viewAt))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.trailing, 12)
        .frame(height: BookmarksView.bookmarkCoverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f
    }()
}

#Preview {
    HistoryView().preferredColorScheme(.dark)
}
