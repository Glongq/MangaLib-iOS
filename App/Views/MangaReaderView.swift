import SwiftUI
import UIKit

/// Полноэкранная читалка: горизонтальное листание страниц, тап переключает интерфейс.
struct MangaReaderView: View {

    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0
    @State private var showUI = true
    @State private var showChapters = false
    @State private var showSettings = false
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
            if viewModel.pages.isEmpty { await viewModel.load() }
            preloadUpcoming(from: currentPage)
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            currentPage = 0
            // На новой главе заливка закладки возвращается «как была».
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkFilled = false }
        }
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
                ZoomableImageScrollView(
                    candidates: viewModel.imageURLs(for: page),
                    fitWidth: fitWidth,
                    onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
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
        // Каждая кнопка — отдельная круглая стеклянная подложка (а не общая
        // капсула), как попросили.
        HStack {
            readerButton(icon: "line.3.horizontal") { showChapters = true }
            Spacer()
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
                .foregroundStyle(.white)
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
                .foregroundStyle(.white)
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
                    // Список на скруглённой подложке (как в настройках), с теми
                    // же тонкими разделителями между строками.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { position, item in
                            row(item.index, item.chapter)
                            if position < ordered.count - 1 {
                                Divider().overlay(Theme.separator)
                            }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
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
        "Том \(chapter.volume) • Глава \(chapter.number)"
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
            .padding(.horizontal, 16)
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
    /// Сервер картинок (Первый/Второй/Сжатия) — общий с окном скачивания, см.
    /// ImageServerChoice. Влияет на то, откуда грузятся/качаются страницы.
    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0
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

                // Сервер картинок — тот же сегментированный «слайдер», что и
                // предзагрузка. Выбранный сервер пробуется первым и в читалке,
                // и при скачивании (см. MangaImageURL.pageURLs).
                Text("Сервер картинок").font(.subheadline).foregroundStyle(Theme.textSecondary)

                Picker("", selection: $serverChoice) {
                    ForEach(ImageServerChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                Text("Если страницы не грузятся — попробуйте другой сервер.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 0)
            }
            // Больше отступ сверху (от «шапки» листа).
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 20)
        }
        // Открывается сразу до верха.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(.dark)
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
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap, fitWidth: fitWidth) }

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

        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
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
        context.coordinator.onSingleTap = onSingleTap
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
        var onSingleTap: () -> Void
        var fitWidth: Bool
        var currentKey: URL?
        private var loadTask: Task<Void, Never>?
        private var lastBounds: CGSize = .zero

        init(onSingleTap: @escaping () -> Void, fitWidth: Bool) {
            self.onSingleTap = onSingleTap
            self.fitWidth = fitWidth
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

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
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
