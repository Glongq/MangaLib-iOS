import SwiftUI

/// Экран «История»: НАСТОЯЩАЯ история чтения аккаунта —
/// `GET /user/chapters/history` (см. BookmarksStore.syncHistoryFromServer).
/// Дедуп по тайтлу — самая свежая запись сверху, сервер и так отдаёт от
/// новых к старым.
///
/// Поиск — родной .searchable() сверху, как в Каталоге/Закладках (эталон —
/// MangaCatalogView/BookmarksView), а не отдельное плавающее поле снизу.
struct HistoryView: View {
    /// true — открыт PUSH-переходом внутри вкладки «Меню» (без своего
    /// NavigationStack; у экрана своя плавающая шапка с кнопкой «назад»).
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BookmarksStore.shared
    @ObservedObject private var siteSession = SiteSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query = ""

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
        // Родной системный заголовок + системный back chevron, никакого
        // своего кода (эталон — Настройки/Загрузки). embedded — push из
        // Меню (системная кнопка "назад" сама появляется); не embedded —
        // свой NavigationStack, нужен явный dismiss (тот же приём, что у
        // AppSettingsView/DownloadsView в их !embedded-режиме).
        .navigationTitle("История")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Поиск по названию")
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationDestination(for: HistoryEntry.self) { entry in
            MangaDetailView(slug: entry.media.apiSlug, fallbackTitle: entry.media.displayTitle,
                             coverURL: entry.media.cover?.bestURL, item: entry.media)
        }
        .background { if embedded { InteractivePopGesture() } }
    }

    // MARK: Список

    @ViewBuilder
    private var list: some View {
        if store.isSyncingHistory && results.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.isEmpty && !AuthSession.shared.isLoggedIn {
            // Раньше — та же ветка/иконка, что и у обычного "пока пусто" —
            // не сигналило, что дело именно в отсутствии входа, а не в том,
            // что истории правда ещё нет.
            StateView(icon: "person.crop.circle.badge.exclamationmark", title: "Войдите в аккаунт", description: "Чтобы видеть историю чтения.", fillScreen: true)
        } else if results.isEmpty {
            StateView(
                icon: "clock.arrow.circlepath",
                title: query.isEmpty ? "Пока пусто" : "Ничего не найдено",
                description: query.isEmpty ? "Здесь появятся тайтлы, которые вы уже начали читать." : "Попробуйте другой запрос.",
                fillScreen: true
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(results) { entry in
                        NavigationLink(value: entry) { row(entry) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(12)
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
