import SwiftUI
import UIKit

/// Невидимый "датчик" активации родного .searchable() (см. HomeView.body) —
/// глобального поиска пока нет, поле служит воротами на вкладку Каталог, где
/// он и живёт (см. CatalogNavigator.switchRequest в RootView, тот же мост,
/// что уже используют жанры/теги из карточки тайтла). @Environment(\.isSearching)
/// нужно читать ИЗ потомка того места, где применён .searchable() — не из
/// самого HomeView (его тело строит содержимое .searchable(), а не наоборот) —
/// отсюда отдельный вью-пустышка, а не просто вычисляемое свойство.
private struct SearchActivationRedirect: View {
    @Environment(\.isSearching) private var isSearching
    var body: some View {
        Color.clear
            .onChange(of: isSearching) { _, active in
                if active { CatalogNavigator.shared.openCatalog(filter: MangaFilter()) }
            }
    }
}

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
    @ObservedObject private var authSession = AuthSession.shared
    /// Порядок/видимость разделов — настраивается в Персонализации (см.
    /// PersonalizationSettingsView.homeSectionsCard), реально применяется
    /// здесь (см. content/section(for:)).
    @ObservedObject private var sectionsStore = HomeSectionsStore.shared
    /// Экран входа для "Мои обновления" без аккаунта — см. updatesTabBinding.
    @State private var showLoginForUpdates = false
    /// Текст в .searchable() — реально никуда не отправляется, поле служит
    /// только "воротами" на вкладку Каталог (см. SearchActivationRedirect).
    @State private var searchQuery = ""
    /// Открытие профиля пользователя тапом по карточке в «Топ активных
    /// недели» — тот же ProfileUserId + .sheet(item:), что и в
    /// FriendsView/MangaReviewsView (см. ProfileUserId в AccountInfoView.swift).
    @State private var profileUser: ProfileUserId?
    /// Сколько строк "Последних обновлений" видно сейчас — см.
    /// updatesSection/updatesFooterControls/Self.updatesPageSize.
    @State private var updatesVisibleCount: Int = HomeView.updatesPageSize

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
            content
                .background { Theme.background.ignoresSafeArea() }
                .refreshable {
                    async let a: Void = viewModel.refresh()
                    async let b: Void = bookmarks.syncHistoryFromServer()
                    _ = await (a, b)
                }
            // App Store-эталон (тот же приём, что в MangaCatalogView —
            // .background() вместо равноправного слоя в ZStack, см.
            // комментарий там): крупный заголовок без фона в покое,
            // системный блюр проявляется при первом скролле, заголовок
            // схлопывается в маленький.
            .navigationTitle("Читают")
            .navigationBarTitleDisplayMode(.large)
            // Настоящего глобального поиска пока нет — то же решение, что и
            // раньше у капсулы-заглушки, просто через родной .searchable()
            // вместо самодельного нередактируемого TextField: как только
            // поле активировано (см. SearchActivationRedirect в content),
            // сразу переключаемся на вкладку «Каталог» — там и живёт
            // реальный поиск (см. MangaCatalogView).
            .searchable(text: $searchQuery, prompt: "Поиск по названию")
            .navigationDestination(for: MangaItem.self) { item in
                MangaDetailView(slug: item.apiSlug, fallbackTitle: item.displayTitle,
                                 coverURL: item.cover?.bestURL, item: item)
            }
            .navigationDestination(for: HistoryEntry.self) { entry in
                MangaDetailView(slug: entry.media.apiSlug, fallbackTitle: entry.media.displayTitle,
                                 coverURL: entry.media.cover?.bestURL, item: entry.media)
            }
            .sheet(isPresented: $showLoginForUpdates, onDismiss: {
                // Успешный вход — сразу открываем именно ту вкладку,
                // ради которой пользователь и заходил.
                if AuthSession.shared.isLoggedIn { viewModel.updatesTab = .mine }
            }) {
                LoginView()
            }
            .sheet(item: $profileUser) { pu in
                ProfileView(userId: pu.id).preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
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

    /// Больше НЕТ общего "весь экран — один спиннер, пока НЕ пришло вообще
    /// всё" (isLoading && !didLoadOnce) — по фидбеку это и было причиной
    /// "интерфейс сыпется, потом собирается": пока грузится, экран был
    /// пустой, а как только приходили ВСЕ секции разом, они появлялись
    /// одним рывком, сдвигая друг друга. Теперь ScrollView и все секции на
    /// местах СРАЗУ — каждая секция сама решает, показать свой скелетон
    /// (см. *Skeleton ниже) или уже пришедший контент, независимо от
    /// остальных. Секции, которым нужен вход (Продолжить читать, Мои
    /// обновления), скелетон не показывают, пока не залогинены — просто
    /// появляются сами после входа, как и раньше, но ТОЖЕ получают скелетон
    /// при обновлении (см. continueReadingSection и .refreshable в body).
    ///
    /// .refreshable НЕ здесь (не на самом ScrollView, а снаружи, в body) —
    /// раньше именно эта связка на одном и том же ScrollView скроллила
    /// шапку вместе с контентом; теперь шапка — родной navigationTitle, не
    /// часть ScrollView вообще, но порядок оставлен как есть, менять незачем.
    private var content: some View {
        // ScrollViewReader — нужен ТОЛЬКО чтобы при переключении "Все"/"Мои"
        // в "Последних обновлениях" не подбрасывало наверх (см. комментарий
        // у .onChange ниже): весь экран — один ScrollView, и когда
        // updatesTab.didSet мгновенно очищает список (см. HomeViewModel) —
        // высота контента резко схлопывается до 4 строк скелетона, и если
        // пользователь был проскроллен ниже этой высоты, ScrollView сам
        // "прижимает" его обратно наверх. Явный scrollTo к началу секции —
        // предсказуемый результат вместо случайного клэмпинга.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(sectionsStore.order.filter(sectionsStore.isVisible)) { kind in
                        section(for: kind).id(kind.id)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background { SearchActivationRedirect() }
            .onChange(of: viewModel.updatesTab) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(HomeSectionKind.updates.id, anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func section(for kind: HomeSectionKind) -> some View {
        switch kind {
        case .popular:          popularSection
        case .continueReading:  continueReadingSection
        case .currentlyReading: currentlyReadingSection
        case .collections:      collectionsSection
        case .topActiveWeek:    topActiveUsersSection
        case .newest:           newestSection
        case .updates:          updatesSection
        }
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
                    // Тот же плоский чип с подложкой, что у periodMenu в
                    // «Сейчас читают» — по прямой просьбе, единый стиль.
                    Button("Очистить") { bookmarks.clearContinueReading() }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
                .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
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
        } else if authSession.isLoggedIn && bookmarks.isSyncingHistory {
            // Скелетон ТОЛЬКО пока залогинены и правда идёт загрузка (не
            // залогинен — секция просто не появляется, как и раньше, ждать
            // ей нечего). Показывается и на самом первом входе, и на
            // .refreshable — оба гоняют syncHistoryFromServer().
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Продолжить читать")
                    .padding(.horizontal, 16)
                continueReadingSkeleton
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

    /// Обложка вплотную к краю подложки (как в "Похожем" на экране тайтла,
    /// см. similarCard) — раньше был общий .padding() на весь HStack, из-за
    /// которого обложка висела с отступом от левого/верхнего/нижнего краёв
    /// карточки. Теперь падинг только у текстовой колонки и справа, а
    /// радиус обложки (16) совпадает с радиусом самой подложки — угол в угол.
    private func continueReadingCard(_ entry: HistoryEntry) -> some View {
        let progress = bookmarks.readingProgress(forSlug: entry.media.apiSlug)
        return HStack(spacing: 12) {
            RemoteImage(url: entry.media.cover?.thumbnailURL ?? entry.media.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.continueReadingCoverWidth, height: Self.continueReadingCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            .padding(.vertical, Self.continueReadingPadding)
            Spacer(minLength: 0)
        }
        .padding(.trailing, Self.continueReadingPadding)
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
    /// Популярное) — по просьбе снова поменян местами с sectionHeader():
    /// та версия (headline×1.25) делала подкатегории заметно крупнее
    /// заголовков секций, что смотрелось наоборот — теперь здесь меньший
    /// эталон (subheadline, без множителя), а больший ушёл в sectionHeader.
    private static var currentlyReadingLabelUIFont: UIFont {
        UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
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
                    currentlyReadingSkeleton
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
            // Было ~10% ширины экрана (44pt) — по просьбе убавлено примерно
            // на 3 процентных пункта (~7%), чтобы справа проглядывали 2
            // буквы следующего заголовка, а не 3.
            let peekWidth: CGFloat = 30
            let pageWidth = max(0, proxy.size.width - 16 - peekWidth)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
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
            // Приглушённый цвет (textSecondary) — тот же, что у жанра/типа
            // тайтла в карточках (см. MangaCardView.typeLabel) — по просьбе,
            // чтобы подкатегории читались чуть обесцвеченными.
            Text(sort.title)
                .font(Self.currentlyReadingLabelFont)
                .foregroundStyle(Theme.textSecondary)
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
            RemoteImage(url: item.cover?.thumbnailURL ?? item.cover?.bestURL) { image in
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
            // Плоский чип с подложкой вместо стекла — по прямой просьбе.
            .background(Theme.surfaceElevated, in: Capsule())
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
                    LazyHStack(spacing: 12) {
                        ForEach(viewModel.collections) { collection in
                            NavigationLink { CollectionDetailView(collectionId: collection.id, fallback: collection) } label: {
                                collectionCard(collection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        } else if viewModel.isLoadingWidgets {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Последние коллекции")
                    .padding(.horizontal, 16)
                collectionsSkeleton
            }
        }
    }

    /// 1-в-1 референс с реального сайта: всё по центру — название, три
    /// чипа-пилюли статов (просмотры/тайтлы/избранное) в один ряд, голос
    /// отдельной пилюлей под ними, веер обложек по центру. Своя копия у
    /// каждого места, где показываются коллекции (см. тот же комментарий в
    /// UserCollectionsView/CollectionsListView).
    ///
    /// Ширина — ~70% экрана (по прямой просьбе, было фикс 260) — карточки в
    /// горизонтальном скролле, так следующая всегда чуть выглядывает
    /// сбоку. Высота названия — фикс на ДВЕ строки (было "плавала" в
    /// зависимости от реальной длины имени: 1-строчные названия давали
    /// более короткую и от этого визуально "прыгающую" карточку в ряду
    /// разных карточек).
    private static var collectionCardWidth: CGFloat { UIScreen.main.bounds.width * 0.7 }
    private static let collectionTitleHeight: CGFloat = 50

    /// Название в 1 строку — центрируем по вертикали в отведённой под
    /// заголовок высоте (иначе короткое название "прилипает" к верху
    /// пустой коробки и выглядит криво); в 2 строки — как раньше, сверху,
    /// коробка и так заполняется целиком. ViewThatFits — стандартный трюк
    /// узнать, влезает ли текст в 1 строку без переноса: у первого варианта
    /// `.fixedSize(horizontal: true)` — его "естественная" ширина всегда
    /// равна ширине текста в 1 строку, и если она не влезает в доступную
    /// ширину, ViewThatFits сам переключается на второй (2-строчный) вариант.
    private func collectionTitleRow(_ collection: MangaCollection) -> some View {
        ViewThatFits(in: .horizontal) {
            collectionTitleContent(collection, lineLimit: 1, fixedSize: true)
                .frame(height: Self.collectionTitleHeight, alignment: .center)
            // .clipped() — при очень длинном названии (или увеличенном
            // системном размере шрифта) 2 строки title3.weight(.bold) могут
            // чуть превысить отведённые 50pt; без обрезки текст визуально
            // вылезал бы под соседнюю строку статов (иконка количества
            // тайтлов/обложек ниже) — по прямой просьбе такого быть не должно.
            collectionTitleContent(collection, lineLimit: 2, fixedSize: false)
                .frame(height: Self.collectionTitleHeight, alignment: .top)
                .clipped()
        }
    }

    private func collectionTitleContent(_ collection: MangaCollection, lineLimit: Int, fixedSize: Bool) -> some View {
        HStack(spacing: 6) {
            Text(collection.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: fixedSize, vertical: false)
            if collection.adult == true {
                Text("18+")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func collectionCard(_ collection: MangaCollection) -> some View {
        VStack(spacing: 12) {
            collectionTitleRow(collection)

            HStack(spacing: 10) {
                if let views = collection.views { statPill(icon: "eye", text: "\(views)") }
                if let itemsCount = collection.itemsCount { statPill(icon: "square.stack", text: "\(itemsCount)") }
                if let favoritesCount = collection.favoritesCount { statPill(icon: "bookmark", text: "\(favoritesCount)") }
            }
            if let votes = collection.votes {
                statPill(icon: "star.fill", text: "\(votes.up) / \(votes.down)")
            }

            collectionPreviewStack(collection.previews ?? [])
        }
        .padding(18)
        .frame(width: Self.collectionCardWidth)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statPill(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    /// Веер обложек 1-в-1 разбор реального сайта (по прямой просьбе,
    /// точные углы/смещения/z-индексы): левая (-13°, x:-35, y:-4, самый
    /// НИЖНИЙ слой) → центральная (0°, по центру, средний слой) → правая
    /// (+7°, x:+30, y:+8, самый ВЕРХНИЙ слой, перекрывает центральную).
    /// Вращение — от НИЖНЕГО центра каждой обложки (anchor: .bottom), не от
    /// геометрического центра — так они расходятся веером из одной точки
    /// внизу, а не проворачиваются на месте. Была симметричная версия
    /// "центр всегда сверху" — по факту у сайта верхний слой ПРАВАЯ.
    private static let fanTransforms: [(rotation: Double, x: CGFloat, y: CGFloat, z: Double)] = [
        (-13, -35, -4, 0),
        (0, 0, 0, 1),
        (7, 30, 8, 2)
    ]

    private func collectionPreviewStack(_ previews: [MangaCover]) -> some View {
        let items = Array(previews.prefix(3))
        return ZStack(alignment: .bottom) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, cover in
                let t = items.count == 3 ? Self.fanTransforms[index] : (rotation: 0, x: 0, y: 0, z: Double(index))
                RemoteImage(url: cover.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    Theme.surfaceElevated
                }
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 4)
                .rotationEffect(.degrees(t.rotation), anchor: .bottom)
                .offset(x: t.x, y: t.y)
                .zIndex(t.z)
            }
        }
        .frame(height: 116)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Топ активных недели

    @ViewBuilder
    private var topActiveUsersSection: some View {
        if !viewModel.topActiveUsers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Топ активных недели")
                    .padding(.horizontal, 16)
                // Левый отступ (16) вернули — без него чипы съезжали левее
                // заголовка секции над ними, выглядело как рассинхрон
                // выравнивания. Справа по-прежнему без отступа — карточки
                // могут доходить до самого края экрана.
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(viewModel.topActiveUsers.enumerated()), id: \.element.id) { index, user in
                            topActiveUserCard(user, rank: index + 1)
                        }
                    }
                    .padding(.leading, 16)
                }
                .scrollIndicators(.hidden)
            }
        } else if viewModel.isLoadingWidgets {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Топ активных недели")
                    .padding(.horizontal, 16)
                topActiveUsersSkeleton
            }
        }
    }

    private func topActiveUserCard(_ user: TopActiveUser, rank: Int) -> some View {
        Button {
            profileUser = ProfileUserId(id: user.id)
        } label: {
            topActiveUserCardContent(user, rank: rank)
        }
        .buttonStyle(.plain)
    }

    private func topActiveUserCardContent(_ user: TopActiveUser, rank: Int) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: user.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    // maxWidth: .infinity вместо фиксированных 90 — растягивается
                    // на ширину, которую VStack уже определил по нику (обычно
                    // самому широкому элементу), а не на свою собственную.
                    progressBar(fraction: points.maxLevelPoints > 0
                                ? Double(points.currentLevelPoints) / Double(points.maxLevelPoints) : nil)
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                }
            }
        }
        .padding(10)
        // maxWidth (не фиксированная width) — чип подстраивается под длину
        // ника: у коротких ников раньше оставалась пустая полоса и контент
        // выглядел "центрированным" внутри фиксированных 210pt. Верхняя
        // граница на всякий случай оставлена той же — длинный ник (20+
        // символов) просто обрежется многоточием (.lineLimit(1) у Text
        // выше), а не растянет чип.
        .frame(maxWidth: 210, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Общий размер карточки — "как в Каталоге при сетке 3"

    /// Используется в "Новинках" и "Обновлении популярных тайтлов" — по
    /// прямой просьбе "обложки и текст всё должно быть как в разделе
    /// каталог при сетке 3". Специально ЖЁСТКО columns: 3 (не читает
    /// личную настройку "Количество карточек", см. CardsPerRow) — та
    /// влияет только на настоящие сетки Каталога/Закладок, здесь же речь
    /// именно про фиксированный эталон "как при сетке 3", а не "как
    /// сейчас выбрано". Тот же расчёт, что и MangaCatalogView.gridCardWidth.
    private static var catalogGrid3CardWidth: CGFloat {
        MangaCardView.gridCardWidth(totalWidth: UIScreen.main.bounds.width, columns: 3, spacing: 12, containerPadding: 12)
    }

    // MARK: Обновление популярных тайтлов

    /// Слайдер популярных тайтлов — БЕЗ заголовка секции сверху (по прямой
    /// просьбе, в отличие от остальных разделов). ПОДТВЕРЖДЁННЫЙ перехватом
    /// ключ "popular" в агрегате главной (см. HomeWidgetsPayload) — раньше
    /// нигде не декодировался. "Глава X" на карточке — то же самое поле,
    /// что и в "Новинках" (metadata.last_item), не отдельный "ранг".
    @ViewBuilder
    private var popularSection: some View {
        if !viewModel.popular.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(viewModel.popular) { item in
                        NavigationLink(value: item) {
                            MangaCardView(item: item, width: Self.catalogGrid3CardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        } else if viewModel.isLoadingWidgets {
            popularSkeleton
        }
    }

    private var popularSkeleton: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBox()
                            .frame(width: Self.catalogGrid3CardWidth, height: (Self.catalogGrid3CardWidth * 3 / 2).rounded())
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        skeletonBar(width: Self.catalogGrid3CardWidth * 0.85, height: 12)
                        skeletonBar(width: Self.catalogGrid3CardWidth * 0.6, height: 10)
                    }
                    .frame(width: Self.catalogGrid3CardWidth)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Новинки

    @ViewBuilder
    private var newestSection: some View {
        if !viewModel.newest.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Новинки")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(viewModel.newest) { item in
                            NavigationLink(value: item) {
                                // Ширина — "как в Каталоге при сетке 3" (см.
                                // Self.catalogGrid3CardWidth), по прямой просьбе.
                                MangaCardView(item: item, width: Self.catalogGrid3CardWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        } else if viewModel.isLoadingNewest {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Новинки")
                    .padding(.horizontal, 16)
                newestSkeleton
            }
        }
    }

    // MARK: Последние обновления

    /// "Все обновления" — /latest-updates, не привязан к аккаунту, работает
    /// без входа (см. MangaNetworkService.fetchLatestUpdates). "Мои
    /// обновления" — /user-latest-updates, требует аккаунт: при тапе без
    /// входа сразу открываем экран входа вместо пустого/ошибочного списка
    /// (см. updatesTabBinding), а после успешного входа сама переключаем
    /// вкладку на "Мои" — ровно то, что пользователь и пытался открыть.
    private var updatesTabBinding: Binding<HomeUpdatesTab> {
        Binding(
            get: { viewModel.updatesTab },
            set: { newValue in
                if newValue == .mine && !AuthSession.shared.isLoggedIn {
                    showLoginForUpdates = true
                    return
                }
                viewModel.updatesTab = newValue
            }
        )
    }

    /// Сколько строк показываем сразу/добавляем за раз (см.
    /// updatesFooterControls) — по прямой просьбе "всегда макс 7", вместо
    /// прежнего бесконечного скролла (см. историю ниже про onAppear).
    private static let updatesPageSize = 7

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Последние обновления")
                .padding(.horizontal, 16)

            Picker("", selection: updatesTabBinding) {
                ForEach(HomeUpdatesTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            // "Все" и "Мои" — теперь оба ПОДТВЕРЖДЁННЫЕ эндпоинты одной формы
            // (см. HomeViewModel.fetchUpdatesPage) — общий ряд для обеих вкладок.
            // Скелетон, пока список ещё пуст И идёт именно НАЧАЛЬНАЯ загрузка
            // (isLoadingUpdates) — не путать с isLoadingMoreUpdates (подгрузка
            // следующей страницы по "Показать ещё", см. updatesFooterControls).
            if viewModel.updates.isEmpty && viewModel.isLoadingUpdates {
                updatesSkeleton
            } else {
                // Раньше — плоский ForEach по ВСЕМ viewModel.updates с
                // .onAppear-подгрузкой следующей страницы у последней строки
                // (бесконечный скролл). По прямой просьбе — максимум 7 строк
                // видно сразу, дальше только по явному тапу "Показать ещё"
                // (см. updatesFooterControls/showMoreUpdates), плюс кнопка
                // свернуть обратно до 7.
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.updates.prefix(updatesVisibleCount)) { item in
                        NavigationLink(value: item) { updateRow(item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                updatesFooterControls
            }
        }
        // Смена вкладки Все/Мои сбрасывает сам список (см. HomeViewModel.
        // updatesTab.didSet) — видимый лимит сбрасываем туда же, к 7.
        .onChange(of: viewModel.updatesTab) { _, _ in updatesVisibleCount = Self.updatesPageSize }
    }

    /// "Показать ещё" (+7, бесконечно, пока есть данные) и, если список уже
    /// раскрыт больше 7 — рядом круглая кнопка "свернуть обратно до 7" (НЕ
    /// стеклянная), обе центрированы. По прямой просьбе.
    @ViewBuilder
    private var updatesFooterControls: some View {
        let isExpanded = updatesVisibleCount > Self.updatesPageSize
        let canShowMore = updatesVisibleCount < viewModel.updates.count || viewModel.updatesHasNext

        if canShowMore || isExpanded {
            HStack(spacing: 12) {
                if canShowMore {
                    Button {
                        showMoreUpdates()
                    } label: {
                        Group {
                            if viewModel.isLoadingMoreUpdates {
                                ProgressView().tint(Theme.textPrimary)
                            } else {
                                Text("Показать ещё")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingMoreUpdates)
                }

                if isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { updatesVisibleCount = Self.updatesPageSize }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }

    /// +7 — если уже подгружено достаточно строк, просто открывает их;
    /// если нет, дозапрашивает следующую страницу (переиспользует ту же
    /// пагинацию, что раньше запускалась по onAppear последней строки).
    private func showMoreUpdates() {
        updatesVisibleCount += Self.updatesPageSize
        if viewModel.updates.count < updatesVisibleCount, let lastId = viewModel.updates.last?.id {
            viewModel.loadMoreUpdatesIfNeeded(currentId: lastId)
        }
    }

    /// caption2×1.2 regular — та же формула, что и MangaCardView.typeUIFont.
    private static var updatesTypeUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption2)
        return UIFont.systemFont(ofSize: base.pointSize * 1.2, weight: .regular)
    }
    private static var updatesTypeFont: Font { Font(updatesTypeUIFont) }
    private static let updatesTextSpacing: CGFloat = 4

    /// 1-в-1 обложка списка закладок (см. BookmarksView.bookmarkCoverWidth/
    /// bookmarkCoverHeight, 80×120, 2:3) — по прямой просьбе "привести
    /// размер/высоту обложек для последних обновлений 1в1 как список
    /// закладок", вместо отдельного независимого расчёта, который был раньше.
    private static let updatesCoverWidth: CGFloat = BookmarksView.bookmarkCoverWidth
    private static let updatesCoverHeight: CGFloat = BookmarksView.bookmarkCoverHeight

    /// Высота подложки — под ХУДШИЙ случай текста (название в 2 строки +
    /// "Том X Глава Y — Название" в 2 строки + дата), а не константа "от
    /// балды": иначе либо остаётся лишний пустой отступ у коротких карточек,
    /// либо длинный текст не влезает и подложка "плывёт" по контенту. Если
    /// это меньше высоты обложки — берём высоту обложки. Текст короче этой
    /// высоты центрируется сам (обычное .center HStack, без Spacer/anchor).
    private static var updatesRowHeight: CGFloat {
        let textBlockHeight = (mangaTitleUIFont.lineHeight * 2).rounded(.up)
            + updatesTextSpacing
            + (updatesTypeUIFont.lineHeight * 2).rounded(.up)
            + updatesTextSpacing
            + updatesTypeUIFont.lineHeight.rounded(.up)
        return max(updatesCoverHeight, textBlockHeight)
    }

    private func updateRow(_ item: MangaItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.cover?.thumbnailURL ?? item.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.updatesCoverWidth, height: Self.updatesCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()

            // Название (макс 2 строки), под ним "Том X Глава Y — Название"
            // (макс 2 строки; только название главы и дата приглушённые —
            // см. chapterAttributedLine), дата — сразу под ним. Без верхнего/
            // нижнего Spacer — блок сам центрируется в фиксированной высоте
            // строки (см. updatesRowHeight выше). maxWidth: .infinity — чтобы
            // подложка ВСЕГДА была одной и той же ширины (во всю строку), а
            // не сжималась по фактической ширине текста у коротких названий.
            VStack(alignment: .leading, spacing: Self.updatesTextSpacing) {
                Text(item.displayTitle)
                    .font(Self.mangaTitleFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                chapterAttributedLine(for: item)
                    .font(Self.updatesTypeFont)
                    .lineLimit(2)
                if let date = item.lastItemDate {
                    Text(date.relativeRussianString)
                        .font(Self.updatesTypeFont)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 12)
        .frame(height: Self.updatesRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// "Том X Глава Y — Название" — Том/Глава обычным цветом (это факт: что
    /// именно обновилось), а название главы (когда есть, часто пусто) и
    /// дата — приглушённым textSecondary, по прямой просьбе.
    private func chapterAttributedLine(for item: MangaItem) -> Text {
        guard let chapter = item.latestChapter else {
            return Text(item.type?.label ?? "").foregroundColor(Theme.textSecondary)
        }
        var parts: [String] = []
        if let volume = chapter.volume, !volume.isEmpty { parts.append("Том \(volume)") }
        if let number = chapter.number, !number.isEmpty { parts.append("Глава \(number)") }
        let base = parts.joined(separator: " ")
        var result = Text(base.isEmpty ? (item.type?.label ?? "") : base)
            .foregroundColor(base.isEmpty ? Theme.textSecondary : Theme.textPrimary)
        if let name = chapter.name, !name.isEmpty {
            result = result + Text(" — \(name)").foregroundColor(Theme.textSecondary)
        }
        if item.extraLatestChaptersCount > 0 {
            result = result + Text(" + ещё \(item.extraLatestChaptersCount)").foregroundColor(Theme.textSecondary)
        }
        return result
    }

    // MARK: Скелетоны загрузки

    /// Плейсхолдер-полоска текста (SkeletonBox нужного размера) — для строк,
    /// которые в реальном контенте занимает Text (название, ник, дата и
    /// т.п.), пока данных ещё нет. Тот же shimmer, что и у RemoteImage
    /// (SkeletonBox), просто в форме текстовой строки, а не обложки.
    private func skeletonBar(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 4) -> some View {
        SkeletonBox()
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Копия макета continueReadingCard — те же размеры обложки/карточки,
    /// чтобы при подмене на реальный контент ничего не "прыгало".
    private var continueReadingSkeleton: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonBox()
                            .frame(width: Self.continueReadingCoverWidth, height: Self.continueReadingCoverHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 7) {
                            skeletonBar(width: 110, height: 12)
                            skeletonBar(width: 70, height: 11)
                            skeletonBar(width: 90, height: 5, cornerRadius: 2.5)
                        }
                        .padding(.vertical, Self.continueReadingPadding)
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, Self.continueReadingPadding)
                    .frame(width: Self.continueReadingCardWidth)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// Копия макета currentlyReadingPage (подкатегория + 3 строки) — та же
    /// высота (currentlyReadingPageHeight), чтобы секция не "прыгала", когда
    /// придут реальные данные.
    private var currentlyReadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            skeletonBar(width: 90, height: Self.currentlyReadingLabelHeight)
            VStack(spacing: Self.currentlyReadingRowSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 10) {
                        SkeletonBox()
                            .frame(width: Self.currentlyReadingCoverSize, height: Self.currentlyReadingCoverSize)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            skeletonBar(width: 150, height: 12)
                            skeletonBar(width: 70, height: 10)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.currentlyReadingCoverSize)
                }
            }
        }
        .frame(height: Self.currentlyReadingPageHeight)
        .padding(.horizontal, 16)
    }

    /// Копия макета collectionCard (по центру, тот же масштаб) — заголовок +
    /// ряд чипов-пилюль + веер обложек, всё по центру карточки.
    private var collectionsSkeleton: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 12) {
                        skeletonBar(width: 140, height: Self.collectionTitleHeight)
                        skeletonBar(width: 180, height: 32)
                        SkeletonBox()
                            .frame(width: Self.collectionCardWidth - 36, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(18)
                    .frame(width: Self.collectionCardWidth)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// Копия макета topActiveUserCard (аватарка-квадрат + ник + уровень +
    /// прогресс-бар) — те же размеры (44×44), что у реальной аватарки.
    private var topActiveUsersSkeleton: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 10) {
                        SkeletonBox()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            skeletonBar(width: 80, height: 11)
                            skeletonBar(width: 56, height: 9)
                            skeletonBar(width: 90, height: 4, cornerRadius: 2)
                        }
                    }
                    .padding(10)
                    .frame(width: 170, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.leading, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// Копия макета MangaCardView (обложка 2:3 от ширины 108 + название +
    /// тип) — те же пропорции, что у реальных карточек «Новинок».
    private var newestSkeleton: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBox()
                            .frame(width: Self.catalogGrid3CardWidth, height: (Self.catalogGrid3CardWidth * 3 / 2).rounded())
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        skeletonBar(width: Self.catalogGrid3CardWidth * 0.85, height: 12)
                        skeletonBar(width: Self.catalogGrid3CardWidth * 0.6, height: 10)
                    }
                    .frame(width: Self.catalogGrid3CardWidth)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// Копия макета updateRow — та же ширина/высота подложки (updatesRowHeight),
    /// чтобы список не "прыгал" при подмене на реальные карточки.
    private var updatesSkeleton: some View {
        VStack(spacing: 10) {
            ForEach(0..<Self.updatesPageSize, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBox()
                        .frame(width: Self.updatesCoverWidth, height: Self.updatesCoverHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: Self.updatesTextSpacing) {
                        skeletonBar(width: 170, height: 12)
                        skeletonBar(width: 130, height: 12)
                        skeletonBar(width: 70, height: 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 12)
                .frame(height: Self.updatesRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Общее

    /// По просьбе снова поменян местами с заголовком подкатегории «Сейчас
    /// читают» (см. currentlyReadingLabelUIFont) — теперь заголовки секций
    /// (у всех есть стрелочка chevron.right справа) крупнее, headline×1.25.
    private static var sectionHeaderFont: Font {
        let base = UIFont.preferredFont(forTextStyle: .headline)
        return Font(UIFont.systemFont(ofSize: base.pointSize * 1.25, weight: .semibold))
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(Self.sectionHeaderFont).foregroundStyle(Theme.textPrimary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

#Preview {
    HomeView().preferredColorScheme(.dark)
}
