import SwiftUI
import UIKit

/// Вкладка «Закладки»: сверху заголовок/поиск + шестерёнка (Вид/Сортировка,
/// см. ViewSortSheet) и карандаш (порядок списков, см. FolderOrderSheet),
/// снизу горизонтальная полоска подкатегорий, между ними список/плитка тайтлов.
/// Плитка (gridContent/bookmarkGridCell) — число колонок из Персонализации
/// (см. CardsPerRow, 2/3/4/Авто), карточка та же архитектура точного
/// расчёта ширины/построчной высоты текста, что и в Каталоге (см.
/// MangaCatalogView.grid/MangaCardView) — плюс, по прямой просьбе, три чипа
/// поверх обложки: номер текущей главы (слева сверху), твоя личная оценка
/// (справа сверху) и "..." — быстрая смена папки (справа снизу).
struct BookmarksView: View {

    @ObservedObject private var store = BookmarksStore.shared
    @ObservedObject private var catalogNav = CatalogNavigator.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var selectedFolderId: String? = nil   // nil = «Все»
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var query = ""

    /// Тайтл, который сейчас редактируется через долгое нажатие на строку
    /// (см. row() ниже, .contextMenu) — открывает тот же AddToFolderSheet,
    /// что и на странице тайтла (сменить папку/убрать из закладок).
    @State private var editingBookmark: BookmarkedTitle?

    /// Щит редактирования порядка списков (иконка карандаша в шапке).
    @State private var showFolderOrderSheet = false
    /// Щит "Вид"/"Сортировка" (иконка шестерёнки в шапке).
    @State private var showViewSortSheet = false

    /// Список/плитка — см. ViewSortSheet. Сохраняется между запусками.
    @AppStorage("bookmarks_view_mode") private var viewMode: BookmarksViewMode = .list
    /// Поле сортировки — см. ViewSortSheet.
    @AppStorage("bookmarks_sort_option") private var sortOption: BookmarksSortOption = .dateAdded
    /// Направление — применяется только к полям-датам (см.
    /// BookmarksSortOption.needsDirection), у сортировки по названию
    /// направление уже "зашито" в сам вариант (А-Я/Я-А).
    @AppStorage("bookmarks_sort_direction") private var sortDirection: BookmarksSortDirection = .newestFirst
    /// Число колонок в режиме "Плитка" — из Персонализации (см. CardsPerRow,
    /// тот же ключ, что читает MangaCatalogView.gridColumnsCount).
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto

