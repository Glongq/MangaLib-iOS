import SwiftUI
import UIKit

/// Палитра читалки под выбранную тему (0 тёмная / 1 светлая / 2 системная).
/// Тексты и иконки читалки и её меню (главы/настройки) берут цвета отсюда,
/// чтобы не сливаться с фоном при светлой теме.
struct ReaderPalette {
    let isLight: Bool
    /// Фон под страницами: тёмный — чёрный, светлый — чуть серый (не чисто белый).
    var pageBackground: Color { isLight ? Color(white: 0.93) : .black }
    /// Фон меню (главы/настройки/комментарии).
    ///
    /// Тёмная ветка берёт цвета из Theme.Dark (ФИКСИРОВАННАЯ тёмная палитра),
    /// а не из Theme.xxx напрямую — тема читалки независима от белой/чёрной
    /// темы всего приложения (см. Theme.swift/ThemeManager), поэтому не
    /// должна меняться, если пользователь переключит тему приложения на белую.
    ///
    /// Светлая ветка — теперь буквально Theme.Light (было — отдельные
    /// приблизительные серые: .white/Color(white: 0.12/0.45/0.94)/
    /// black.opacity(0.10), на глаз чуть-чуть, "на пару тонов" отличались от
    /// белой темы приложения) — по прямой просьбе: кнопки/поле ввода/
    /// подложки комментариев в читалке должны выглядеть ТОЧНО как в карточке
    /// тайтла. Независимость самого ПЕРЕКЛЮЧАТЕЛЯ темы читалки (см. doc-
    /// comment выше про Theme.Dark) этим не нарушается — она про то, ЧТО
    /// выбрано (свет/тьма/системная, отдельно от темы приложения), а не про
    /// то, какие именно RGB у "светлого". pageBackground (сам холст страницы)
    /// НЕ тронут — так и остаётся своим чуть серым, не белым, тоном.
    var background: Color { isLight ? Theme.Light.background : Theme.Dark.background }
    var foreground: Color { isLight ? Theme.Light.textPrimary : .white }
    var secondary: Color { isLight ? Theme.Light.textSecondary : Theme.Dark.textSecondary }
    var surface: Color { isLight ? Theme.Light.surfaceElevated : Theme.Dark.surfaceElevated }
    var separator: Color { isLight ? Theme.Light.separator : Theme.Dark.separator }

    static func make(theme: Int, system: ColorScheme) -> ReaderPalette {
        switch theme {
        case 1: return ReaderPalette(isLight: true)
        case 2: return ReaderPalette(isLight: system == .light)
        default: return ReaderPalette(isLight: false)
        }
    }
}

/// Позиция одной страницы вертикальной ленты (её midY в координатах скролла)
/// — используется, чтобы определить, какая страница сейчас по ЦЕНТРУ экрана
/// (см. VerticalPagePositionKey/verticalReader), а не просто первой появилась
/// на экране (onAppear срабатывает уже при показе даже краешка сверху).
private struct VerticalPagePosition: Equatable {
    let segIndex: Int
    let pageIndex: Int
    let midY: CGFloat
}

private struct VerticalPagePositionKey: PreferenceKey {
    static var defaultValue: [VerticalPagePosition] = []
    static func reduce(value: inout [VerticalPagePosition], nextValue: () -> [VerticalPagePosition]) {
        value.append(contentsOf: nextValue())
    }
}

/// Команда для листа профиля (см. MangaReaderView.selectedTeam/teamsCreditChip) —
/// облегчённая обёртка над ChapterTeam: slugURL там Optional (нужен
/// non-optional для TeamView), .sheet(item:) нужен Identifiable.
private struct SelectedTeam: Identifiable {
    let id: Int
    let slugURL: String
    let name: String
    let coverURL: URL?
}

/// Полноэкранная читалка: горизонтальное листание страниц, тап переключает интерфейс.
struct MangaReaderView: View {

    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    /// Тег 1 — первая РЕАЛЬНАЯ страница главы (тег 0 зарезервирован под
    /// prevTriggerPage, см. pager/singlePageView ниже).
    @State private var currentPage = 1
    /// true — следующая успешно загруженная глава должна поставить
    /// currentPage на её endPage (свайпнули НАЗАД, "Конец" прошлой главы), а
    /// не на страницу 1 (обычный вход/переход вперёд/скачок из списка глав).
    /// См. openPrevious()/applyLandingIfNeeded().
    @State private var pendingLandOnEnd = false
    /// currentIndex, для которого уже применена посадка currentPage (см.
    /// applyLandingIfNeeded) — идемпотентность вместо расчёта "на изменение
    /// pages.count": при переходе на главу с БЫСТРЫМ путём (уже в pageCache,
    /// см. ReaderViewModel.goTo) новое число страниц может СЛУЧАЙНО совпасть
    /// со старым, и тогда .onChange(of: pages.count) вообще не сработал бы —
    /// сравнение "применяли ли уже для ЭТОГО currentIndex" работает всегда.
    @State private var pagesAppliedForIndex: Int?
    @State private var showUI = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showComments = false
    /// Команда, по чипу "Над главой работали" на экране конца главы (см.
    /// teamsCreditChip) — открывает её профиль (TeamView) листом.
    @State private var selectedTeam: SelectedTeam?
    /// Лист "Оценить перевод" (см. chapterActionButtons/
    /// TranslationRatingSheet).
    @State private var showTranslationRating = false
    /// Индексы страниц (горизонтальный режим), для которых пользователь уже
    /// докрутил вниз до блока комментариев — сам блок ChapterCommentsSheet
    /// рендерится (и начинает грузить данные) только для них, а не для всех
    /// страниц главы сразу. Сбрасывается при смене главы (см. onChange
    /// currentIndex) — индексы считаются от pages ТЕКУЩЕЙ главы.
    @State private var revealedCommentPages: Set<Int> = []
    /// Та же логика «раскрытия по жесту», что и revealedCommentPages, но для
    /// экрана конца главы (endPage) — блок комментариев там рендерится (и
    /// начинает грузить данные) только после того, как реально доскроллили
    /// до него, а не сразу при показе endPage. Сбрасывается при смене главы.
    @State private var endCommentsRevealed = false
    /// Зумит ли пользователь текущую страницу сейчас — пока да, внешний
    /// вертикальный ScrollView страницы (см. horizontalPage) отключён, чтобы
    /// не конкурировать с панорамой зума за один и тот же вертикальный драг.
    @State private var isCurrentPageZoomed = false
    /// Залита ли кнопка-закладка белым (bookmark.fill). Локальное визуальное
    /// состояние: тап переключает, переход на след. главу сбрасывает.
    @State private var bookmarkFilled = false

    /// Режим вписывания: false — по высоте (вся страница), true — по ширине.
    /// Ключ теперь параметризован ТИПОМ тайтла (Манга/Манхва/...), а не общий
    /// на все читалки: у манхвы (вертикальный вебтун-формат) по умолчанию
    /// вписывание по ширине, у обычной манги — по высоте (разворот целиком),
    /// как попросили. Значение по умолчанию считается ОДИН раз в init() (см.
    /// Self.defaultFitWidth ниже) и дальше живёт как обычная @AppStorage —
    /// пользователь может переопределить его в настройках, и это запомнится
    /// отдельно для этого типа тайтлов.
    @AppStorage private var fitWidth: Bool

    /// Предзагрузка страниц вперёд — общая для всех читалок настройка,
    /// количество страниц (1/3/5), всегда включена (нет варианта "выкл").
    @AppStorage("reader_preload_count") private var preloadCount = 3

    /// Сервер картинок — при смене страница сбрасывается и грузится с нового
    /// сервера (см. .id(serverChoice) у content).
    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0
    /// Тип листания (пока просто селектор, поведение не меняется): 0 — свайпами
    /// влево, 1 — вверх, 2 — вправо.
    @AppStorage("reader_page_mode") private var pageMode = 0
    /// Тема читалки: 0 — тёмная, 1 — светлая, 2 — системная.
    @AppStorage("reader_theme") private var readerTheme = 0
    /// Зум двойным нажатием (тумблер).
    @AppStorage("reader_double_tap_zoom") private var doubleTapZoom = true
    /// Скрыть номер страницы (тумблер).
    @AppStorage("reader_hide_page_number") private var hidePageNumber = false
    /// «Переключение страниц» — выключить листание свайпом.
    @AppStorage("reader_disable_swipe") private var disableSwipe = false
    /// «Переключение страниц» — плавное (с анимацией) листание; выкл = мгновенно.
    @AppStorage("reader_smooth_paging") private var smoothPaging = true
    /// Отступ между картинками в вертикальном (непрерывном) режиме, px.
    @AppStorage("reader_vertical_gap") private var verticalGap: Double = 0

