import SwiftUI

/// Вкладка «Читают» — теперь настоящая главная лента приложения (раньше
/// была заглушкой StubView, см. историю в RootView), собранная по образцу
/// главной страницы сайта: продолжить читать, сейчас читают (с подвкладками
/// и периодом), коллекции, топ активных недели, новинки, последние
/// обновления. Один сплошной вертикальный ScrollView — каждая секция сама
/// решает, показываться ли (пустая секция просто не рендерится), а
/// «Последние обновления» внизу подгружает страницы по мере скролла
/// (см. HomeViewModel.loadMoreUpdatesIfNeeded), как попросили — "беск вниз
/// листать можно".
///
/// ВАЖНО про данные: «Продолжить читать» и «Последние обновления» стоят на
/// подтверждённых, уже используемых эндпоинтах (история/закладки, каталог с
/// sort=updated/added, уведомления). «Сейчас читают» — на подтверждённом
/// пути `/media/top-views`, но параметры вкладок/периода — догадка (см.
/// MangaNetworkService.fetchTopViews). «Коллекции»/«Топ активных недели» —
/// на НЕподтверждённом пути (см. fetchHomeWidgets) и тихо не показываются,
/// если сервер не ответит 200.
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var bookmarks = BookmarksStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MangaItem.self) { item in
                MangaDetailView(slug: item.apiSlug, fallbackTitle: item.displayTitle,
                                 coverURL: item.cover?.bestURL, item: item)
            }
            .navigationDestination(for: HistoryEntry.self) { entry in
                MangaDetailView(slug: entry.media.apiSlug, fallbackTitle: entry.media.displayTitle,
                                 coverURL: entry.media.cover?.bestURL, item: entry.media)
            }
            .navigationDestination(for: NotificationItem.self) { note in
                if let media = note.media {
                    MangaDetailView(slug: media.apiSlug, fallbackTitle: media.displayTitle,
                                     coverURL: media.cover?.bestURL, item: media)
                }
            }
        }
        .task {
            viewModel.loadInitialIfNeeded()
            // «Читают» теперь открывается первой вкладкой при запуске — не
            // полагаемся только на параллельный AuthSession.syncAccountData()
            // при холодном старте (см. BookmarksView/HistoryView.task, тот же приём).
            await bookmarks.syncHistoryFromServer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await viewModel.refresh() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.didLoadOnce {
            ProgressView().tint(Theme.accent)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    quickSearchBar
                    continueReadingSection
                    currentlyReadingSection
                    collectionsSection
                    topActiveUsersSection
                    newestSection
                    updatesSection
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await viewModel.refresh() }
        }
    }

    // MARK: Быстрый поиск

    /// Тапом уходим на вкладку «Каталог» (там и живёт реальный поиск, см.
    /// MangaCatalogView) — тот же мост, что уже используют жанры/теги из
    /// карточки тайтла (см. CatalogNavigator.switchRequest в RootView).
    private var quickSearchBar: some View {
        Button {
            CatalogNavigator.shared.openCatalog(filter: MangaFilter())
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                Text("Быстрый поиск").foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: Продолжить читать

    @ViewBuilder
    private var continueReadingSection: some View {
        let entries = bookmarks.continueReadingEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Продолжить читать")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(entries) { entry in
                            NavigationLink(value: entry) { continueReadingCard(entry) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func continueReadingCard(_ entry: HistoryEntry) -> some View {
        let progress = bookmarks.readingProgress(forSlug: entry.media.apiSlug)
        return HStack(spacing: 10) {
            RemoteImage(url: entry.media.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 56, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.media.displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text("Глава \(entry.item.number)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                progressBar(fraction: progressFraction(progress))
                    .frame(maxWidth: .infinity)
                    .frame(height: 4)
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func progressFraction(_ progress: ReadingProgress?) -> Double? {
        guard let progress, progress.totalChapters > 0 else { return nil }
        return min(1, max(0, Double(progress.readCount) / Double(progress.totalChapters)))
    }

    private func progressBar(fraction: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceElevated)
                Capsule().fill(Theme.accent)
                    .frame(width: geo.size.width * CGFloat(fraction ?? 0))
            }
        }
    }

    // MARK: Сейчас читают

    @ViewBuilder
    private var currentlyReadingSection: some View {
        if !viewModel.currentlyReading.isEmpty || viewModel.isLoadingCurrentlyReading {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionHeader("Сейчас читают")
                    Spacer(minLength: 0)
                    periodMenu
                }
                .padding(.horizontal, 16)

                sortTabs
                    .padding(.horizontal, 16)

                if viewModel.currentlyReading.isEmpty && viewModel.isLoadingCurrentlyReading {
                    ProgressView().tint(Theme.accent).frame(height: 190)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(viewModel.currentlyReading) { item in
                                NavigationLink(value: item) {
                                    MangaCardView(item: item, width: 108)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private var sortTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(TopViewsSort.allCases) { sort in
                    Button {
                        viewModel.currentlyReadingSort = sort
                    } label: {
                        Text(sort.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(sort == viewModel.currentlyReadingSort ? Theme.background : Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(
                                sort == viewModel.currentlyReadingSort ? Theme.accent : Theme.surfaceElevated,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var periodMenu: some View {
        Menu {
            Picker("Период", selection: $viewModel.currentlyReadingPeriod) {
                ForEach(TopViewsPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.currentlyReadingPeriod.title)
                Image(systemName: "chevron.down")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

    // MARK: Последние коллекции

    @ViewBuilder
    private var collectionsSection: some View {
        if !viewModel.collections.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Последние коллекции")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.collections) { collection in
                            collectionCard(collection)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func collectionCard(_ collection: MangaCollection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(collection.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            HStack(spacing: 14) {
                if let views = collection.views { statLabel(icon: "eye", value: views) }
                if let itemsCount = collection.itemsCount { statLabel(icon: "square.stack", value: itemsCount) }
                if let favoritesCount = collection.favoritesCount { statLabel(icon: "bookmark", value: favoritesCount) }
            }
            if let votes = collection.votes {
                statLabel(icon: "star.fill", value: votes.up, secondary: votes.down)
            }

            collectionPreviewStack(collection.previews ?? [])
        }
        .padding(14)
        .frame(width: 220)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statLabel(icon: String, value: Int, secondary: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(secondary.map { "\(value)/\($0)" } ?? "\(value)")
                .font(.caption2)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    /// Три обложки веером, как на сайте — каждая следующая чуть смещена
    /// вправо/вниз и повёрнута на пару градусов.
    private func collectionPreviewStack(_ previews: [MangaCover]) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(previews.prefix(3).enumerated()), id: \.offset) { index, cover in
                RemoteImage(url: cover.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    Theme.surfaceElevated
                }
                .frame(width: 60, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .rotationEffect(.degrees(Double(index) * 4 - 4))
                .offset(x: CGFloat(index) * 26)
                .clipped()
            }
        }
        .frame(height: 84, alignment: .leading)
    }

    // MARK: Топ активных недели

    @ViewBuilder
    private var topActiveUsersSection: some View {
        if !viewModel.topActiveUsers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Топ активных недели")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(viewModel.topActiveUsers.enumerated()), id: \.element.id) { index, user in
                            topActiveUserCard(user, rank: index + 1)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func topActiveUserCard(_ user: TopActiveUser, rank: Int) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: user.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .clipped()
            .overlay(alignment: .topLeading) {
                Text("\(rank)#")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .offset(x: -4, y: -4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(user.username)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let points = user.pointsInfo {
                    Text("Уровень \(points.level)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    progressBar(fraction: points.maxLevelPoints > 0
                                ? Double(points.currentLevelPoints) / Double(points.maxLevelPoints) : nil)
                        .frame(width: 90, height: 4)
                }
            }
        }
        .padding(10)
        .frame(width: 210)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Новинки

    @ViewBuilder
    private var newestSection: some View {
        if !viewModel.newest.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Новинки")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(viewModel.newest) { item in
                            NavigationLink(value: item) {
                                MangaCardView(item: item, width: 108)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Последние обновления

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Последние обновления")
                .padding(.horizontal, 16)

            Picker("", selection: $viewModel.updatesTab) {
                ForEach(HomeUpdatesTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            LazyVStack(spacing: 10) {
                switch viewModel.updatesTab {
                case .all:
                    ForEach(viewModel.updates) { item in
                        NavigationLink(value: item) { updateRow(item) }
                            .buttonStyle(.plain)
                            .onAppear { viewModel.loadMoreUpdatesIfNeeded(currentId: item.id) }
                    }
                case .mine:
                    ForEach(viewModel.myUpdates) { note in
                        NavigationLink(value: note) { updateRow(note) }
                            .buttonStyle(.plain)
                            .onAppear { viewModel.loadMoreUpdatesIfNeeded(currentId: note.id) }
                    }
                }
                if viewModel.isLoadingMoreUpdates {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func updateRow(_ item: MangaItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(chapterLine(for: item))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let date = item.lastItemDate {
                Text(date.relativeRussianString)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func chapterLine(for item: MangaItem) -> String {
        guard let chapter = item.latestChapter else { return item.type?.label ?? "" }
        var parts: [String] = []
        if let volume = chapter.volume, !volume.isEmpty { parts.append("Том \(volume)") }
        if let number = chapter.number, !number.isEmpty { parts.append("Глава \(number)") }
        var line = parts.joined(separator: " ")
        if item.extraLatestChaptersCount > 0 {
            line += " + ещё \(item.extraLatestChaptersCount)"
        }
        return line.isEmpty ? (item.type?.label ?? "") : line
    }

    private func updateRow(_ note: NotificationItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: note.media?.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(note.media?.displayTitle ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(note.displayText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(note.createdAt.relativeRussianString)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Общее

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

#Preview {
    HomeView().preferredColorScheme(.dark)
}
