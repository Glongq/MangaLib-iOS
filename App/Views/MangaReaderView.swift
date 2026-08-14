import SwiftUI
import UIKit

/// Палитра читалки под выбранную тему (0 тёмная / 1 светлая / 2 системная).
/// Тексты и иконки читалки и её меню (главы/настройки) берут цвета отсюда,
/// чтобы не сливаться с фоном при светлой теме.
struct ReaderPalette {
    let isLight: Bool
    /// Фон под страницами: тёмный — чёрный, светлый — чуть серый (не чисто белый).
    var pageBackground: Color { isLight ? Color(white: 0.93) : .black }
    /// Фон меню (главы/настройки): светлый — белый.
    var background: Color { isLight ? .white : Theme.background }
    var foreground: Color { isLight ? Color(white: 0.12) : .white }
    var secondary: Color { isLight ? Color(white: 0.45) : Theme.textSecondary }
    var surface: Color { isLight ? Color(white: 0.94) : Theme.surfaceElevated }
    var separator: Color { isLight ? Color.black.opacity(0.10) : Theme.separator }

    static func make(theme: Int, system: ColorScheme) -> ReaderPalette {
        switch theme {
        case 1: return ReaderPalette(isLight: true)
        case 2: return ReaderPalette(isLight: system == .light)
        default: return ReaderPalette(isLight: false)
        }
    }
}

/// Полноэкранная читалка: горизонтальное листание страниц, тап переключает интерфейс.
struct MangaReaderView: View {

    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0
    @State private var showUI = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showComments = false
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