    /// Текущая страница в вертикальном режиме (для номера/комментариев) —
    /// обновляется, когда очередная картинка попадает в область просмотра.
    @State private var verticalPage = 1

    /// Зум вертикальной ленты через РЕАЛЬНУЮ ширину колонки (не transform):
    /// колонка становится шире экрана → включается нативная горизонтальная
    /// прокрутка, и панорама увеличенной ленты идёт нативным скроллом (плавно,
    /// без ручного offset и без дёрганья). `vScale` — текущий масштаб,
    /// `vScaleBase` — зафиксированный на конце пинча.
    @State private var vScale: CGFloat = 1
    @State private var vScaleBase: CGFloat = 1

    /// Тап по левой/правой части листает, по центру — показывает интерфейс
    /// (по умолчанию вкл). Ширина краевых зон — доля экрана.
    @Environment(\.colorScheme) private var systemColorScheme

    /// Палитра под выбранную тему — цвета фона/текста/иконок читалки и её меню.
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }
    private var readerIsLight: Bool { palette.isLight }
    private var readerBackground: Color { palette.pageBackground }
    /// Цвет текста/иконок читалки (белый на тёмной, тёмный на светлой).
    private var fg: Color { palette.foreground }

    init(slug: String,
         chapters: [ChapterItem],
         startIndex: Int,
         mangaId: Int? = nil,
         mangaTitle: String? = nil,
         mangaTypeName: String? = nil,
         coverURL: String? = nil,
         preferredBranchId: Int? = nil,
         siteId: Int? = nil) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(
            slug: slug, chapters: chapters, startIndex: startIndex,
            mangaId: mangaId, mangaTitle: mangaTitle, coverURL: coverURL,
            preferredBranchId: preferredBranchId, siteId: siteId
        ))
        self.mangaTitle = mangaTitle
        _fitWidth = AppStorage(wrappedValue: Self.defaultFitWidth(forType: mangaTypeName), Self.fitWidthKey(forType: mangaTypeName))
    }

    private let mangaTitle: String?

    /// "Манхва" — единственный тип, для которого по умолчанию включено
    /// вписывание по ширине (вертикальный скролл), как явно попросили;
    /// всё остальное (в т.ч. обычная "Манга") — по высоте.
    private static func defaultFitWidth(forType typeName: String?) -> Bool {
        typeName == "Манхва"
    }

    /// Отдельный ключ UserDefaults на тип тайтла — так ручной выбор режима
    /// для манхвы не перетирает выбор для обычной манги и наоборот.
    private static func fitWidthKey(forType typeName: String?) -> String {
        "reader_fit_width_\(typeName ?? "unknown")"
    }

    var body: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            content
                // Смена сервера картинок → пересоздаём страницы, чтобы они
                // сбросились и загрузились с ВЫБРАННОГО сервера.
                .id(serverChoice)

            // Интерфейс читалки — плавное появление/затухание с блюром (а не
            // резкое вкл/выкл). Всегда в дереве, управляется opacity/blur.
            overlayUI
                .opacity(showUI ? 1 : 0)
                .blur(radius: showUI ? 0 : 12)
                .allowsHitTesting(showUI)
                .animation(.easeInOut(duration: 0.16), value: showUI)

            // Индикатор текущей страницы — виден ВСЕГДА (даже при скрытом
            // интерфейсе), в обоих режимах листания. При скрытии интерфейса
            // плавно опускается ниже, при показе — поднимается над нижней
            // панелью. В вертикальном режиме номер страницы считается по
            // центру экрана (см. verticalReader/onPreferenceChange), а не
            // по первому появлению картинки.
            if !hidePageNumber, pageBubbleTotal > 0,
               (pageMode == 1 || (currentPage > 0 && currentPage <= viewModel.pages.count)) {
                VStack {
                    Spacer()
                    pageBubble
                }
                .padding(.bottom, showUI ? 96 : 34)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.16), value: showUI)
            }

            // Тост закладки — отдельным слоем поверх всего, ВНЕ
            // GlassEffectContainer (иначе стекло названия и тоста «перетекает» и
            // получается рывок вбок). Приезжает сверху и так же плавно уезжает
            // вверх — 1-в-1 как «Загрузка начата».
            if let toast = viewModel.bookmarkToast {
                VStack {
                    BookmarkAddedToast(
                        text: toast,
                        systemImage: toast.localizedCaseInsensitiveContains("убрано")
                            ? "bookmark.slash.fill" : "bookmark.fill"
                    )
                    .padding(.top, 4)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            // Инлайн-панель комментариев к текущей странице — НЕ sheet и не
            // отдельная подложка: тот же фон читалки, выезжает снизу. Только
            // вертикальный режим (кнопка "text.bubble" в bottomBar) — в
            // горизонтальном комментарии открываются иначе, продолжением
            // страницы вниз обычным скроллом (см. horizontalPage). Закрытие —
            // «хваталкой» сверху панели.
            if showComments, let ch = viewModel.currentChapter {
                let pageNo = pageMode == 1
                    ? verticalPage
                    : max(min(currentPage, viewModel.pages.count), 1)
                ChapterCommentsSheet(
                    chapterId: ch.id,
                    postPage: pageNo,
                    siteId: viewModel.siteId,
                    chapterNumber: ch.number,
                    onClose: { withAnimation(.easeInOut(duration: 0.25)) { showComments = false } }
                )
                .transition(.move(edge: .bottom))
                .zIndex(30)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: viewModel.bookmarkToast)
        // Только НИЖНЯЯ safe area игнорируется (как в RootView.swift) — низ
        // safe area на Face ID экранах даёт ~34pt от истинного края из-за
        // home indicator, и .padding(.bottom, 20) у bottomBar раньше
        // добавлялся ПОВЕРХ этого — теперь отсчитывается от истинного края.
        // ВЕРХ сознательно НЕ игнорируем — topBar вернули к прежнему виду
        // (просили не трогать), а его старые отступы рассчитаны именно на
        // то, что верх остаётся в safe area (не заезжает под "выемку"/статус-бар).
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(!showUI)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if pageMode == 1 {
                await viewModel.startVertical()
            } else if viewModel.pages.isEmpty {
                await viewModel.load()
            }
            applyLandingIfNeeded()
        }
        // Живое переключение режима листания.
        .onChange(of: pageMode) { _, mode in
            Task {
                if mode == 1 {
                    await viewModel.startVertical()
                } else {
                    await viewModel.load()
                }
                applyLandingIfNeeded()
            }
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            // На новой главе заливка закладки возвращается «как была».
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkFilled = false }
            // Индексы revealedCommentPages относились к pages ПРЕДЫДУЩЕЙ главы.
            revealedCommentPages.removeAll()
            endCommentsRevealed = false
            isCurrentPageZoomed = false
            // Быстрый путь (кэш соседей/офлайн, см. ReaderViewModel.goTo) —
            // pages уже готовы к этому моменту (goTo наполняет их СИНХРОННО,
            // без await), можно применять посадку сразу. Сетевой путь ещё
            // пуст — применится через onChange(pages.count) ниже.
            applyLandingIfNeeded()
        }
        .onChange(of: currentPage) { _, page in
            isCurrentPageZoomed = false
            // Долистали до страницы-триггера — открываем след./прошлую главу
            // (работает и в режиме «выключить перелистывание», где листаем тапом).
            if page == viewModel.pages.count + 2 { openNext() }
            else if page == 0 { openPrevious() }
        }
        // Подстраховка на сетевой путь (см. onChange(currentIndex) выше) —
        // срабатывает, когда pages наконец реально наполнились.
        .onChange(of: viewModel.pages.count) { _, _ in
            applyLandingIfNeeded()
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(
                chapters: viewModel.chapters,
                currentIndex: viewModel.currentIndex,
                currentBranchId: viewModel.preferredBranchId,
                onSelect: { index in
                    showChapters = false
                    // Переход из списка глав — всегда на страницу 1, не на
                    // "Конец" (см. pendingLandOnEnd/openPrevious).
                    pendingLandOnEnd = false
                    Task {
                        if pageMode == 1 { await viewModel.goToVertical(index: index) }
                        else { await viewModel.goTo(index: index) }
                    }
                },
                onSelectTranslator: { branchId in
                    Task { await viewModel.setPreferredBranch(branchId, verticalMode: pageMode == 1) }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                fitWidth: $fitWidth,
                preloadCount: $preloadCount,
                pageMode: $pageMode,
                readerTheme: $readerTheme,
                doubleTapZoom: $doubleTapZoom,
                hidePageNumber: $hidePageNumber,
                disableSwipe: $disableSwipe,
                smoothPaging: $smoothPaging,
                verticalGap: $verticalGap
            )
        }
        .sheet(item: $selectedTeam) { team in
            NavigationStack {
                TeamView(slugURL: team.slugURL, fallbackName: team.name, coverURL: team.coverURL)
            }
        }
        .sheet(isPresented: $showTranslationRating) {
            TranslationRatingSheet(viewModel: viewModel)
        }
        .preferredColorScheme(readerTheme == 2 ? nil : (readerIsLight ? .light : .dark))
    }

    // MARK: Предзагрузка страниц

    /// Качает картинки следующих `preloadCount` страниц вперёд (относительно
    /// `page`) в фоне — см. RemoteImageLoader.preload. Настройка всегда
    /// включена, регулируется только сколько страниц вперёд (1/3/5).
    private func preloadUpcoming(from page: Int) {
        guard preloadCount > 0 else { return }
        let start = page + 1
        let end = min(start + preloadCount, viewModel.pages.count)
        guard start < end else { return }
        for index in start..<end {
            RemoteImageLoader.preload(candidates: viewModel.imageURLs(for: viewModel.pages[index]))
        }
    }

    // MARK: Контент (страницы)

    @ViewBuilder
    private var content: some View {
        if pageMode == 1 {
            verticalContent
        } else if viewModel.isLoading && viewModel.pages.isEmpty {
            ProgressView().tint(fg)
        } else if let error = viewModel.errorMessage, viewModel.pages.isEmpty {
            errorView(error) { Task { await viewModel.load() } }
        } else if viewModel.pages.isEmpty {
            Text("Нет страниц").foregroundStyle(fg)
        } else if disableSwipe {
            // Свайп-листание выключено: показываем ТОЛЬКО текущую страницу
            // (без TabView, поэтому свайпом не листается), листаем тапами по краям.
            singlePageView
        } else {
            pager
        }
    }

    private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(message).multilineTextAlignment(.center).font(.footnote)
            Button("Повторить", action: retry)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .foregroundStyle(fg)
        .padding(32)
    }

    // MARK: Вертикальный (непрерывный) режим

    @ViewBuilder
    private var verticalContent: some View {
        if viewModel.isLoading && viewModel.segments.isEmpty {
            ProgressView().tint(fg)
        } else if let error = viewModel.errorMessage, viewModel.segments.isEmpty {
            errorView(error) { Task { await viewModel.startVertical() } }
        } else if viewModel.segments.isEmpty {
            Text("Нет страниц").foregroundStyle(fg)
        } else {
            verticalReader
        }
    }

    private var verticalReader: some View {
        GeometryReader { geo in
            // Двухосевой нативный скролл: вертикаль — листание ленты, горизонталь
            // включается только при зуме (когда колонка шире экрана). Панорама
            // увеличенной ленты — нативным скроллом, поэтому плавно, без дёрганья.
            // .scrollBounceBehavior(.basedOnSize) убирает боковой дрейф на 1×,
            // когда контент по ширине ровно равен экрану.
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: CGFloat(verticalGap)) {
                    ForEach(viewModel.segments) { seg in
                        ForEach(Array(seg.pages.enumerated()), id: \.offset) { pageIndex, page in
                            VerticalPageImage(candidates: viewModel.imageURLs(for: page), width: page.width, height: page.height)
                                .background(
                                    GeometryReader { pageGeo in
                                        Color.clear.preference(
                                            key: VerticalPagePositionKey.self,
                                            value: [VerticalPagePosition(
                                                segIndex: seg.index,
                                                pageIndex: pageIndex,
                                                midY: pageGeo.frame(in: .named("verticalReaderScroll")).midY
                                            )]
                                        )
                                    }
                                )
                        }
                        // Футер конца главы — при его появлении догружаем следующую.
                        chapterEndFooter(seg)
                            .onAppear { Task { await viewModel.appendNext() } }
                    }
                    if viewModel.isAppending {
                        ProgressView().tint(fg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .frame(width: geo.size.width * vScale)
            }
            .coordinateSpace(name: "verticalReaderScroll")
            // Номер страницы/главы для индикатора считаем по той странице,
            // чей центр ближе всего к центру ЭКРАНА — не по первой, что
            // просто появилась в кадре (см. VerticalPagePosition выше).
            .onPreferenceChange(VerticalPagePositionKey.self) { positions in
                let viewportCenter = geo.size.height / 2
                guard let nearest = positions.min(by: {
                    abs($0.midY - viewportCenter) < abs($1.midY - viewportCenter)
                }) else { return }
                if nearest.segIndex != viewModel.currentIndex {
                    viewModel.markCurrentChapter(nearest.segIndex)
                }
                if verticalPage != nearest.pageIndex + 1 {
                    verticalPage = nearest.pageIndex + 1
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in vScale = min(max(vScaleBase * v.magnification, 1), 4) }
                    .onEnded { _ in
                        if vScale < 1.02 {
                            withAnimation(.easeOut(duration: 0.15)) { vScale = 1 }
                            vScaleBase = 1
                        } else {
                            vScaleBase = vScale
                        }
                    }
            )
            .onTapGesture(count: 2) {
                let target: CGFloat = vScale > 1 ? 1 : 2
                withAnimation(.easeOut(duration: 0.2)) { vScale = target }
                vScaleBase = target
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
        }
        .ignoresSafeArea()
    }

    private func nextChapterAfter(_ index: Int) -> ChapterItem? {
        let n = index + 1
        return viewModel.chapters.indices.contains(n) ? viewModel.chapters[n] : nil
    }

    // Разделитель конца главы в ленте: «Конец · …», ниже — что дальше.
    private func chapterEndFooter(_ seg: ReaderViewModel.ReaderSegment) -> some View {
        VStack(spacing: 6) {
            Text("Конец · \(seg.chapter.shortTitle)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fg.opacity(0.85))
            if let next = nextChapterAfter(seg.index) {
                Text("Далее: \(next.titleOrShort)")
                    .font(.caption).foregroundStyle(fg.opacity(0.6))
                    .multilineTextAlignment(.center)
            } else {
                Text("Это последняя доступная глава")
                    .font(.caption).foregroundStyle(fg.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background(readerBackground)
    }

    /// Одна текущая страница без пейджера (режим «выключить перелистывание»).
    /// Схема тегов (та же, что и у pager ниже — общая currentPage): 0 —
    /// prevTriggerPage, 1...pages.count — реальные страницы, pages.count+1 —
    /// endPage, pages.count+2 — nextTriggerPage.
    @ViewBuilder
    private var singlePageView: some View {
        if currentPage == 0 {
            prevTriggerPage
        } else if currentPage <= viewModel.pages.count {
            horizontalPage(index: currentPage - 1, page: viewModel.pages[currentPage - 1])
                .id(currentPage)
        } else if currentPage == viewModel.pages.count + 1 {
            endPage
        } else {
            nextTriggerPage
        }
    }

    private var nextChapter: ChapterItem? {
        let n = viewModel.currentIndex + 1
        return viewModel.chapters.indices.contains(n) ? viewModel.chapters[n] : nil
    }

    private var pager: some View {
        TabView(selection: $currentPage) {
            // Страница-триггер перехода к ПРОШЛОЙ главе — свайп дальше назад
            // с первой страницы главы попадает сюда, а не упирается в край
            // (см. ReaderViewModel.pageCache/prefetchNeighbors — обычно уже
            // готова заранее, без сетевого спиннера).
            if viewModel.hasPrevious {
                prevTriggerPage.tag(0)
            }

            ForEach(Array(viewModel.pages.enumerated()), id: \.offset) { index, page in
                horizontalPage(index: index, page: page)
                    .tag(index + 1)
            }

            // Страница-перелистывание в конце главы.
            endPage.tag(viewModel.pages.count + 1)

            // Ещё одна страница-триггер: доведя свайп до неё, открываем следующую главу.
            if nextChapter != nil {
                nextTriggerPage.tag(viewModel.pages.count + 2)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    /// Одна страница горизонтального режима — картинка на весь экран, а НИЖЕ,
    /// продолжением той же страницы, обычным вертикальным скроллом (не
    /// свайпом-жестом и не отдельной панелью) — комментарии к главе. Ровно
    /// тот же принцип, что и на экране конца главы (см. endPage): просто
    /// ScrollView, где комментарии — следующий блок контента. Блок
    /// ChapterCommentsSheet появляется в дереве (и начинает грузить данные,
    /// см. её .task(id: postPage)) только когда докрутили ДО него — метка-
    /// маркер ниже картинки ловит .onAppear лишь при реальной прокрутке вниз,
    /// а не сразу при показе страницы.
    private func horizontalPage(index: Int, page: PageItem) -> some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ZoomableImageScrollView(
                        candidates: viewModel.imageURLs(for: page),
                        fitWidth: fitWidth,
                        doubleTapZoom: doubleTapZoom,
                        onTap: { xFraction in handleReaderTap(xFraction) },
                        onZoomChanged: { zoomed in isCurrentPageZoomed = zoomed }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)

                    if let ch = viewModel.currentChapter {
                        Color.clear.frame(height: 1)
                            .onAppear { revealedCommentPages.insert(index) }

                        // Показываем блок (включая состояние "отключены" с
                        // кнопкой настроек) только после реальной прокрутки
                        // вниз — не сразу при показе страницы (см. маркер
                        // выше). Сеть при этом не дёргаем, если отключено —
                        // см. ChapterCommentsSheet.task(id:).
                        if revealedCommentPages.contains(index) {
                            Divider().overlay(fg.opacity(0.15))
                            ChapterCommentsSheet(chapterId: ch.id, postPage: index + 1, siteId: viewModel.siteId, embedded: true)
                                .padding(.bottom, 40)
                        }
                    }
                }
            }
            .scrollDisabled(isCurrentPageZoomed)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea()
    }

    /// Обработка тапа по странице: левая/правая небольшая зона — листание,
    /// центр — показать/скрыть интерфейс (ответ 2а).
    private func handleReaderTap(_ xFraction: CGFloat) {
        if xFraction < 0.2 {
            goToPage(currentPage - 1)
        } else if xFraction > 0.8 {
            goToPage(currentPage + 1)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() }
        }
    }

    /// Перейти к странице по тапу: плавно (анимация) или мгновенно —
    /// по настройке «Плавное перелистывание».
    private func goToPage(_ target: Int) {
        let minTag = viewModel.hasPrevious ? 0 : 1
        let maxTag = viewModel.pages.count + 1 + (nextChapter != nil ? 1 : 0)
        let clamped = min(max(target, minTag), maxTag)
        guard clamped != currentPage else { return }
        if smoothPaging {
            // Ускорено ×1.5 (0.25 → ~0.167).
            withAnimation(.easeInOut(duration: 0.167)) { currentPage = clamped }
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { currentPage = clamped }
        }
    }

    // Невидимые страницы-триггеры перехода к следующей/прошлой главе — сама
    // разница только в том, какую главу превью-догружает .task (см.
    // ReaderViewModel.loadTransitionPreview).
    private var nextTriggerPage: some View {
        readerBackground
            .overlay { transitionSpinner }
            .task { await viewModel.loadTransitionPreview(for: viewModel.currentIndex + 1) }
    }

    private var prevTriggerPage: some View {
        readerBackground
            .overlay { transitionSpinner }
            .task { await viewModel.loadTransitionPreview(for: viewModel.currentIndex - 1) }
    }

    /// Кольцевой прогресс (тот же стиль рисования, что у спиннера скачивания
    /// главы, см. MangaDetailView.chapterDownloadControl) пока известен
    /// transitionImageProgress; иначе — обычный неопределённый спиннер
    /// (кэш-хит без картинок для превью — редкий случай, переход почти
    /// мгновенный).
    @ViewBuilder
    private var transitionSpinner: some View {
        if let frac = viewModel.transitionImageProgress {
            ZStack {
                Circle().stroke(fg.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, frac))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)
            .animation(.linear(duration: 0.15), value: frac)
        } else {
            ProgressView().tint(fg)
        }
    }

    // Экран конца главы: сверху «Конец…»/«Следующая глава» на всю высоту
    // экрана, а НИЖЕ, за её пределами — продолжением идут комментарии к
    // последней странице (долистал главу до конца → и ЕЩЁ жест вниз →
    // бесконечная лента комментов). endHeader занимает минимум высоту
    // экрана (см. GeometryReader), поэтому блок комментариев физически ниже
    // фолда и раскрывается (и грузит данные) только по факту скролла — не
    // сразу вместе с показом endPage.
    private var endPage: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    endHeader
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }

                    if let ch = viewModel.currentChapter, !viewModel.pages.isEmpty {
                        // Маркер ловит .onAppear только при реальной
                        // прокрутке вниз — сам блок комментариев (и его
                        // сетевой запрос, см. ChapterCommentsSheet.task)
                        // появляется только после этого.
                        Color.clear.frame(height: 1)
                            .onAppear { endCommentsRevealed = true }

                        if endCommentsRevealed {
                            Divider().overlay(fg.opacity(0.15))
                            ChapterCommentsSheet(
                                chapterId: ch.id,
                                postPage: viewModel.pages.count,
                                siteId: viewModel.siteId,
                                embedded: true
                            )
                            .padding(.bottom, 40)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(readerBackground)
        .ignoresSafeArea()
    }

    /// Верхняя «шапка» экрана конца — «Конец · …» и кнопка следующей главы.
    /// Сам контент компактный, но обёртка в endPage растягивает его на всю
    /// высоту экрана (центрируя) — так комментарии физически оказываются
    /// ниже фолда и раскрываются только по факту прокрутки вниз, а не сразу.
    private var endHeader: some View {
        VStack(spacing: 14) {
            Text("Конец · \(viewModel.currentChapter?.shortTitle ?? "главы")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fg.opacity(0.85))
                .padding(.top, 60)

            if !viewModel.chapterTeams.isEmpty {
                teamsCreditChip
            }

            if let next = nextChapter {
                Button {
                    openNext()
                } label: {
                    VStack(spacing: 6) {
                        Text("Следующая глава")
                            .font(.caption).foregroundStyle(fg.opacity(0.6))
                        Text(next.titleOrShort)
                            .font(.headline).foregroundStyle(fg)
                            .multilineTextAlignment(.center)
                        Label("Листните ещё раз", systemImage: "hand.draw")
                            .font(.caption2).foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            } else {
                Text("Это последняя доступная глава")
                    .font(.subheadline).foregroundStyle(fg.opacity(0.6))
            }

            chapterActionButtons
        }
        .padding(.bottom, 18)
    }

    /// "Над главой работали" — команда(ы) перевода ИМЕННО этой главы (см.
    /// ReaderViewModel.chapterTeams/ChapterPagesResult.teams, приходят
    /// прямо в ответе главы) — тап открывает профиль команды (см.
    /// TeamView), по прямой просьбе рядом с "Спасибо" на экране конца главы.
    private var teamsCreditChip: some View {
        VStack(spacing: 6) {
            Text("Над главой работали")
                .font(.caption2)
                .foregroundStyle(fg.opacity(0.5))
            HStack(spacing: 8) {
                ForEach(viewModel.chapterTeams) { team in
                    Group {
                        if let slugURL = team.slugURL {
                            Button {
                                selectedTeam = SelectedTeam(id: team.id, slugURL: slugURL, name: team.name, coverURL: team.avatarURL)
                            } label: {
                                teamChipLabel(team.name)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Нет slug_url — переход некуда, показываем как
                            // обычную неинтерактивную подпись.
                            teamChipLabel(team.name)
                        }
                    }
                }
            }
        }
    }

    private func teamChipLabel(_ name: String) -> some View {
        Text(name)
            .font(.caption.weight(.medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fg.opacity(0.12), in: Capsule())
    }

    /// "Спасибо" (лайк главы) + "Оценить перевод" — обе по прямой просьбе,
    /// на экране конца главы рядом с командой-переводчиком выше. "Спасибо"
    /// заливается акцентным, когда уже лайкнуто (см. ReaderViewModel.
    /// chapterIsLiked/toggleLike) — счётчик берём из того же места, что и
    /// исходное состояние (приходит прямо в ответе главы).
    private var chapterActionButtons: some View {
        HStack(spacing: 10) {
            Button { likeTapped() } label: {
                Label(
                    viewModel.chapterLikesCount.map { "Спасибо · \($0)" } ?? "Спасибо",
                    systemImage: (viewModel.chapterIsLiked ?? false) ? "heart.fill" : "heart"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle((viewModel.chapterIsLiked ?? false) ? Theme.background : fg)
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
            .background((viewModel.chapterIsLiked ?? false) ? Theme.accent : fg.opacity(0.12), in: Capsule())
            .buttonStyle(.plain)

            Button { showTranslationRating = true } label: {
                Text("Оценить перевод")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(fg)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
            }
            .background(fg.opacity(0.12), in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    private func likeTapped() {
        Task {
            do {
                try await viewModel.toggleLike()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
            }
        }
    }

    private func openNext() {
        guard nextChapter != nil else { return }
        pendingLandOnEnd = false
        Task { await viewModel.goTo(index: viewModel.currentIndex + 1) }
    }

    /// Свайпнули/дотапали до prevTriggerPage — переходим на ПРОШЛУЮ главу и
    /// приземляемся на её "Конец" (endPage), а не на страницу 1 — зеркально
    /// тому, как forward-переход всегда высаживает на первую страницу новой
    /// главы (см. pendingLandOnEnd/onChange(of: viewModel.pages.count)).
    private func openPrevious() {
        guard viewModel.hasPrevious else { return }
        pendingLandOnEnd = true
        Task { await viewModel.goTo(index: viewModel.currentIndex - 1) }
    }

    /// Ставит currentPage на верную страницу ТЕКУЩЕЙ (уже загруженной)
    /// главы — 1, либо, если ждали возврата назад (pendingLandOnEnd), на её
    /// endPage. Идемпотентно (см. pagesAppliedForIndex) и безопасно вызывать
    /// из нескольких мест (см. .task/.onChange(currentIndex)/.onChange(pages.
    /// count) выше) — не полагается на факт "значение pages.count
    /// ИЗМЕНИЛОСЬ" (при переходе по уже закэшированным соседям новое число
    /// страниц может случайно совпасть со старым, и тогда обычный onChange
    /// просто не сработал бы).
    private func applyLandingIfNeeded() {
        guard !viewModel.pages.isEmpty, pagesAppliedForIndex != viewModel.currentIndex else { return }
        pagesAppliedForIndex = viewModel.currentIndex
        currentPage = pendingLandOnEnd ? viewModel.pages.count + 1 : 1
        pendingLandOnEnd = false
        preloadUpcoming(from: currentPage - 1)
    }

    // MARK: Оверлей интерфейса

    private var overlayUI: some View {
        // Индикатор страницы вынесен отдельным всегда-видимым слоем (см. body),
        // поэтому здесь только верхняя и нижняя панели.
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
    }

    // Верхняя зона: кнопка выхода и плашка названия/тома/главы — раньше были
    // ОДНОЙ общей подложкой на всю ширину (кнопка + текст в одном HStack
    // внутри одного .glassEffect(Capsule())). Разделены на две НЕЗАВИСИМЫЕ
    // стеклянные подложки: кнопка сама по себе слева, а плашка с текстом —
    // отдельная капсула, которая не занимает всю ширину (`.frame(maxWidth:)`
    // вместо `.frame(maxWidth: .infinity, alignment: .leading)`), поэтому
    // сжимается/растягивается по факту содержимого и остаётся ВСЕГДА по
    // центру экрана через ZStack (а не смещена из-за соседства с кнопкой,
    // как было раньше в общем HStack).
    private var topBar: some View {
        ZStack {
            // Название плавно прячется, пока показывается тост закладки (сам тост
            // рисуется отдельным слоем в body — ВНЕ GlassEffectContainer, иначе
            // стекло «перетекало» из названия в тост и получался дёрг вбок).
            titleBadge
                .opacity(viewModel.bookmarkToast == nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: viewModel.bookmarkToast)

            HStack {
                Button { dismiss() } label: {
                    // Крупнее, чем было (40→48, headline→title3): попросили
                    // увеличить крестик.
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(fg)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                // 16pt от края — тот же отступ, что и у системной кнопки
                // "назад" на экране тайтла (MangaDetailView использует
                // штатный toolbar back-button NavigationStack, у которого
                // стандартный leading-инсет ровно 16pt). Раньше здесь была
                // общая .padding(.horizontal, 10) на весь ZStack, из-за чего
                // крестик стоял ближе к краю, чем системная стрелка.
                .padding(.leading, 16)
                Spacer(minLength: 0)
            }
        }
        // 6 → 2 (-4px): подняли панель чуть выше, как попросили.
        .padding(.top, 2)
    }

    // Плашка названия — своя отдельная подложка, ширина по контенту
    // (с потолком, чтобы очень длинные названия не упирались в кнопку),
    // текст чуть меньше прежнего (subheadline→footnote, caption→caption2).
    private var titleBadge: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(mangaTitle ?? viewModel.currentChapter?.name ?? "Глава")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(viewModel.currentChapter?.shortTitle ?? "")
                .font(.caption2)
                .foregroundStyle(fg.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 260)
        .glassEffect(.regular, in: Capsule())
    }

    // Текущий номер страницы для бабла — в горизонтальном режиме это
    // TabView-селекция (currentPage — уже 1-based для реальных страниц, тег
    // 0 зарезервирован под prevTriggerPage, см. pager), в вертикальном —
    // verticalPage, считаемый по центру экрана (см. verticalReader).
    private var pageBubbleCurrent: Int { pageMode == 1 ? verticalPage : currentPage }

    // Общее число страниц ТЕКУЩЕЙ главы для бабла — в вертикальном режиме
    // берём из segments (там же, откуда verticalPage), а не из pages
    // (которые заполняются только для горизонтального режима).
    private var pageBubbleTotal: Int {
        if pageMode == 1 {
            return viewModel.segments.first(where: { $0.index == viewModel.currentIndex })?.pages.count ?? 0
        }
        return viewModel.pages.count
    }

    // Бабл с номером страницы. Скрыт на "виртуальных" страницах конца главы/
    // перехода (currentPage == 0 или > pages.count, см. видимость выше) —
    // иначе показывал бы, например, "3/2" на экране "Конец главы", вместо
    // того чтобы просто пропасть.
    private var pageBubble: some View {
        Text("\(pageBubbleCurrent)/\(pageBubbleTotal)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    // Нижняя матовая подложка с тремя кнопками — эту НЕ трогаем, уже
    // идеальна: явная высота 64, 20px от боков и от низа истинного края
    // экрана (см. .ignoresSafeArea(.container, edges: .bottom) в body).
    // Иконки крупнее в 1.3 раза (20→26pt шрифт, 44→57pt рамка). topBar
    // (см. выше) намеренно НЕ синхронизирован с этими размерами — его
    // вернули к прежнему виду по просьбе.
    private var bottomBar: some View {
        // Каждая кнопка — отдельная круглая стеклянная подложка (а не общая
        // капсула), как попросили.
        HStack {
            readerButton(icon: "line.3.horizontal") { showChapters = true }
            Spacer()
            // Комментарии показываем только в вертикальном режиме листания.
            if pageMode == 1 {
                readerButton(icon: "text.bubble") { withAnimation(.easeInOut(duration: 0.25)) { showComments = true } }
                Spacer()
            }
            bookmarkButton
            Spacer()
            readerButton(icon: "gearshape") { showSettings = true }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func readerButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(fg)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        }
    }

    /// Кнопка-закладка: тап заливает её белым (bookmark.fill) и добавляет тайтл;
    /// повторный тап (когда уже белая) — убирает из закладок и обесцвечивает.
    /// При переходе на след. главу заливка сбрасывается (см. onChange currentIndex).
    private var bookmarkButton: some View {
        Button {
            let nowFilled = !bookmarkFilled
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkFilled = nowFilled }
            viewModel.setBookmark(nowFilled)
        } label: {
            Image(systemName: bookmarkFilled ? "bookmark.fill" : "bookmark")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(fg)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
        }
    }
}

// MARK: - Список глав

/// Панель списка глав (снизу вверх): дата справа, сортировка, выход, заголовок.
struct ChapterListSheet: View {
    let chapters: [ChapterItem]
    let currentIndex: Int
    /// branch_id, реально применяемый сейчас читалкой (ReaderViewModel.
    /// preferredBranchId) — только чтобы при открытии меню сразу отметить
    /// галочкой уже выбранного переводчика, а не сбрасывать на "Все".
    let currentBranchId: Int?
    let onSelect: (Int) -> Void
    /// Вызывается при смене переводчика с УЖЕ найденным branch_id (nil —
    /// "Все переводчики"/сброс на дефолтный) — родитель применяет его к
    /// ReaderViewModel, реально переключая, что загружается (см.
    /// MangaReaderView.setPreferredBranch).
    let onSelectTranslator: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var descending = true   // true = новые сверху
    /// Фильтр по команде перевода (id ChapterTeam); nil — показываем все главы.
    /// Доступен только когда у тайтла ≥2 переводчиков (см. allTeams/header).
    @State private var selectedTeamId: Int?

    // Тема читалки — меню глав тоже светлеет при светлой теме.
    @AppStorage("reader_theme") private var readerTheme = 0
    @Environment(\.colorScheme) private var systemColorScheme
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    init(chapters: [ChapterItem], currentIndex: Int, currentBranchId: Int?,
         onSelect: @escaping (Int) -> Void, onSelectTranslator: @escaping (Int?) -> Void) {
        self.chapters = chapters
        self.currentIndex = currentIndex
        self.currentBranchId = currentBranchId
        self.onSelect = onSelect
        self.onSelectTranslator = onSelectTranslator
        // Предвыбираем в меню ту команду, что уже реально применена в
        // читалке, чтобы галочка совпадала с тем, что сейчас читается.
        var initialTeamId: Int?
        if let currentBranchId {
            outer: for chapter in chapters {
                for branch in chapter.branches ?? [] where branch.branchId == currentBranchId {
                    initialTeamId = branch.teams?.first?.id
                    break outer
                }
            }
        }
        _selectedTeamId = State(initialValue: initialTeamId)
    }

    private struct IndexedChapter: Identifiable {
        let index: Int
        let chapter: ChapterItem
        var id: Int { chapter.id }
    }

    /// Уникальные команды перевода по всем главам — если их ≥2, в шапке вместо
    /// прямого тоггла порядка появляется меню (выбор переводчика + сортировка).
    private var allTeams: [ChapterTeam] {
        var seen = Set<Int>()
        var result: [ChapterTeam] = []
        for chapter in chapters {
            for branch in chapter.branches ?? [] {
                for team in branch.teams ?? [] where !seen.contains(team.id) {
                    seen.insert(team.id)
                    result.append(team)
                }
            }
        }
        return result
    }

    /// branch_id команды перевода: branch_id стабилен для команды по всему
    /// тайтлу (см. ReaderViewModel.preferredBranchId), поэтому достаточно
    /// найти его у ЛЮБОЙ главы, где встречается эта команда.
    private func branchId(forTeam teamId: Int) -> Int? {
        for chapter in chapters {
            for branch in chapter.branches ?? [] where (branch.teams ?? []).contains(where: { $0.id == teamId }) {
                return branch.branchId
            }
        }
        return nil
    }

    private var ordered: [IndexedChapter] {
        var indexed = chapters.enumerated().map { IndexedChapter(index: $0.offset, chapter: $0.element) }
        if let selectedTeamId {
            indexed = indexed.filter { item in
                (item.chapter.branches ?? []).contains { branch in
                    (branch.teams ?? []).contains { $0.id == selectedTeamId }
                }
            }
        }
        return descending ? Array(indexed.reversed()) : indexed
    }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { position, item in
                            row(item.index, item.chapter)
                            if position < ordered.count - 1 {
                                Divider().overlay(palette.separator)
                            }
                        }
                    }
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                    .animation(.easeInOut(duration: 0.2), value: descending)
                    .animation(.easeInOut(duration: 0.2), value: selectedTeamId)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(palette.isLight ? .light : .dark)
        // Смена переводчика в меню — это не просто фильтр списка: реально
        // переключает branch_id, с которым читалка грузит главы (см.
        // MangaReaderView.onSelectTranslator → ReaderViewModel.setPreferredBranch).
        .onChange(of: selectedTeamId) { _, newValue in
            onSelectTranslator(newValue.flatMap { branchId(forTeam: $0) })
        }
    }

    // Шапка как в настройках читалки: заголовок по центру, стеклянные кнопки.
    // Слева — сортировка, справа — крестик выхода (поменяны местами по просьбе).
    private var header: some View {
        ZStack {
            Text("Главы").font(.headline).foregroundStyle(palette.foreground)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                sortControl
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(palette.foreground)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Кнопка сортировки в шапке. Если у тайтла ≥2 переводчиков — превращается
    /// в меню с двумя группами (Picker + .inline, ровно как меню "Сортировка"
    /// в каталоге — см. MangaCatalogView.controlsBar): выбор переводчика
    /// (реально переключает branch_id, а не только фильтрует список — см.
    /// onChange(of: selectedTeamId) выше) и порядок (по убыванию/возрастанию).
    /// При 1 переводчике (или без данных о командах) — как раньше, прямой
    /// тоггл по тапу.
    @ViewBuilder
    private var sortControl: some View {
        if allTeams.count >= 2 {
            Menu {
                Picker("Переводчик", selection: $selectedTeamId) {
                    Text("Все переводчики").tag(Int?.none)
                    ForEach(allTeams) { team in
                        Text(team.name).tag(Int?(team.id))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Сортировка", selection: $descending) {
                    Label("По возрастанию", systemImage: "arrow.up").tag(false)
                    Label("По убыванию", systemImage: "arrow.down").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        } else {
            Button {
                withAnimation { descending.toggle() }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

    // Формат заголовка строки по референсу: "Том{X} Гл.{Y}" (без пробела
    // перед номером тома, сокращённое "Гл." с точкой) — это отдельный,
    // локальный для этого списка формат, НЕ трогает общий
    // ChapterItem.shortTitle ("Том X Глава Y"), которым по-прежнему
    // пользуется topBar ридера.
    private func rowTitle(_ chapter: ChapterItem) -> String {
        "Том \(chapter.volume) • Глава \(chapter.number)"
    }

    private func row(_ index: Int, _ chapter: ChapterItem) -> some View {
        let isCurrent = index == currentIndex
        return Button { onSelect(index) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(chapter))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                    if let name = chapter.name, !name.isEmpty {
                        Text(name).font(.subheadline).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }
                Spacer()
                // Галочка (акцентный оранжевый) вместо даты — только у
                // текущей прочитанной главы, как на референсе.
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Настройки читалки. Порядок: тип листания → тема → сервер → вписывание →
/// предзагрузка → переключение страниц (под-лист) → зум двойным → скрыть номер.
struct ReaderSettingsSheet: View {
    @Binding var fitWidth: Bool
    @Binding var preloadCount: Int
    @Binding var pageMode: Int
    @Binding var readerTheme: Int
    @Binding var doubleTapZoom: Bool
    @Binding var hidePageNumber: Bool
    @Binding var disableSwipe: Bool
    @Binding var smoothPaging: Bool
    @Binding var verticalGap: Double

    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showPaging = false
    /// Прогретый генератор вибрации для шага ползунка отступа.
    private let gapHaptic = UIImpactFeedbackGenerator(style: .light)

    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    /// Высота под-листа «Переключение страниц» — РОВНО по содержимому
    /// (заголовок + 2 тумблера с подписями), не системный .medium (был на
    /// полэкрана с пустым хвостом снизу) — тот же приём, что и в
    /// RatingSheet.ratingSheetHeight: фиксированное число, а не
    /// GeometryReader+PreferenceKey (пересчёт детента постфактум — известная
    /// хрупкая штука в SwiftUI, см. комментарий там). Реальная сумма
    /// высот/паддингов ≈290-300, тут с запасом под крупный Dynamic Type.
    private static let pagingSheetHeight: CGFloat = 340

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        Text("Настройки").font(.headline).foregroundStyle(palette.foreground)
                            .frame(maxWidth: .infinity, alignment: .center)
                        HStack {
                            Spacer()
                            // Крестик — стеклянный, как попросили.
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.headline)
                                    .foregroundStyle(palette.foreground)
                                    .frame(width: 40, height: 40)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                        }
                    }

                    // 1. Тип листания (пока просто селектор — ответ 3а).
                    label("Тип листания")
                    Picker("", selection: $pageMode) {
                        Text("Влево").tag(0); Text("Вверх").tag(1); Text("Вправо").tag(2)
                    }.pickerStyle(.segmented)

                    // 2. Тема читалки.
                    label("Тема читалки")
                    Picker("", selection: $readerTheme) {
                        Text("Светлая").tag(1); Text("Тёмная").tag(0); Text("Системная").tag(2)
                    }.pickerStyle(.segmented)

                    // 3. Сервер картинок.
                    label("Сервер картинок")
                    Picker("", selection: $serverChoice) {
                        ForEach(ImageServerChoice.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)

                    // 4. Вместить изображение — не нужно в вертикальном режиме
                    //    (там картинки всегда по ширине).
                    if pageMode != 1 {
                        label("Вместить изображение")
                        Picker("", selection: $fitWidth) {
                            Text("По высоте").tag(false); Text("По ширине").tag(true)
                        }.pickerStyle(.segmented)
                    }

                    // Предзагрузка (оставил).
                    label("Предзагрузка страниц")
                    Picker("", selection: $preloadCount) {
                        Text("1").tag(1); Text("3").tag(3); Text("5").tag(5)
                    }.pickerStyle(.segmented)

                    // 5. В вертикальном режиме здесь ползунок «Отступ между
                    //    картинками», иначе — строка «Переключение страниц».
                    if pageMode == 1 {
                        gapSlider
                    } else {
                        Button { showPaging = true } label: {
                            HStack {
                                Text("Переключение страниц").foregroundStyle(palette.foreground)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(palette.secondary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // 6. Зум двойным нажатием (тумблер, своя подложка).
                    toggleRow("Увеличить двойным нажатием", isOn: $doubleTapZoom)

                    // 7. Скрыть номер страниц (тумблер, своя подложка).
                    toggleRow("Скрыть номер страниц", isOn: $hidePageNumber)

                    Spacer(minLength: 0)
                }
                // Горизонтальный отступ — 16, тот же, что и в
                // PersonalizationSettingsView (было 20).
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .tint(Theme.accent)
        .sheet(isPresented: $showPaging) {
            pagingSheet
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 22.5, weight: .semibold)).foregroundStyle(palette.secondary)
    }
    // footnote + отступ 4 — тот же стиль, что и у подписей под подложками в
    // PersonalizationSettingsView (см. "Выключи для белой темы..." и т.д.).
    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(palette.secondary).padding(.horizontal, 4)
    }
    // Без явного .font() — то же самое, что и у Toggle-строк в
    // PersonalizationSettingsView (там текст тоже без своего размера,
    // обычный системный), и те же паддинг/высота/закругление (16/52/24),
    // что и у card()-подложек там же — по прямой просьбе выровнять.
    private func toggleRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).foregroundStyle(palette.foreground)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Ползунок «Отступ между картинками» (только вертикальный режим) —
    /// оформление как у слайдера сворачивания комментариев: живая подпись
    /// сверху + короткая вибрация на каждый шаг. Паддинг/закругление — как у
    /// многострочных подложек в PersonalizationSettingsView (cardsPerRowSection
    /// и т.д.): .padding(16) со всех сторон, cornerRadius 24.
    private var gapSlider: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Отступ между картинками")
                    .foregroundStyle(palette.foreground)
                Spacer()
                Text("\(Int(verticalGap)) px")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            Slider(value: $verticalGap, in: 0...50, step: 1)
                .tint(Theme.accent)
                .onChange(of: verticalGap) { _, _ in gapHaptic.impactOccurred() }
                .onAppear { gapHaptic.prepare() }

            HStack {
                Text("0").font(.caption2).foregroundStyle(palette.secondary)
                Spacer()
                Text("50 px").font(.caption2).foregroundStyle(palette.secondary)
            }
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Под-лист «Переключение страниц».
    private var pagingSheet: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Переключение страниц").font(.headline).foregroundStyle(palette.foreground)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                toggleRow("Выключить перелистывание", isOn: $disableSwipe)
                caption("Листать можно будет тапами по краям экрана.")

                toggleRow("Плавное перелистывание", isOn: $smoothPaging)
                caption("Анимировать переключение страниц при нажатии.")

                Spacer(minLength: 0)
            }
            // Горизонтальный отступ — 16, тот же, что и в основном шите
            // настроек читалки/PersonalizationSettingsView (было 20).
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 20)
        }
        .presentationDetents([.height(Self.pagingSheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .tint(Theme.accent)
    }
}

// MARK: - Нативный зум страницы (UIScrollView)

/// UIScrollView-обёртка вокруг картинки — «масляно» плавный pinch/pan/двойной
/// тап с инерцией и корректным центрированием (как в родных вьюверах). SwiftUI-
/// жесты давали резину; здесь весь зум делает UIKit.
///
/// - `fitWidth == false`: страница вписана целиком по высоте (обычная манга).
/// - `fitWidth == true`: страница по ширине, длинные страницы скроллятся вниз
///   даже без зума (вебтун/манхва).
/// Одиночный тап — `onSingleTap` (показать/скрыть интерфейс). Двойной тап —
/// зум к точке / сброс. Горизонтальный свайп на масштабе 1 не перехватывается
/// (контент вписан → не скроллится вбок), поэтому листание страниц TabView
/// продолжает работать.
struct ZoomableImageScrollView: UIViewRepresentable {
    let candidates: [URL]
    let fitWidth: Bool
    let doubleTapZoom: Bool
    /// Одиночный тап: передаёт долю по X (0…1) — читалка сама решает
    /// листать/показать интерфейс (см. handleReaderTap).
    let onTap: (CGFloat) -> Void
    /// Есть ли сейчас зум (масштаб > 1) — читалка использует это, чтобы
    /// отключить внешний вертикальный ScrollView (продолжение страницы вниз,
    /// см. MangaReaderView.horizontalPage), пока идёт панорама зума, и они не
    /// конкурировали за один и тот же вертикальный драг.
    var onZoomChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, fitWidth: fitWidth, doubleTapZoom: doubleTapZoom, onZoomChanged: onZoomChanged) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutCallbackScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bouncesZoom = true
        scroll.decelerationRate = .fast

        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .clear
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        let ring = RingProgressView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        scroll.addSubview(ring)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        context.coordinator.ringView = ring

        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        scroll.addGestureRecognizer(double)

        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.boundsChanged() }

        context.coordinator.load(candidates: candidates)
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.doubleTapZoom = doubleTapZoom
        if context.coordinator.fitWidth != fitWidth {
            context.coordinator.fitWidth = fitWidth
            context.coordinator.layoutImage(resetZoom: true)
        }
        if context.coordinator.currentKey != candidates.first {
            context.coordinator.load(candidates: candidates)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var ringView: RingProgressView?
        var onTap: (CGFloat) -> Void
        var onZoomChanged: ((Bool) -> Void)?
        var fitWidth: Bool
        var doubleTapZoom: Bool
        var currentKey: URL?
        private var loadTask: Task<Void, Never>?
        private var lastBounds: CGSize = .zero
        private var lastReportedZoomed = false

        init(onTap: @escaping (CGFloat) -> Void, fitWidth: Bool, doubleTapZoom: Bool, onZoomChanged: ((Bool) -> Void)? = nil) {
            self.onTap = onTap
            self.fitWidth = fitWidth
            self.doubleTapZoom = doubleTapZoom
            self.onZoomChanged = onZoomChanged
        }

        func load(candidates: [URL]) {
            currentKey = candidates.first
            loadTask?.cancel()
            imageView?.image = nil
            ringView?.progress = 0
            ringView?.isHidden = false
            let key = currentKey
            loadTask = Task { [weak self] in
                // Видимая страница — высокий сетевой приоритет, чтобы не
                // ждать наравне с молча качающимися вперёд preload()-страницами.
                // onProgress — реальный прогресс скачивания (0...1) для
                // кольца вместо неопределённого спиннера, по прямой просьбе.
                let img = await RemoteImageLoader.fetchImage(candidates: candidates, priority: URLSessionTask.highPriority) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.currentKey == key else { return }
                        self.ringView?.progress = CGFloat(p)
                    }
                }
                await MainActor.run {
                    guard let self, self.currentKey == key else { return }
                    self.ringView?.isHidden = true
                    self.imageView?.image = img
                    self.layoutImage(resetZoom: true)
                }
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if zoomed != lastReportedZoomed {
                lastReportedZoomed = zoomed
                onZoomChanged?(zoomed)
            }
        }

        @objc func handleSingleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = scrollView, scroll.bounds.width > 0 else { onTap(0.5); return }
            let x = g.location(in: scroll).x / scroll.bounds.width
            onTap(min(max(x, 0), 1))
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard doubleTapZoom else { return } // зум двойным нажатием отключён
            guard let scroll = scrollView, let imageView, imageView.image != nil else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = g.location(in: imageView)
                let newScale: CGFloat = min(2.5, scroll.maximumZoomScale)
                let w = scroll.bounds.width / newScale
                let h = scroll.bounds.height / newScale
                scroll.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
            }
        }

        func boundsChanged() {
            guard let scroll = scrollView, scroll.bounds.size != lastBounds else { return }
            lastBounds = scroll.bounds.size
            // Переразмечаем только когда не в зуме (иначе сбили бы текущий зум).
            layoutImage(resetZoom: scroll.zoomScale <= scroll.minimumZoomScale + 0.01)
        }

        /// Вписывает картинку (по высоте или по ширине) и центрирует.
        func layoutImage(resetZoom: Bool) {
            guard let scroll = scrollView, let imageView, let image = imageView.image else {
                // Нет картинки — центрируем кольцо прогресса.
                centerRing()
                return
            }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }

            if resetZoom { scroll.zoomScale = 1 }

            let size: CGSize
            if fitWidth {
                let scale = bounds.width / image.size.width
                size = CGSize(width: bounds.width, height: image.size.height * scale)
            } else {
                let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            imageView.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            centerImage()
            centerRing()
        }

        private func centerImage() {
            guard let scroll = scrollView, let imageView else { return }
            let bounds = scroll.bounds.size
            let content = imageView.frame.size
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
            scroll.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        private func centerRing() {
            guard let scroll = scrollView, let ringView else { return }
            ringView.center = CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
        }
    }
}

/// UIScrollView, сообщающий во внешний код о смене bounds (для перевёрстки
/// картинки при первом появлении/повороте) — у UIScrollView нет делегата на это.
final class LayoutCallbackScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Кольцевой индикатор РЕАЛЬНОГО прогресса скачивания страницы (0...1) —
/// вместо неопределённого UIActivityIndicatorView, по прямой просьбе. Тот же
/// стиль отрисовки, что и у SwiftUI-кольца в VerticalPageImage.pageProgressRing/
/// MangaDetailView.chapterDownloadControl (трек + дуга прогресса), просто
/// нативным UIKit-слоем — читалка страниц целиком нативная (см.
/// ZoomableImageScrollView).
final class RingProgressView: UIView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    /// Минимум 0.02 — тонкий видимый штрих сразу, даже пока прогресс ещё
    /// не начал реально расти (тот же приём, что и в SwiftUI-версии).
    var progress: CGFloat = 0 {
        didSet { progressLayer.strokeEnd = max(0.02, min(1, progress)) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        trackLayer.lineWidth = 3
        layer.addSublayer(trackLayer)

        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = UIColor.white.cgColor
        progressLayer.lineWidth = 3
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0.02
        layer.addSublayer(progressLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2 - trackLayer.lineWidth / 2
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: max(0, radius),
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
    }
}

/// Одна страница в вертикальной (непрерывной) ленте: грузится через общий
/// кэш (RemoteImageLoader), вписывается по ширине, высота — по соотношению
/// сторон, чтобы LazyVStack корректно раскладывал ленту. Пока грузится —
/// плейсхолдер фиксированной высоты со спиннером.
struct VerticalPageImage: View {
    let candidates: [URL]
    /// Реальные пиксельные размеры страницы с сервера (см. PageItem.width/
    /// height, приходят в ответе главы ДО загрузки самой картинки) —
    /// используются, чтобы placeholder СРАЗУ был нужных пропорций: высота
    /// вебтун-страницы бывает в 10+ раз больше ширины, и с фиксированным
    /// placeholder (было 480pt всегда) контент заметно "прыгал" при
    /// подгрузке реальной картинки, особенно при быстрой прокрутке через
    /// несколько ещё не загруженных страниц разом. nil/некорректные —
    /// прежний фиксированный placeholder (сервер их не прислал).
    let width: Int?
    let height: Int?
    @State private var image: UIImage?
    /// Реальный прогресс скачивания (0...1) — по прямой просьбе, кольцо
    /// вместо неопределённого спиннера (см. RemoteImageLoader.fetchImage
    /// onProgress). Сбрасывается на 0 в начале каждой новой загрузки.
    @State private var progress: Double = 0

    /// Высота placeholder'а под реальную ширину экрана — та же логика
    /// "по факту загрузки" (scaledToFit + maxWidth: .infinity) даёт финальную
    /// картинку, просто заранее просчитанная. Не учитывает vScale (зум) —
    /// он временное состояние жеста, не стоит того, чтобы тащить сюда лишний
    /// параметр ради долей секунды, что кто-то одновременно и зумит, и
    /// именно эта картинка ещё грузится.
    private var placeholderHeight: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 480 }
        return UIScreen.main.bounds.width * CGFloat(height) / CGFloat(width)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: placeholderHeight)
                    .frame(maxWidth: .infinity)
                    .overlay { pageProgressRing }
            }
        }
        .task(id: candidates.first) {
            progress = 0
            // Видимая страница — высокий сетевой приоритет (см. комментарий
            // у fetchImage в RemoteImage.swift).
            image = await RemoteImageLoader.fetchImage(candidates: candidates, priority: URLSessionTask.highPriority) { p in
                Task { @MainActor in progress = p }
            }
        }
    }

    /// Кольцо реального прогресса скачивания — тот же стиль отрисовки, что и
    /// у MangaDetailView.chapterDownloadControl (трек + дуга), просто белым
    /// (страница ещё не загрузилась, фон тёмный вне зависимости от темы).
    private var pageProgressRing: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
        .animation(.linear(duration: 0.15), value: progress)
    }
}

/// Маленький тост "Добавлено в закладки" (иконка закладки слева + текст) —
/// см. ReaderViewModel.justAddedToReading. Появляется/исчезает через
/// .transition в месте использования (MangaReaderView.body), сам по себе
/// просто статичная плашка.
struct BookmarkAddedToast: View {
    var text: String = "Добавлено в закладки"
    var systemImage: String = "bookmark.fill"

    var body: some View {
        // Стеклянная капсула — 1-в-1 стиль/положение тоста «Загрузка начата»
        // (см. RootView.DownloadToast).
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
