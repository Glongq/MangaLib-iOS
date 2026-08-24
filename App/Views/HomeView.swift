import SwiftUI
import UIKit

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
/// ВАЖНО про данные: «Продолжить читать», оба «Последних обновления» (Все/
/// Мои), «Сейчас читают» и теперь ТАКЖЕ «Коллекции»/«Топ активных недели» —
/// все на ПОДТВЕРЖДЁННЫХ реальным перехватом эндпоинтах (история/закладки,
/// каталог с sort=updated/added, /user-latest-updates, /media/top-views с
/// параметром `time`, и агрегат главной на корне API `/`, см.
/// MangaNetworkService.fetchTopViews/fetchHomeWidgets). Единственное, что
/// всё ещё догадка — какой именно ключ группы ("1"/"2"/"3") в ответе
/// top-views соответствует какой из трёх вкладок (см. TopViewsSort.groupKey).
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var bookmarks = BookmarksStore.shared

    /// Эталонный размер названия тайтла для ЭТОЙ страницы — тот же расчёт,
    /// что и MangaCardView.titleFont (caption1 × 1.2, medium), которым уже
    /// рендерятся карточки в «Новинках»: "текст как у названия тайтла в
    /// Новинках", везде на «Читают», где показывается НАЗВАНИЕ ТАЙТЛА
    /// («Продолжить читать», строки «Сейчас читают», строки «Последние
    /// обновления») — а не вообще любой текст (заголовки секций, подписи,
    /// имена пользователей/коллекций — другая роль, эталон на них не давят).
    private static var mangaTitleUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        return UIFont.systemFont(ofSize: base.pointSize * 1.2, weight: .medium)
    }
    private static var mangaTitleFont: Font { Font(mangaTitleUIFont) }

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
        }
        .task {
            viewModel.loadInitialIfNeeded()
            // «Читают» теперь открывается первой вкладкой при запуске — не
            // полагаемся только на параллельный AuthSession.syncAccountData()
            // при холодном старте (см. BookmarksView/HistoryView.task, тот же приём).
            await bookmarks.syncHistoryFromServer()
        }
        // НЕТ .onChange(of: scenePhase) — раньше здесь был автообновление при
        // каждом возврате из фона, и это оказалось причиной бага из фидбека
        // ("если на чуть-чуть свернуть приложение — элементы то появляются, то
        // пропадают"): даже мгновенный взгляд в App Switcher засчитывался как
        // "вернулись", запускал полный reloadAll() поверх уже показанных
        // данных, и без защиты от параллельных вызовов (см. HomeViewModel.
        // reloadTask) более старый ещё не завершившийся запрос мог перезаписать
        // уже пришедший свежий результат пустым/устаревшим. Обновление теперь
        // только по .task (при первом открытии) и потянуть-обновить.
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
                HStack {
                    sectionHeader("Продолжить читать")
                    Spacer(minLength: 0)
                    // Заглушка: локально прячет из виджета всё, что видно
                    // прямо сейчас (см. BookmarksStore.clearContinueReading) —
                    // не удаляет ни историю, ни закладку на сервере, реального
                    // подтверждённого эндпоинта под "очистить" ещё нет.
                    Button("Очистить") { bookmarks.clearContinueReading() }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(entries) { entry in
                            // Мусорка — ОТДЕЛЬНЫЙ Button рядом с NavigationLink
                            // в ZStack, а не вложен в его label: вложенная
                            // кнопка внутри NavigationLink ненадёжно ловит тап
                            // (жест может уйти на переход вместо кнопки).
                            ZStack(alignment: .topTrailing) {
                                NavigationLink(value: entry) { continueReadingCard(entry) }
                                    .buttonStyle(.plain)
                                trashButton(slug: entry.media.apiSlug)
                            }
                            .onAppear { viewModel.loadChapterCountIfNeeded(for: entry) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Общий множитель размера карточки "Продолжить читать" — попросили
    /// "увеличить в целом размер в 1.2х", от старых чисел (56x78 обложка,
    /// 220 ширина карточки, 10 паддинг).
    private static let continueReadingScale: CGFloat = 1.2
    private static let continueReadingCoverWidth: CGFloat = (56 * continueReadingScale).rounded()
    private static let continueReadingCoverHeight: CGFloat = (78 * continueReadingScale).rounded()
    private static let continueReadingCardWidth: CGFloat = (220 * continueReadingScale).rounded()
    private static let continueReadingPadding: CGFloat = (10 * continueReadingScale).rounded()

    /// Название — ВСЕГДА ровно 2 строки высотой (пустая вторая строка, если
    /// название короче), чтобы прогресс-бар был на одном и том же месте у
    /// всех карточек ряда независимо от длины конкретного названия.
    private static var continueReadingTitleBlockHeight: CGFloat {
        (mangaTitleUIFont.lineHeight * 2).rounded(.up)
    }

    private func continueReadingCard(_ entry: HistoryEntry) -> some View {
        let progress = bookmarks.readingProgress(forSlug: entry.media.apiSlug)
        return HStack(spacing: 12) {
            RemoteImage(url: entry.media.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.continueReadingCoverWidth, height: Self.continueReadingCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 7) {
                Text(entry.media.displayTitle)
                    .font(Self.mangaTitleFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: Self.continueReadingTitleBlockHeight, alignment: .top)
                Text(continueReadingProgressLabel(entry: entry, progress: progress))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                progressBar(fraction: progressFraction(progress))
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(Self.continueReadingPadding)
        .frame(width: Self.continueReadingCardWidth)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// "Глава 5 — 3 из 14" — номер главы + позиция/всего, когда общее число
    /// глав известно (см. loadChapterCountIfNeeded); "постраничный" прогресс
    /// внутри самой главы ("страница 3 из 14") — этого в API нет вообще
    /// (история аккаунта отдаёт только номер главы, не страницу), поэтому
    /// показываем прогресс по главам, не по страницам.
    private func continueReadingProgressLabel(entry: HistoryEntry, progress: ReadingProgress?) -> String {
        guard let progress, progress.totalChapters > 0 else { return "Глава \(entry.item.number)" }
        return "Глава \(entry.item.number) — \(progress.readCount) из \(progress.totalChapters)"
    }

    /// Мусорка поверх подложки карточки — только прячет локально (см.
    /// BookmarksStore.dismissContinueReading), заглушка до реального API.
    private func trashButton(slug: String) -> some View {
        Button {
            bookmarks.dismissContinueReading(slug: slug)
        } label: {
            Image(systemName: "trash")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
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

    /// Квадратная обложка ряда + высота одного ряда/страницы пейджинга —
    /// вынесены в константы, чтобы карусель ниже и высота её GeometryReader
    /// считались от одних и тех же чисел.
    private static let currentlyReadingCoverSize: CGFloat = 56
    private static let currentlyReadingRowSpacing: CGFloat = 10
    /// Заголовок страницы-подкатегории (Новинки/Набирающее популярность/
    /// Популярное) — увеличен в 1.25х по просьбе. Высота строки берётся из
    /// реальных метрик шрифта (а не фиксированного числа), чтобы более
    /// крупный текст не обрезался по вертикали.
    private static var currentlyReadingLabelUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        return UIFont.systemFont(ofSize: base.pointSize * 1.25, weight: .semibold)
    }
    private static var currentlyReadingLabelFont: Font { Font(currentlyReadingLabelUIFont) }
    private static var currentlyReadingLabelHeight: CGFloat { currentlyReadingLabelUIFont.lineHeight.rounded(.up) }
    private static var currentlyReadingPageHeight: CGFloat {
        currentlyReadingLabelHeight + 8
        + currentlyReadingCoverSize * 3
        + currentlyReadingRowSpacing * 2
    }

    @ViewBuilder
    private var currentlyReadingSection: some View {
        let hasAnyItems = TopViewsSort.allCases.contains { !(viewModel.currentlyReadingBySort[$0] ?? []).isEmpty }
        if hasAnyItems || viewModel.isLoadingCurrentlyReading || viewModel.currentlyReadingErrorMessage != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionHeader("Сейчас читают")
                    Spacer(minLength: 0)
                    periodMenu
                }
                .padding(.horizontal, 16)

                if !hasAnyItems, let error = viewModel.currentlyReadingErrorMessage {
                    errorRow(error) { viewModel.retry() }
                        .padding(.horizontal, 16)
                } else if !hasAnyItems && viewModel.isLoadingCurrentlyReading {
                    ProgressView().tint(Theme.accent)
                        .frame(height: Self.currentlyReadingPageHeight)
                        .frame(maxWidth: .infinity)
                } else {
                    currentlyReadingCarousel
                }
            }
        }
    }

    /// Горизонтальный пейджинг страниц-категорий (Новинки/Набирающее
    /// популярность/Популярное), каждая — 3 тайтла строками друг под другом.
    /// Ширина страницы — почти весь экран минус ~40pt, чтобы справа
    /// проглядывал краешек следующей страницы (обложка + первые буквы её
    /// заголовка, как попросили — "должно быть видно первые 2 буквы На и По").
    /// .scrollTargetBehavior(.viewAligned) — нативный снап по странице.
    private var currentlyReadingCarousel: some View {
        GeometryReader { proxy in
            let peekWidth: CGFloat = 44
            let pageWidth = max(0, proxy.size.width - 16 - peekWidth)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(TopViewsSort.allCases) { sort in
                        currentlyReadingPage(sort: sort, items: viewModel.currentlyReadingBySort[sort] ?? [])
                            .frame(width: pageWidth, alignment: .leading)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, 16)
                .padding(.trailing, peekWidth)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
        .frame(height: Self.currentlyReadingPageHeight)
    }

    private func currentlyReadingPage(sort: TopViewsSort, items: [MangaItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sort.title)
                .font(Self.currentlyReadingLabelFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(height: Self.currentlyReadingLabelHeight, alignment: .leading)
            VStack(spacing: Self.currentlyReadingRowSpacing) {
                ForEach(items.prefix(3)) { item in
                    NavigationLink(value: item) { currentlyReadingRow(item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func currentlyReadingRow(_ item: MangaItem) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: item.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.currentlyReadingCoverSize, height: Self.currentlyReadingCoverSize)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(Self.mangaTitleFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let typeLabel = item.type?.label, !typeLabel.isEmpty {
                    Text(typeLabel)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.currentlyReadingCoverSize)
    }

    /// Короткая строка ошибки + "Повторить" — используется там, где секция
    /// не может просто промолчать (см. currentlyReadingSection): без неё
    /// неудачный запрос выглядел как "вообще не грузит" без объяснений.
    private func errorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Повторить", action: retry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
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

            // "Все" и "Мои" — теперь оба ПОДТВЕРЖДЁННЫЕ эндпоинты одной формы
            // (см. HomeViewModel.fetchUpdatesPage) — общий ряд для обеих вкладок.
            LazyVStack(spacing: 10) {
                ForEach(viewModel.updates) { item in
                    NavigationLink(value: item) { updateRow(item) }
                        .buttonStyle(.plain)
                        .onAppear { viewModel.loadMoreUpdatesIfNeeded(currentId: item.id) }
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
                    .font(Self.mangaTitleFont)
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