    /// Простой зум всей вертикальной ленты (приближается весь вид, а не
    /// отдельная картинка). `scale` — текущий масштаб, `offset` — сдвиг при
    /// увеличении; `last*` фиксируются на конце жеста.
    @State private var vScale: CGFloat = 1
    @State private var vLastScale: CGFloat = 1
    @State private var vOffset: CGSize = .zero
    @State private var vLastOffset: CGSize = .zero

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
         preferredBranchId: Int? = nil) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(
            slug: slug, chapters: chapters, startIndex: startIndex,
            mangaId: mangaId, mangaTitle: mangaTitle, coverURL: coverURL,
            preferredBranchId: preferredBranchId
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

            if showUI {
                overlayUI.transition(.opacity)
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
            } else {
                if viewModel.pages.isEmpty { await viewModel.load() }
                preloadUpcoming(from: currentPage)
            }
        }
        // Живое переключение режима листания.
        .onChange(of: pageMode) { _, mode in
            Task {
                if mode == 1 {
                    await viewModel.startVertical()
                } else {
                    currentPage = 0
                    await viewModel.load()
                }
            }
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            currentPage = 0
            // На новой главе заливка закладки возвращается «как была».
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkFilled = false }
        }
        .onChange(of: currentPage) { _, page in
            preloadUpcoming(from: page)
            // Долистали до страницы-триггера — открываем следующую главу
            // (работает и в режиме «выключить перелистывание», где листаем тапом).
            if page == viewModel.pages.count + 1 { openNext() }
        }
        // Срабатывает и на первую загрузку страниц, и при переходе на
        // следующую главу (goTo → load() заново наполняет pages).
        .onChange(of: viewModel.pages.count) { _, count in
            if count > 0 { preloadUpcoming(from: currentPage) }
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(
                chapters: viewModel.chapters,
                currentIndex: viewModel.currentIndex,
                onSelect: { index in
                    showChapters = false
                    Task {
                        if pageMode == 1 { await viewModel.goToVertical(index: index) }
                        else { await viewModel.goTo(index: index) }
                    }
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
        .sheet(isPresented: $showComments) {
            // Комментарии текущей страницы главы (post_type=chapter, post_page).
            if let ch = viewModel.currentChapter {
                let pageNo = pageMode == 1
                    ? verticalPage
                    : min(currentPage, max(viewModel.pages.count - 1, 0)) + 1
                ChapterCommentsSheet(chapterId: ch.id, postPage: pageNo)
            }
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
            ScrollView {
                LazyVStack(spacing: CGFloat(verticalGap)) {
                    ForEach(viewModel.segments) { seg in
                        ForEach(Array(seg.pages.enumerated()), id: \.offset) { pageIndex, page in
                            VerticalPageImage(candidates: viewModel.imageURLs(for: page))
                                .onAppear {
                                    viewModel.markCurrentChapter(seg.index)
                                    verticalPage = pageIndex + 1
                                }
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
            }
            .scrollIndicators(.hidden)
            // Приближаем весь вид целиком. Пока масштаб 1× — жесты не
            // перехватываются, лента листается как обычно; при зуме включается
            // перетаскивание (панорама), а листание возобновляется после
            // возврата к 1× (пинч обратно).
            .scaleEffect(vScale)
            .offset(vOffset)
            .simultaneousGesture(zoomGesture(in: geo.size))
            .highPriorityGesture(panGesture(in: geo.size), including: vScale > 1 ? .all : .none)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
        }
        .ignoresSafeArea()
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                vScale = min(max(vLastScale * v.magnification, 1), 5)
                vOffset = clampVertical(vOffset, scale: vScale, size: size)
            }
            .onEnded { _ in
                if vScale <= 1.01 {
                    withAnimation(.easeOut(duration: 0.2)) { vScale = 1; vOffset = .zero }
                    vLastScale = 1; vLastOffset = .zero
                } else {
                    vLastScale = vScale
                    vOffset = clampVertical(vOffset, scale: vScale, size: size)
                    vLastOffset = vOffset
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let proposed = CGSize(
                    width: vLastOffset.width + v.translation.width,
                    height: vLastOffset.height + v.translation.height
                )
                vOffset = clampVertical(proposed, scale: vScale, size: size)
            }
            .onEnded { _ in vLastOffset = vOffset }
    }

    /// Не даём увезти вид за края при панораме увеличенной ленты.
    private func clampVertical(_ o: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        let maxX = max(size.width * (scale - 1) / 2, 0)
        let maxY = max(size.height * (scale - 1) / 2, 0)
        return CGSize(
            width: min(max(o.width, -maxX), maxX),
            height: min(max(o.height, -maxY), maxY)
        )
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
    @ViewBuilder
    private var singlePageView: some View {
        if currentPage < viewModel.pages.count {
            ZoomableImageScrollView(
                candidates: viewModel.imageURLs(for: viewModel.pages[currentPage]),
                fitWidth: fitWidth,
                doubleTapZoom: doubleTapZoom,
                onTap: { xFraction in handleReaderTap(xFraction) }
            )
            .ignoresSafeArea()
            .id(currentPage)
        } else if currentPage == viewModel.pages.count {
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
            ForEach(Array(viewModel.pages.enumerated()), id: \.offset) { index, page in
                ZoomableImageScrollView(
                    candidates: viewModel.imageURLs(for: page),
                    fitWidth: fitWidth,
                    doubleTapZoom: doubleTapZoom,
                    onTap: { xFraction in handleReaderTap(xFraction) }
                )
                .ignoresSafeArea()
                .tag(index)
            }

            // Страница-перелистывание в конце главы.
            endPage.tag(viewModel.pages.count)

            // Ещё одна страница-триггер: доведя свайп до неё, открываем следующую главу.
            if nextChapter != nil {
                nextTriggerPage.tag(viewModel.pages.count + 1)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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
        let maxTag = viewModel.pages.count + (nextChapter != nil ? 1 : 0)
        let clamped = min(max(target, 0), maxTag)
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

    // Невидимая страница-триггер (перехода к следующей главе).
    private var nextTriggerPage: some View {
        readerBackground
            .overlay { ProgressView().tint(fg) }
    }

    // Экран конца главы: сверху «Конец…», снизу «Следующая глава …».
    private var endPage: some View {
        VStack {
            Text("Конец · \(viewModel.currentChapter?.shortTitle ?? "главы")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fg.opacity(0.85))
                // 60 → 95 (+35): опустили надпись ниже, как попросили.
                .padding(.top, 95)

            Spacer()

            if let next = nextChapter {
                Button {
                    openNext()
                } label: {
                    VStack(spacing: 8) {
                        Text("Следующая глава")
                            .font(.caption).foregroundStyle(fg.opacity(0.6))
                        Text(next.titleOrShort)
                            .font(.headline).foregroundStyle(fg)
                            .multilineTextAlignment(.center)
                        Label("Листните ещё раз", systemImage: "hand.draw")
                            .font(.caption2).foregroundStyle(Theme.accent)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                .buttonStyle(.plain)
            } else {
                Text("Это последняя доступная глава")
                    .font(.subheadline).foregroundStyle(fg.opacity(0.6))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(readerBackground)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
    }

    private func openNext() {
        guard nextChapter != nil else { return }
        Task { await viewModel.goTo(index: viewModel.currentIndex + 1) }
    }

    // MARK: Оверлей интерфейса

    private var overlayUI: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 0) {
                topBar
                Spacer()
                // currentPage < pages.count — реальная страница; на "Конец
                // главы"/переходной странице (currentPage == pages.count или
                // pages.count+1) индикатор просто пропадает, а не показывает
                // некорректное значение вроде "3/2".
                if !hidePageNumber && !viewModel.pages.isEmpty && currentPage < viewModel.pages.count { pageBubble }
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

    // Бабл с номером страницы. Скрыт на "виртуальных" страницах конца главы/
    // перехода (currentPage >= pages.count) — иначе показывал бы, например,
    // "3/2" на экране "Конец главы", вместо того чтобы просто пропасть.
    private var pageBubble: some View {
        Text("\(currentPage + 1)/\(viewModel.pages.count)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 12)
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
                readerButton(icon: "text.bubble") { showComments = true }
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
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var descending = true   // true = новые сверху

    // Тема читалки — меню глав тоже светлеет при светлой теме.
    @AppStorage("reader_theme") private var readerTheme = 0
    @Environment(\.colorScheme) private var systemColorScheme
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    private struct IndexedChapter: Identifiable {
        let index: Int
        let chapter: ChapterItem
        var id: Int { chapter.id }
    }

    private var ordered: [IndexedChapter] {
        let indexed = chapters.enumerated().map { IndexedChapter(index: $0.offset, chapter: $0.element) }
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
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(palette.isLight ? .light : .dark)
    }

    // Шапка как в настройках читалки: заголовок по центру, стеклянные кнопки.
    // Слева — сортировка, справа — крестик выхода (поменяны местами по просьбе).
    private var header: some View {
        ZStack {
            Text("Главы").font(.headline).foregroundStyle(palette.foreground)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Button {
                    withAnimation { descending.toggle() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
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
                                Text("Переключение страниц").font(.system(size: 17)).foregroundStyle(palette.foreground)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(palette.secondary)
                            }
                            .padding(14)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .padding(.horizontal, 20)
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
    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(palette.secondary)
    }
    private func toggleRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).font(.system(size: 17)).foregroundStyle(palette.foreground)
        }
        .tint(Theme.accent)
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Ползунок «Отступ между картинками» (только вертикальный режим) —
    /// оформление как у слайдера сворачивания комментариев: живая подпись
    /// сверху + короткая вибрация на каждый шаг.
    private var gapSlider: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Отступ между картинками")
                    .font(.system(size: 17)).foregroundStyle(palette.foreground)
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
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
        }
        .presentationDetents([.medium])
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

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, fitWidth: fitWidth, doubleTapZoom: doubleTapZoom) }

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

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        scroll.addSubview(spinner)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        context.coordinator.spinner = spinner

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
        weak var spinner: UIActivityIndicatorView?
        var onTap: (CGFloat) -> Void
        var fitWidth: Bool
        var doubleTapZoom: Bool
        var currentKey: URL?
        private var loadTask: Task<Void, Never>?
        private var lastBounds: CGSize = .zero

        init(onTap: @escaping (CGFloat) -> Void, fitWidth: Bool, doubleTapZoom: Bool) {
            self.onTap = onTap
            self.fitWidth = fitWidth
            self.doubleTapZoom = doubleTapZoom
        }

        func load(candidates: [URL]) {
            currentKey = candidates.first
            loadTask?.cancel()
            imageView?.image = nil
            spinner?.startAnimating()
            let key = currentKey
            loadTask = Task { [weak self] in
                let img = await RemoteImageLoader.fetchImage(candidates: candidates)
                await MainActor.run {
                    guard let self, self.currentKey == key else { return }
                    self.spinner?.stopAnimating()
                    self.imageView?.image = img
                    self.layoutImage(resetZoom: true)
                }
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

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
                // Нет картинки — центрируем спиннер.
                centerSpinner()
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
            centerSpinner()
        }

        private func centerImage() {
            guard let scroll = scrollView, let imageView else { return }
            let bounds = scroll.bounds.size
            let content = imageView.frame.size
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
            scroll.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        private func centerSpinner() {
            guard let scroll = scrollView, let spinner else { return }
            spinner.center = CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
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

/// Одна страница в вертикальной (непрерывной) ленте: грузится через общий
/// кэш (RemoteImageLoader), вписывается по ширине, высота — по соотношению
/// сторон, чтобы LazyVStack корректно раскладывал ленту. Пока грузится —
/// плейсхолдер фиксированной высоты со спиннером.
struct VerticalPageImage: View {
    let candidates: [URL]
    @State private var image: UIImage?

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
                    .frame(height: 480)
                    .overlay { ProgressView().tint(.white) }
            }
        }
        .task(id: candidates.first) {
            image = await RemoteImageLoader.fetchImage(candidates: candidates)
        }
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
