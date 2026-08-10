import SwiftUI

/// Полноэкранная читалка: горизонтальное листание страниц, тап переключает интерфейс.
struct MangaReaderView: View {

    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0
    @State private var showUI = true
    @State private var showChapters = false
    @State private var showSettings = false

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

    init(slug: String,
         chapters: [ChapterItem],
         startIndex: Int,
         mangaId: Int? = nil,
         mangaTitle: String? = nil,
         mangaTypeName: String? = nil,
         coverURL: String? = nil) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(
            slug: slug, chapters: chapters, startIndex: startIndex,
            mangaId: mangaId, mangaTitle: mangaTitle, coverURL: coverURL
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
            Color.black.ignoresSafeArea()

            content

            if showUI {
                overlayUI.transition(.opacity)
            }

            // Тост "Добавлено в закладки" — показывается независимо от showUI
            // (пользователь мог как раз спрятать интерфейс, чтобы читать), см.
            // ReaderViewModel.recordProgress/justAddedToReading.
            if viewModel.justAddedToReading {
                VStack {
                    BookmarkAddedToast()
                        .padding(.top, 54)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.justAddedToReading)
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
            if viewModel.pages.isEmpty { await viewModel.load() }
            preloadUpcoming(from: currentPage)
        }
        .onChange(of: viewModel.currentIndex) { _, _ in currentPage = 0 }
        .onChange(of: currentPage) { _, page in preloadUpcoming(from: page) }
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
                    Task { await viewModel.goTo(index: index) }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(fitWidth: $fitWidth, preloadCount: $preloadCount)
        }
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
        if viewModel.isLoading && viewModel.pages.isEmpty {
            ProgressView().tint(.white)
        } else if let error = viewModel.errorMessage, viewModel.pages.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(error).multilineTextAlignment(.center).font(.footnote)
                Button("Повторить") { Task { await viewModel.load() } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .foregroundStyle(.white)
            .padding(32)
        } else if viewModel.pages.isEmpty {
            Text("Нет страниц").foregroundStyle(.white)
        } else {
            pager
        }
    }

    private var nextChapter: ChapterItem? {
        let n = viewModel.currentIndex + 1
        return viewModel.chapters.indices.contains(n) ? viewModel.chapters[n] : nil
    }

    private var pager: some View {
        TabView(selection: $currentPage) {
            ForEach(Array(viewModel.pages.enumerated()), id: \.offset) { index, page in
                ZoomablePage(
                    candidates: viewModel.imageURLs(for: page),
                    fitWidth: fitWidth,
                    onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
                )
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
        .onChange(of: currentPage) { _, page in
            // Долистали до страницы-триггера — открываем следующую главу.
            if page == viewModel.pages.count + 1 { openNext() }
        }
    }

    // Невидимая страница-триггер (перехода к следующей главе).
    private var nextTriggerPage: some View {
        Color.black
            .overlay { ProgressView().tint(.white) }
    }

    // Экран конца главы: сверху «Конец…», снизу «Следующая глава …».
    private var endPage: some View {
        VStack {
            Text("Конец · \(viewModel.currentChapter?.shortTitle ?? "главы")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                // 60 → 95 (+35): опустили надпись ниже, как попросили.
                .padding(.top, 95)

            Spacer()

            if let next = nextChapter {
                Button {
                    openNext()
                } label: {
                    VStack(spacing: 8) {
                        Text("Следующая глава")
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                        Text(next.titleOrShort)
                            .font(.headline).foregroundStyle(.white)
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
                    .font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
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
                if !viewModel.pages.isEmpty && currentPage < viewModel.pages.count { pageBubble }
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
            titleBadge

            HStack {
                Button { dismiss() } label: {
                    // Крупнее, чем было (40→48, headline→title3): попросили
                    // увеличить крестик.
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
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
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(viewModel.currentChapter?.shortTitle ?? "")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
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
            .foregroundStyle(.white)
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
        HStack {
            readerButton(icon: "line.3.horizontal") { showChapters = true }
            Spacer()
            readerButton(icon: "bookmark") {
                viewModel.markProgress()
            }
            Spacer()
            readerButton(icon: "gearshape") { showSettings = true }
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func readerButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 57, height: 57)
                .contentShape(Rectangle())
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
            // Сплошной непрозрачный фон (как в детальном экране тайтла, где это уже работает
            // идеально). Лист открыт поверх ридера с чёрным фоном — "просвечивание" сквозь
            // presentationBackground там просто показывает блюр чёрного, то есть остаётся
            // чёрным. Поэтому здесь нужен свой видимый непрозрачный фон, а не прозрачность.
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    // Плоский список на самом фоне (по референсу) — без
                    // стеклянной карточки/обводки, только тонкие разделители
                    // между строками.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { position, item in
                            row(item.index, item.chapter)
                            if position < ordered.count - 1 {
                                Divider().overlay(Theme.separator)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
    }

    // Кнопки шапки — отдельные стеклянные капсулы прямо на тёмном фоне
    // (без сплошной подложки на всю ширину, которая «съедала» контраст).
    private var header: some View {
        GlassEffectContainer(spacing: 8) {
            HStack {
                // Крестик слева (не стрелка назад) — как на референсе.
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: Circle())

                Spacer()
                Text("Главы").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()

                // Сортировка справа — цвет иконки белый (textPrimary), а не
                // акцентный оранжевый, как просили.
                Button {
                    withAnimation { descending.toggle() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: Circle())
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
        "Том\(chapter.volume) Гл.\(chapter.number)"
    }

    private func row(_ index: Int, _ chapter: ChapterItem) -> some View {
        let isCurrent = index == currentIndex
        return Button { onSelect(index) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(chapter))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let name = chapter.name, !name.isEmpty {
                        Text(name).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
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
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Настройки читалки: режим вписывания изображения + предзагрузка страниц.
struct ReaderSettingsSheet: View {
    @Binding var fitWidth: Bool
    @Binding var preloadCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Настройки").font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(Theme.textSecondary)
                    }
                }

                Text("Вписывать изображение").font(.subheadline).foregroundStyle(Theme.textSecondary)

                // «Слайдер» между режимами: сегментированный переключатель.
                Picker("", selection: $fitWidth) {
                    Text("По высоте").tag(false)
                    Text("По ширине").tag(true)
                }
                .pickerStyle(.segmented)

                Text(fitWidth
                     ? "Страница заполняет ширину экрана, длинные страницы прокручиваются вниз."
                     : "Вся страница видна целиком по высоте экрана.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)

                // Предзагрузка страниц вперёд — всегда включена (варианта
                // "выкл" нет), регулируется только количество: тот же
                // сегментированный стиль, что и у режима вписывания выше.
                Text("Предзагрузка страниц").font(.subheadline).foregroundStyle(Theme.textSecondary)

                Picker("", selection: $preloadCount) {
                    Text("1").tag(1)
                    Text("3").tag(3)
                    Text("5").tag(5)
                }
                .pickerStyle(.segmented)

                Text("Следующие \(preloadCount) стр. будут скачиваться заранее, пока вы читаете текущую.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

/// Страница главы с честным pinch-to-zoom (якорь в точке щипка), двойным тапом и панорамой.
struct ZoomablePage: View {
    let candidates: [URL]
    let fitWidth: Bool
    let onSingleTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            pageContent(geo)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toggleZoom() } }
                .onTapGesture(count: 1) { onSingleTap() }
        }
    }

    private var image: some View {
        RemoteImage(candidates: candidates) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            ProgressView().tint(.white)
        } failure: {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private func pageContent(_ geo: GeometryProxy) -> some View {
        if fitWidth {
            // По ширине: заполняем ширину, длинные страницы прокручиваются вниз.
            ScrollView(.vertical, showsIndicators: false) {
                image.frame(width: geo.size.width)
            }
        } else {
            let base = image
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale, anchor: .center)   // всегда от центра — предсказуемо и плавно
                .offset(offset)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: scale)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: offset)
                .gesture(magnify(geo))
            if scale > 1 {
                base.simultaneousGesture(pan(geo))
            } else {
                base
            }
        }
    }

    // Pinch от центра: плавно, с мягким возвратом и ограничением сдвига.
    private func magnify(_ geo: GeometryProxy) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), maxScale)
                offset = clamped(offset, in: geo)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.02 {
                    scale = 1; lastScale = 1; resetPan()
                } else {
                    offset = clamped(offset, in: geo)
                    lastOffset = offset
                }
            }
    }

    private func pan(_ geo: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height), in: geo)
            }
            .onEnded { _ in lastOffset = offset }
    }

    /// Не даём утащить картинку за края — она всегда «стремится» к центру.
    private func clamped(_ value: CGSize, in geo: GeometryProxy) -> CGSize {
        let maxX = max((geo.size.width * scale - geo.size.width) / 2, 0)
        let maxY = max((geo.size.height * scale - geo.size.height) / 2, 0)
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }

    private func toggleZoom() {
        if scale > 1 {
            scale = 1; lastScale = 1; resetPan()
        } else {
            scale = 2.5; lastScale = 2.5; resetPan()
        }
    }

    private func resetPan() { offset = .zero; lastOffset = .zero }
}

/// Маленький тост "Добавлено в закладки" (иконка закладки слева + текст) —
/// см. ReaderViewModel.justAddedToReading. Появляется/исчезает через
/// .transition в месте использования (MangaReaderView.body), сам по себе
/// просто статичная плашка.
struct BookmarkAddedToast: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
            Text("Добавлено в закладки")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