    /// Применить папку, запрошенную извне (профиль «Списки тайтлов» → «Читаю»).
    private func applyPendingFolder() {
        guard let folder = catalogNav.pendingBookmarksFolder else { return }
        catalogNav.pendingBookmarksFolder = nil
        selectedFolderId = folder
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                titlesList
            }
            // Родной системный поиск (сам выезжает сверху, свой Cancel, своя
            // анимация — высоту менять нельзя, это контролирует iOS) +
            // .large — эталон App Store (см. тот же приём в MangaCatalogView):
            // крупный заголовок без фона в покое, системный блюр проявляется
            // при первом скролле, заголовок схлопывается в маленький.
            // Раньше здесь был самодельный всегда видимый TextField в
            // стеклянной капсуле со своим схлопыванием заголовка.
            .navigationTitle("Закладки")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Поиск в «\(selectedName)»")
            // Шестерёнка (Вид/Сортировка) + карандаш (порядок списков) —
            // по прямой просьбе. Карандаш — правее шестерёнки (порядок
            // объявления = порядок слева направо в группе .topBarTrailing).
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showViewSortSheet = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: Theme.pillControlHeight, height: Theme.pillControlHeight)
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFolderOrderSheet = true } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: Theme.pillControlHeight, height: Theme.pillControlHeight)
                    }
                    .glassEffect(.regular.interactive(), in: Circle())
                }
            }
            .onAppear { applyPendingFolder() }
            .onChange(of: catalogNav.openBookmarksRequest) { _, _ in applyPendingFolder() }
            .navigationDestination(for: BookmarkedTitle.self) { bm in
                MangaDetailView(slug: bm.slug, fallbackTitle: bm.title,
                                coverURL: bm.coverURL.flatMap(URL.init(string:)))
            }
            .alert("Новая папка", isPresented: $showNewFolder) {
                TextField("Название папки", text: $newFolderName)
                Button("Отмена", role: .cancel) { newFolderName = "" }
                Button("Создать") {
                    if let folder = store.createFolder(name: newFolderName) {
                        selectedFolderId = folder.id
                    }
                    newFolderName = ""
                }
            } message: {
                Text("Папка появится здесь и в списке «Добавить в».")
            }
            // Открывается долгим нажатием на строку тайтла (.contextMenu
            // в titlesList) — тот же лист выбора папки, что и на странице
            // тайтла, с моделью "отложенный выбор + Применить".
            .sheet(item: $editingBookmark) { bm in
                AddToFolderSheet(slug: bm.slug, title: bm.title, coverURL: bm.coverURL, rating: bm.rating)
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            .sheet(isPresented: $showFolderOrderSheet) {
                FolderOrderSheet(store: store)
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            .sheet(isPresented: $showViewSortSheet) {
                ViewSortSheet(viewMode: $viewMode, sortOption: $sortOption, sortDirection: $sortDirection)
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            // Полоска подкатегорий — снизу, над главной панелью. ВНУТРИ
            // NavigationStack (на корневом контенте), а не снаружи него: раньше
            // висела снаружи, чтобы обойти баг совместного расчёта с ВНЕШНИМ
            // инсетом самодельного BottomBar из старого RootView — но RootView
            // стал настоящим системным TabView, та причина отпала. А снаружи
            // NavigationStack полоска оставалась на экране ПОВЕРХ любого пуша
            // (карточки тайтла и т.д.), т.к. технически была соседом стека, а
            // не частью его корневого экрана — отсюда баг "подкатегории не
            // пропадают на карточке тайтла".
            .safeAreaInset(edge: .bottom, spacing: 0) {
                categoryMenu
                    // 20 — та же ширина/выравнивание, что и у главной панели.
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .tint(Theme.accent)
        // Подтягивает реальные закладки аккаунта (5 стандартных папок) при
        // открытии вкладки, если есть сессия — см. BookmarksStore.syncFromServer.
        // Без сессии ничего не делает (просто локальный список, как раньше).
        .task { await store.syncFromServer() }
    }

    private var currentTitles: [BookmarkedTitle] {
        let base = store.titles(in: selectedFolderId)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty ? base : base.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        return sorted(filtered)
    }

    // MARK: Сортировка (см. ViewSortSheet)

    private func sorted(_ titles: [BookmarkedTitle]) -> [BookmarkedTitle] {
        switch sortOption {
        case .titleAsc:
            return titles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc:
            return titles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .dateAdded:
            return sortedByDate(titles) { $0.addedAt }
        case .dateRead:
            return sortedByDate(titles) { store.readingProgress(forSlug: $0.slug)?.lastReadAt }
        case .chapterUpdated:
            // Нет подтверждённых данных о дате обновления глав ИМЕННО этого
            // тайтла на стороне закладок (BookmarkedTitle — лёгкий локальный
            // снимок, без этого поля) — пока не переставляем список, чтобы
            // не выдумывать несуществующие данные. Появится вместе с самими
            // данными (см. project.yml/CLAUDE.md — принцип "не полу-готовые
            // реализации").
            return titles
        }
    }

    private func sortedByDate(_ titles: [BookmarkedTitle], date: (BookmarkedTitle) -> Date?) -> [BookmarkedTitle] {
        titles.sorted { a, b in
            switch (date(a), date(b)) {
            case let (da?, db?): return sortDirection == .newestFirst ? da > db : da < db
            case (nil, .some): return false   // без даты — всегда в конец
            case (.some, nil): return true
            case (nil, nil): return false
            }
        }
    }

    private var selectedName: String {
        guard let id = selectedFolderId else { return "Все" }
        return store.allFolders.first { $0.id == id }?.name ?? "Все"
    }

    // MARK: Полоска подкатегорий (горизонтальный скролл, вместо аккордеона)

    // Переделано с "тап → разворачивается список" на постоянно видимую
    // горизонтальную полоску чипов — все подкатегории видны сразу, если не
    // влезают — скроллятся вбок. Активная горит акцентным (оранжевым) фоном.
    private var categoryMenu: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryChip(title: "Все", id: nil)
                ForEach(store.allFolders) { folder in
                    categoryChip(title: folder.name, id: folder.id)
                }
                addFolderChip
            }
        }
        .scrollIndicators(.hidden)
    }

    private func categoryChip(title: String, id: String?) -> some View {
        let active = selectedFolderId == id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selectedFolderId = id
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(active ? .semibold : .regular))
                Text("\(store.titlesCount(in: id))").font(.caption2.weight(.bold))
            }
            .foregroundStyle(active ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 14)
            // Высота выровнена по Theme.pillControlHeight — строго та же
            // высота, что у Фильтры/Сортировка в Каталоге.
            .frame(minHeight: Theme.pillControlHeight)
            .contentShape(Capsule())
            // .interactive() вернул именно здесь (в отличие от триггера
            // старого аккордеона, который чинили раньше) — это тот же
            // проверенный рецепт, что уже используется и работает в
            // MangaDetailView.tabButton: .regular.tint(...).interactive() для
            // активного состояния. Без .interactive() тонированное стекло
            // выглядит слишком плоским/сплошным — самому эффекту стекла
            // (блик, лёгкая прозрачность) как раз и нужен .interactive(),
            // просто так его и рисует Liquid Glass. Здесь это безопасно:
            // чип маленький и однородный (не широкая пилюля с разнородным
            // содержимым по краям, как было в старом триггере) — тот баг был
            // именно про это, а не про .interactive() как таковой.
            .glassEffect(active ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var addFolderChip: some View {
        Button {
            newFolderName = ""
            showNewFolder = true
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: Theme.pillControlHeight)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Список тайтлов

    @ViewBuilder
    private var titlesList: some View {
        if currentTitles.isEmpty {
            if store.isSyncing {
                // Идёт первая подтяжка закладок аккаунта — иначе пустой экран
                // на секунду выглядит как баг (будто ничего не подтянулось).
                // В режиме "Плитка" — скелетон-сетка под текущее число
                // колонок (та же идея, что и в Каталоге, см. skeletonGrid
                // там), в списке — как раньше, просто спиннер.
                if viewMode == .grid {
                    bookmarksSkeletonGrid
                } else {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Пусто",
                    systemImage: "bookmark",
                    description: Text("Добавляйте тайтлы через кнопку «Добавить в» на странице тайтла.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Список/плитка — см. ViewSortSheet (иконка шестерёнки).
            switch viewMode {
            case .list: listContent
            case .grid: gridContent
            }
        }
    }

    /// Зажать палец на тайтле — изменить папку/убрать из закладок, не
    /// открывая страницу тайтла. Общий для списка и плитки.
    @ViewBuilder
    private func bookmarkContextMenu(_ bm: BookmarkedTitle) -> some View {
        Button {
            editingBookmark = bm
        } label: {
            Label("Изменить папку", systemImage: "folder")
        }
        Button(role: .destructive) {
            store.remove(slug: bm.slug)
        } label: {
            Label("Убрать из закладок", systemImage: "bookmark.slash")
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(currentTitles) { bm in
                    NavigationLink(value: bm) { row(bm) }
                        .buttonStyle(.plain)
                        .contextMenu { bookmarkContextMenu(bm) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            // Запас снизу побольше обычного — гарантирует, что последний
            // тайтл не окажется под полоской подкатегорий, даже если
            // safe-area-резерв через NavigationStack посчитается неточно.
            // 90→120 — увеличили ещё немного.
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
    }

    // Число колонок — динамическое (см. cardsPerRow/CardsPerRow), 2/3/4/Авто(=3).
    private var gridColumnsCount: Int { cardsPerRow.columns }
    private static let gridSpacing: CGFloat = 12
    private static let gridHorizontalPadding: CGFloat = 12

    /// Та же архитектура, что и MangaCatalogView.grid (см. комментарий там
    /// и у MangaCardView.width): ширина карточки считается ОДИН раз через
    /// GeometryReader и кормит и GridItem(.fixed), и саму карточку — вместо
    /// LazyVGrid(.flexible())+.aspectRatio, которые могли разойтись на
    /// пиксель между соседними карточками. Ряды — явным stride, а не плоский
    /// ForEach: нужно видеть все карточки ряда сразу, чтобы решить, нужна ли
    /// ряду высота под 2-строчные название/прогресс (см. bookmarkGridCell).
    private var gridContent: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: Self.gridSpacing,
                containerPadding: Self.gridHorizontalPadding
            )
            let titles = currentTitles
            let rows = stride(from: 0, to: titles.count, by: gridColumnsCount).map { start in
                Array(titles[start..<min(start + gridColumnsCount, titles.count)])
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                        let twoLineTitle = rowItems.contains {
                            Self.gridTitleLineCount($0.title, width: cardWidth) > 1
                        }
                        let twoLineProgress = rowItems.contains {
                            Self.gridProgressLineCount(progressText(for: $0), width: cardWidth) > 1
                        }
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            ForEach(rowItems) { bm in
                                NavigationLink(value: bm) {
                                    bookmarkGridCell(bm, width: cardWidth,
                                                      twoLineTitle: twoLineTitle, twoLineProgress: twoLineProgress)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { bookmarkContextMenu(bm) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Скелетон-сетка на время первой подтяжки закладок аккаунта (см.
    /// titlesList/store.isSyncing) — та же ширина карточки, что и у
    /// настоящей плитки, шиммер-плейсхолдеры вместо реальных обложек/текста.
    /// 12 ячеек с запасом — не привязано к реальному количеству закладок
    /// (его ещё не знаем).
    private var bookmarksSkeletonGrid: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: Self.gridSpacing,
                containerPadding: Self.gridHorizontalPadding
            )
            let placeholderCount = 12
            let rows = stride(from: 0, to: placeholderCount, by: gridColumnsCount).map { start in
                Array(start..<min(start + gridColumnsCount, placeholderCount))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowIndices in
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            ForEach(rowIndices, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    SkeletonBox()
                                        .frame(width: cardWidth, height: (cardWidth * 3 / 2).rounded())
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    SkeletonBar(width: cardWidth * 0.85, height: 12)
                                    SkeletonBar(width: cardWidth * 0.5, height: 10)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// "Продолжить N/M" / "Продолжить: Том X, Глава Y" / "Начать чтение" —
    /// тот же формат, что и в списке (см. row(_:) ниже), только с явным
    /// "Начать чтение" вместо "Открыть" для карточек плитки, по прямой просьбе.
    private func progressText(for bm: BookmarkedTitle) -> String {
        guard let p = store.readingProgress(forSlug: bm.slug) else { return "Начать чтение" }
        return p.totalChapters > 0
            ? "Продолжить \(p.lastChapterNumber)/\(p.totalChapters)"
            : "Продолжить: Том \(p.lastChapterVolume), Глава \(p.lastChapterNumber)"
    }

    /// Карточка плитки закладок: обложка 2:3 с тремя чипами поверх (глава
    /// слева сверху / твоя оценка справа сверху / "..." смена папки справа
    /// снизу, все три — см. helpers ниже), название (макс 2 строки) +
    /// прогресс чтения (макс 2 строки). twoLineTitle/twoLineProgress считает
    /// родительский ряд целиком (см. gridContent) — та же логика, что и в
    /// MangaCardView.rowNeedsTwoLines: у всех карточек ряда одна и та же
    /// минимальная высота текстового блока, сами строки внутри каждой
    /// карточки всегда стоят вплотную, недостающая высота уходит пустым
    /// местом снизу, а не зазором между названием и прогрессом.
    private func bookmarkGridCell(_ bm: BookmarkedTitle, width: CGFloat, twoLineTitle: Bool, twoLineProgress: Bool) -> some View {
        let progress = store.readingProgress(forSlug: bm.slug)
        return VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: bm.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: width, height: (width * 3 / 2).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            .overlay(alignment: .topLeading) { chapterChip(progress) }
            .overlay(alignment: .topTrailing) { myRatingChip(bm.myRating) }
            .overlay(alignment: .bottomTrailing) { folderMenuChip(bm) }

            VStack(alignment: .leading, spacing: Self.gridTextSpacing) {
                Text(bm.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .topLeading)

                Text(progressText(for: bm))
                    .font(.caption2)
                    .foregroundStyle(progress != nil ? Theme.accent : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .topLeading)
            }
            .frame(width: width, alignment: .top)
            .frame(minHeight: Self.gridTextBlockHeight(twoLineTitle: twoLineTitle, twoLineProgress: twoLineProgress), alignment: .top)
        }
        .frame(width: width, alignment: .top)
    }

    // MARK: Точный расчёт высоты текстового блока плитки (см. bookmarkGridCell)

    private static var gridTitleFont: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    private static var gridProgressFont: UIFont { UIFont.preferredFont(forTextStyle: .caption2) }
    private static var gridTextSpacing: CGFloat { gridTitleFont.leading }

    private static func gridLineCount(_ text: String, width: CGFloat, font: UIFont) -> Int {
        guard width > 0 else { return 1 }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return min(max(Int((box.height / font.lineHeight).rounded(.up)), 1), 2)
    }
    private static func gridTitleLineCount(_ text: String, width: CGFloat) -> Int {
        gridLineCount(text, width: width, font: gridTitleFont)
    }
    private static func gridProgressLineCount(_ text: String, width: CGFloat) -> Int {
        gridLineCount(text, width: width, font: gridProgressFont)
    }
    private static func gridTextBlockHeight(twoLineTitle: Bool, twoLineProgress: Bool) -> CGFloat {
        let titleHeight = gridTitleFont.lineHeight * (twoLineTitle ? 2 : 1)
        let progressHeight = gridProgressFont.lineHeight * (twoLineProgress ? 2 : 1)
        return (titleHeight + gridTextSpacing + progressHeight).rounded(.up)
    }

    // MARK: Чипы поверх обложки в плитке

    /// Номер текущей/последней открытой главы — слева сверху, только в
    /// плитке. Ничего не рисует, если прогресса ещё нет (тайтл не открывали).
    @ViewBuilder
    private func chapterChip(_ progress: ReadingProgress?) -> some View {
        if let progress {
            Text("Глава \(progress.lastChapterNumber)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
    }

    /// Твоя личная оценка тайтла (см. BookmarkedTitle.myRating) — справа
    /// сверху. В отличие от RatingChip (оценка САЙТА, 3 фиксированные зоны
    /// цвета красный/жёлтый/зелёный) здесь НЕПРЕРЫВНЫЙ градиент красный→
    /// зелёный по значению 0-10, по прямой просьбе. Ничего не рисует, если
    /// оценка ещё не подтянулась (см. BookmarksStore.setMyRating).
    @ViewBuilder
    private func myRatingChip(_ rating: Int?) -> some View {
        if let rating {
            Text("\(rating)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(personalRatingColor(rating), in: Capsule())
                .padding(6)
        }
    }

    /// "..." — быстрая смена папки без захода на страницу тайтла и без
    /// долгого нажатия, справа снизу. .highPriorityGesture (а не Button) —
    /// карточка целиком лежит внутри NavigationLink(value:), обычный Button
    /// внутри его лейбла не всегда надёжно перехватывает тап отдельно от
    /// самой навигации; .highPriorityGesture гарантированно забирает тап
    /// раньше NavigationLink, не запуская переход на карточку тайтла.
    private func folderMenuChip(_ bm: BookmarkedTitle) -> some View {
        Image(systemName: "ellipsis")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.55), in: Circle())
            .padding(6)
            .contentShape(Circle())
            .highPriorityGesture(TapGesture().onEnded { editingBookmark = bm })
    }

    /// Соотношение сторон и закругление обложки — эталон Каталог/Новинки
    /// (см. MangaCardView.cover: 2:3, radius 16), раньше здесь было 78×109
    /// (≈5:7, чуть уже) и radius 12 — рассинхрон с остальным приложением.
    /// Увеличена и вплотную к краю подложки (была с отступом 10 со всех
    /// сторон, как у обычного .padding()) — тот же приём, что у
    /// continueReadingCard/updateRow: паддинг только у текстовой колонки и
    /// справа, радиус обложки = радиусу подложки (16, было 18) — угол в угол.
    static let bookmarkCoverWidth: CGFloat = 80
    static let bookmarkCoverHeight: CGFloat = (bookmarkCoverWidth * 3 / 2).rounded()

    private func row(_ bm: BookmarkedTitle) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: bm.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.bookmarkCoverWidth, height: Self.bookmarkCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            // Единый бэйдж оценки (см. RatingChip) — тот же стиль/цвет, что и
            // в каталоге/карточке тайтла, теперь и в закладках.
            .overlay(alignment: .topTrailing) { RatingChip(rating: bm.rating) }

            // Тот же размер текста, что и в «Новое» (NotificationsView.row) —
            // .subheadline для основной строки, .caption2 для второстепенной
            // (было .system(size: 16, weight: .medium) / .caption — крупнее
            // и другой шрифт, экраны выглядели по-разному при одинаковой
            // структуре, попросили "одинаковые по форме").
            VStack(alignment: .leading, spacing: 4) {
                Text(bm.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let p = store.readingProgress(forSlug: bm.slug) {
                    // totalChapters может быть 0 — если прогресс подтянут из
                    // реальной истории аккаунта (см. BookmarksStore.
                    // syncHistoryFromServer), а не из живого списка глав,
                    // открытого в этом приложении. "N/0" выглядело бы криво —
                    // тогда просто показываем номер главы без знаменателя.
                    Text(p.totalChapters > 0
                         ? "Продолжить \(p.lastChapterNumber)/\(p.totalChapters)"
                         : "Продолжить: Том \(p.lastChapterVolume), Глава \(p.lastChapterNumber)")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Открыть").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.trailing, 12)
        .frame(height: Self.bookmarkCoverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Вид/Сортировка (см. BookmarksView.ViewSortSheet)

/// Список/плитка — см. BookmarksView.gridContent/listContent.
enum BookmarksViewMode: String {
    case list, grid
}

/// Поле сортировки списка закладок — см. BookmarksView.sorted(_:).
enum BookmarksSortOption: String, CaseIterable, Identifiable {
    case titleAsc, titleDesc, dateAdded, chapterUpdated, dateRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleAsc:       return "По названию (А-Я)"
        case .titleDesc:      return "По названию (Я-А)"
        case .dateAdded:      return "По дате добавления"
        case .chapterUpdated: return "Дате обновления глав"
        case .dateRead:       return "Дате чтения"
        }
    }

    /// У сортировки по названию направление уже "зашито" в сам вариант
    /// (А-Я/Я-А) — общий переключатель "сначала новые/старые" (см.
    /// BookmarksSortDirection) имеет смысл только у полей-дат.
    var needsDirection: Bool {
        switch self {
        case .titleAsc, .titleDesc: return false
        case .dateAdded, .chapterUpdated, .dateRead: return true
        }
    }
}

/// Направление для полей-дат (см. BookmarksSortOption.needsDirection).
enum BookmarksSortDirection: String, CaseIterable, Identifiable {
    case newestFirst, oldestFirst

    var id: String { rawValue }

    var title: String { self == .newestFirst ? "Сначала новые" : "Сначала старые" }
}

/// Щит редактирования порядка списков (иконка карандаша в шапке Закладок) —
/// драг для перестановки, порядок определяет порядок чипов внизу
/// (BookmarksView.categoryMenu читает store.allFolders в этом же порядке).
/// Плюс кнопка создания новой папки — по прямой просьбе ("и в этом щите
/// ещё кнопка создать новую папку").
private struct FolderOrderSheet: View {
    @ObservedObject var store: BookmarksStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.allFolders) { folder in
                    Text(folder.name)
                        .foregroundStyle(Theme.textPrimary)
                        .listRowBackground(Theme.surface)
                }
                .onMove { from, to in store.moveFolders(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            // Список всегда в режиме перестановки — экран только для этого,
            // отдельный переключатель "Изменить"/"Готово" не нужен. Без
            // .onDelete кнопка удаления строки не появляется — только ручка
            // перетаскивания.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Порядок списков")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .alert("Новая папка", isPresented: $showNewFolder) {
                TextField("Название папки", text: $newFolderName)
                Button("Отмена", role: .cancel) { newFolderName = "" }
                Button("Создать") {
                    store.createFolder(name: newFolderName)
                    newFolderName = ""
                }
            } message: {
                Text("Папка появится здесь и в списке «Добавить в».")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Щит "Вид"/"Сортировка" (иконка шестерёнки в шапке Закладок).
private struct ViewSortSheet: View {
    @Binding var viewMode: BookmarksViewMode
    @Binding var sortOption: BookmarksSortOption
    @Binding var sortDirection: BookmarksSortDirection

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    card {
                        sectionHeader("Вид")
                        divider
                        selectableRow(title: "Список", icon: "list.bullet", isSelected: viewMode == .list) {
                            viewMode = .list
                        }
                        divider
                        selectableRow(title: "Плитка", icon: "square.grid.2x2", isSelected: viewMode == .grid) {
                            viewMode = .grid
                        }
                    }

                    card {
                        sectionHeader("Сортировка")
                        ForEach(BookmarksSortOption.allCases) { option in
                            divider
                            selectableRow(title: option.title, isSelected: sortOption == option) {
                                sortOption = option
                            }
                        }
                        if sortOption.needsDirection {
                            divider
                            ForEach(BookmarksSortDirection.allCases) { direction in
                                selectableRow(title: direction.title, isSelected: sortDirection == direction) {
                                    sortDirection = direction
                                }
                                if direction != BookmarksSortDirection.allCases.last {
                                    divider
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var divider: some View {
        Divider().overlay(Theme.separator).padding(.leading, 16)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func selectableRow(title: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                }
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Радиус — тот же, что и у карточек в разделе "Меню" (см.
    // SideMenuView.cardCornerRadius) — тот же эталон, что и в
    // PersonalizationSettingsView.card.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    BookmarksView().preferredColorScheme(.dark)
}
