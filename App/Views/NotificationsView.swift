import SwiftUI

/// Вкладка «Уведомления» — реальный `GET /notifications` (см.
/// NotificationsViewModel/MangaNetworkService.fetchNotifications).
///
/// Автообновление "при каждом заходе в приложение": `.task` при первом
/// появлении экрана (в т.ч. когда возвращаешься на эту вкладку — `screen` в
/// RootView пересобирает вьюху при каждом переключении таба, значит `.task`
/// отрабатывает заново) + `.onChange(of: scenePhase)` при возврате из фона,
/// пока вкладка уже открыта. Потянуть-обновить (долгий свайп вниз) — тот же
/// viewModel.refresh() через `.refreshable`.
struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    // Схлопывание кнопки сортировки при скролле вниз (вверх — хоть чуть-чуть
    // — возвращается). Заголовок теперь родной .navigationTitle/.large (см.
    // body) — как в Каталоге/Закладках — его эта логика больше не касается.
    @State private var headerCollapsed = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var isHeaderAnimating = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            // App Store-эталон (см. тот же приём в MangaCatalogView/
            // BookmarksView): крупный заголовок без фона в покое, системный
            // блюр проявляется при первом скролле, заголовок схлопывается в
            // маленький — целиком системное поведение, доп. кода не нужно.
            .navigationTitle("Уведомления")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MangaItem.self) { item in
                MangaDetailView(
                    slug: item.apiSlug, fallbackTitle: item.displayTitle,
                    coverURL: item.cover?.bestURL, item: item
                )
            }
            // Кнопка сортировки — снизу слева, над главной панелью. ВНУТРИ
            // NavigationStack (на корневом контенте) — иначе она остаётся на
            // экране поверх любого пуша (карточки тайтла из уведомления),
            // потому что технически была бы соседом стека, а не частью его
            // корневого экрана.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !headerCollapsed {
                    HStack {
                        filterButton
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.blurFade)
                }
            }
        }
        .tint(Theme.accent)
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await viewModel.refresh() }
            }
        }
    }

    // MARK: Шапка

    private func setHeaderCollapsed(_ value: Bool) {
        guard headerCollapsed != value else { return }
        isHeaderAnimating = true
        withAnimation(.easeInOut(duration: 0.22)) { headerCollapsed = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isHeaderAnimating = false }
    }

    /// Круглая кнопка сортировки/фильтра — раньше открывала
    /// NotificationFilterSheet (шторка снизу), теперь обычное системное
    /// глассовое `Menu` (тот же приём, что и Сортировка в Каталоге/
    /// Комментариях) — не отдельный экран, а нативный поповер.
    /// Бейдж — реальное число из GET /notifications/count (unread.all), не
    /// посчитано на клиенте.
    private var filterButton: some View {
        Menu {
            Picker("Прочитанность", selection: $viewModel.readFilter) {
                ForEach(NotificationReadFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Порядок", selection: $viewModel.sortOrder) {
                ForEach(NotificationSortOrder.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Категория", selection: $viewModel.typeFilter) {
                ForEach(NotificationTypeFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: Theme.pillControlHeight, height: Theme.pillControlHeight)

                if let unread = viewModel.counts?.unread.all, unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 6, y: -4)
                }
            }
        }
        .glassEffect(.regular.interactive(), in: Circle())
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage, viewModel.items.isEmpty {
            errorState(error)
        } else if viewModel.items.isEmpty && viewModel.isLoading {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.items.isEmpty && viewModel.hasLoadedOnce {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.items) { item in
                    row(item)
                        .onAppear {
                            guard item.id == viewModel.items.last?.id else { return }
                            Task { await viewModel.loadMoreIfNeeded(current: item) }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            // Запас снизу — чтобы последняя карточка не оказалась под
            // кнопкой сортировки/главной панелью (тот же приём, что и в
            // Закладках, см. комментарий там: 90→120).
            .padding(.bottom, 120)
        }
        // Тот же механизм схлопывания шапки, что в Каталоге/Закладках — см.
        // комментарии там же (в т.ч. про защиту isHeaderAnimating от дребезга).
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, newOffset in
            defer { lastScrollOffset = newOffset }
            guard !isHeaderAnimating else { return }
            let delta = newOffset - lastScrollOffset
            if newOffset <= 0 {
                setHeaderCollapsed(false)
            } else if delta > 6 {
                setHeaderCollapsed(true)
            } else if delta < -6 {
                setHeaderCollapsed(false)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await viewModel.refresh() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.readFilter == .unread ? "Нет новых уведомлений" : "Уведомлений нет",
            systemImage: "bell",
            description: Text("Здесь появятся новые главы, ответы и другие события.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Строка уведомления

    /// Размер подложки/обложки — тот же, что и в Закладках (см.
    /// BookmarksView.bookmarkCoverWidth/Height, единый источник, чтобы не
    /// разъехались) — по прямой просьбе "сделать таким же, как в закладках".
    /// Структура текста (3 строки: текст/команды/дата) не менялась —
    /// изменилось только выравнивание: HStack без alignment: .top (был
    /// прижат к верху) — теперь центрируется по высоте подложки, как и
    /// попросили ("выравнивание высоты к центру подложки").
    @ViewBuilder
    private func row(_ item: NotificationItem) -> some View {
        let core = HStack(spacing: 12) {
            RemoteImage(url: item.media?.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "bell.fill").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: BookmarksView.bookmarkCoverWidth, height: BookmarksView.bookmarkCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                // maxWidth: .infinity — иначе Text меряет себя по идеальной
                // ширине текста, а не по доступной ширине ряда, и справа
                // остаётся пустая "мёртвая зона" вместо переноса строк.
                Text(item.displayText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Команда(ы) перевода — "Армия 100 богинь", "ImageBoard Team,
                // ONIMAI.RU" и т.п. (см. NotificationItem.teamNames) —
                // подтверждённое реальным перехватом поле "teams".
                if !item.teamNames.isEmpty {
                    Text(item.teamNames)
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }

                Text(item.createdAt.relativeRussianString)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.trailing, 12)
        .frame(height: BookmarksView.bookmarkCoverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        if let media = item.media {
            NavigationLink(value: media) { core }
                .buttonStyle(.plain)
        } else {
            core
        }
    }
}

#Preview {
    NotificationsView()
        .preferredColorScheme(.dark)
}
