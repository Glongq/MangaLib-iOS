import SwiftUI
import UIKit

/// Полноэкранная читалка внешнего сайта — по прямой просьбе (30.08) ПОРТ
/// РЕАЛЬНОЙ читалки MangaReaderView, 1-в-1 по ощущениям: тот же
/// горизонтальный пейджер с настоящим UIKit-зумом (ZoomableImageScrollView),
/// тот же непрерывный вертикальный режим (VerticalPageImage + пинч-зум всей
/// ленты), те же тап-зоны (края листают, центр показывает/прячет интерфейс),
/// та же палитра/стекло/настройки — и даже те же ключи `@AppStorage`
/// ("reader_theme"/"reader_page_mode"/... ), чтобы выбор пользователя в
/// обычной читалке МангаЛиба переносился сюда без отдельной настройки.
///
/// `ZoomableImageScrollView`/`VerticalPageImage`/`RemoteImageLoader`/
/// `ReaderPalette` — переиспользуются НАПРЯМУЮ из MangaReaderView.swift, не
/// копируются: это чистые UI/сетевые примитивы без зависимости от LibSite-
/// моделей (принимают `candidates: [URL]`, не `PageItem`), тот же принцип,
/// что уже применён к SkeletonBox/StateView/CollapsibleChips/RatingChip в
/// этом слое.
///
/// Что НЕ портировано (сознательно, у hitomi/e-hentai просто нет этих
/// понятий, см. ExternalSiteCapabilities): список глав/переводчиков (галерея
/// — ОДНА непрерывная выдача страниц, не набор глав), лайк/оценка перевода,
/// закладка (hasBookmarks: false), инлайн-комментарии по странице (у
/// hitomi комментариев нет вообще, у e-hentai они привязаны к ТАЙТЛУ
/// целиком — уже показаны во вкладке «Комментарии» карточки, см.
/// ExternalGalleryDetailView), «Сервер картинок» в настройках (у обоих
/// сайтов ровно один реальный источник страницы, нет альтернативных
/// зеркал/CDN на выбор).
struct ExternalReaderView: View {
    let site: ExternalSite
    let detail: ExternalGalleryDetail

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var currentPage: Int
    @State private var verticalPage: Int
    @State private var showUI = true
    @State private var showSettings = false
    @State private var isCurrentPageZoomed = false
    /// Индексы страниц, для которых предзагрузка УЖЕ запущена (см.
    /// preloadPage) — без этого при каждом чуть-чуть прокрученном
    /// verticalPage окно (см. preloadVerticalWindow) пересчитывалось бы и
    /// заново дёргало те же самые уже запрошенные страницы.
    @State private var preloadedIndices: Set<Int> = []
    @State private var vScale: CGFloat = 1
    @State private var vScaleBase: CGFloat = 1
    @State private var didScrollToInitial = false

    /// 0 — влево, 1 — вверх (непрерывный), 2 — вправо; те же значения/ключ,
    /// что и у MangaReaderView.pageMode.
    @AppStorage("reader_page_mode") private var pageMode = 0
    @AppStorage("reader_theme") private var readerTheme = 0
    @AppStorage("reader_double_tap_zoom") private var doubleTapZoom = true
    @AppStorage("reader_hide_page_number") private var hidePageNumber = false
    @AppStorage("reader_disable_swipe") private var disableSwipe = false
    @AppStorage("reader_smooth_paging") private var smoothPaging = true
    @AppStorage("reader_vertical_gap") private var verticalGap: Double = 0
    @AppStorage("reader_preload_count") private var preloadCount = 3
    /// Свой ключ (не общий "reader_fit_width_{type}" MangaReaderView) — у
    /// hitomi/e-hentai нет понятия "Манга"/"Манхва" с разными дефолтами.
    @AppStorage("external_reader_fit_width") private var fitWidth = false

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }
    private var fg: Color { palette.foreground }
    private var readerBackground: Color { palette.pageBackground }

    /// `initialPage` — открыть сразу на этой странице (1-based,
    /// `ExternalGalleryPage.index`) — тап по миниатюре в превью-гриде
    /// карточки тайтла (см. ExternalGalleryDetailView.previewGridSection).
    init(site: ExternalSite, detail: ExternalGalleryDetail, initialPage: Int? = nil) {
        self.site = site
        self.detail = detail
        let clamped = min(max(initialPage ?? 1, 1), max(detail.pages.count, 1))
        _currentPage = State(initialValue: clamped)
        _verticalPage = State(initialValue: clamped)
    }

    var body: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            content

            overlayUI
                .opacity(showUI ? 1 : 0)
                .blur(radius: showUI ? 0 : 12)
                .allowsHitTesting(showUI)
                .animation(.easeInOut(duration: 0.16), value: showUI)

            if !hidePageNumber, !detail.pages.isEmpty {
                VStack {
                    Spacer()
                    pageBubble
                }
                .padding(.bottom, showUI ? 96 : 34)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.16), value: showUI)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(!showUI)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if pageMode == 1 { preloadVerticalWindow(from: verticalPage) } else { preloadUpcoming(from: currentPage) }
        }
        .onChange(of: currentPage) { _, page in
            isCurrentPageZoomed = false
            if pageMode != 1 { preloadUpcoming(from: page) }
        }
        .onChange(of: verticalPage) { _, page in
            if pageMode == 1 { preloadVerticalWindow(from: page) }
        }
        .onChange(of: pageMode) { _, mode in
            if mode == 1 { preloadVerticalWindow(from: verticalPage) } else { preloadUpcoming(from: currentPage) }
        }
        .sheet(isPresented: $showSettings) {
            ExternalReaderSettingsSheet(
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
        .preferredColorScheme(readerTheme == 2 ? nil : (palette.isLight ? .light : .dark))
    }

    // MARK: Контент (страницы)

    @ViewBuilder
    private var content: some View {
        if detail.pages.isEmpty {
            Text("Нет страниц").foregroundStyle(fg)
        } else if pageMode == 1 {
            verticalReader
        } else if disableSwipe {
            singlePageView
        } else {
            pager
        }
    }

    private var singlePageView: some View {
        let index = min(max(currentPage, 1), detail.pages.count) - 1
        return externalHorizontalPage(index: index, page: detail.pages[index])
            .id(currentPage)
    }

    private var pager: some View {
        TabView(selection: $currentPage) {
            ForEach(Array(detail.pages.enumerated()), id: \.offset) { index, page in
                externalHorizontalPage(index: index, page: page)
                    .tag(index + 1)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    private func externalHorizontalPage(index: Int, page: ExternalGalleryPage) -> some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                ExternalHorizontalPageImage(
                    provider: provider, galleryId: detail.id, page: page,
                    fitWidth: fitWidth, doubleTapZoom: doubleTapZoom,
                    ringColor: UIColor(fg),
                    onTap: { xFraction in handleReaderTap(xFraction) },
                    onZoomChanged: { zoomed in isCurrentPageZoomed = zoomed }
                )
                .frame(width: geo.size.width, height: horizontalPageHeight(geo: geo, page: page))
            }
            .scrollDisabled(isCurrentPageZoomed)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea()
    }

    /// Та же логика, что и у MangaReaderView.horizontalPageHeight — при
    /// "по ширине" на известных размерах страница может быть выше экрана
    /// (докручивается тем же внешним ScrollView, что и здесь).
    private func horizontalPageHeight(geo: GeometryProxy, page: ExternalGalleryPage) -> CGFloat {
        guard fitWidth, page.width > 0, page.height > 0 else { return geo.size.height }
        let scaled = geo.size.width * CGFloat(page.height) / CGFloat(page.width)
        return max(scaled, geo.size.height)
    }

    /// Тап по левой/правой части листает, по центру — показывает/прячет интерфейс.
    private func handleReaderTap(_ xFraction: CGFloat) {
        if xFraction < 0.2 {
            goToPage(currentPage - 1)
        } else if xFraction > 0.8 {
            goToPage(currentPage + 1)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() }
        }
    }

    private func goToPage(_ target: Int) {
        let clamped = min(max(target, 1), detail.pages.count)
        guard clamped != currentPage else { return }
        if smoothPaging {
            withAnimation(.easeInOut(duration: 0.167)) { currentPage = clamped }
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { currentPage = clamped }
        }
    }

    // MARK: Вертикальный (непрерывный) режим

    private var verticalReader: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: CGFloat(verticalGap)) {
                        ForEach(Array(detail.pages.enumerated()), id: \.offset) { index, page in
                            ExternalVerticalPageImage(provider: provider, galleryId: detail.id, page: page)
                                .id(index + 1)
                                .background(
                                    GeometryReader { pageGeo in
                                        Color.clear.preference(
                                            key: ExternalVerticalPagePositionKey.self,
                                            value: [ExternalVerticalPagePosition(
                                                pageIndex: index,
                                                midY: pageGeo.frame(in: .named("externalVerticalReaderScroll")).midY
                                            )]
                                        )
                                    }
                                )
                        }
                    }
                    .frame(width: geo.size.width * vScale)
                }
                .coordinateSpace(name: "externalVerticalReaderScroll")
                .onPreferenceChange(ExternalVerticalPagePositionKey.self) { positions in
                    let viewportCenter = geo.size.height / 2
                    guard let nearest = positions.min(by: { abs($0.midY - viewportCenter) < abs($1.midY - viewportCenter) }) else { return }
                    if verticalPage != nearest.pageIndex + 1 { verticalPage = nearest.pageIndex + 1 }
                }
                .onAppear {
                    guard !didScrollToInitial else { return }
                    didScrollToInitial = true
                    guard currentPage > 1 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(currentPage, anchor: .top)
                    }
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

    // MARK: Предзагрузка

    /// Разрешение URL страницы — асинхронное (у e-hentai реальный сетевой
    /// запрос за H@H-ссылкой, см. EHentaiProvider.pageImageURL), поэтому в
    /// отличие от MangaReaderView.preloadUpcoming (готовая формула,
    /// синхронно) здесь на каждую страницу — своя лёгкая задача.
    private func preloadUpcoming(from page: Int) {
        guard preloadCount > 0 else { return }
        let start = page + 1
        let end = min(start + preloadCount, detail.pages.count)
        guard start < end else { return }
        for index in start..<end {
            preloadPage(detail.pages[index])
        }
    }

    /// Вертикальный режим — окно вперёд от текущей страницы (по прямой
    /// просьбе — не ВСЁ сразу, а следующие 50), пересчитывается по мере
    /// прокрутки (см. .onChange(of: verticalPage)).
    private static let verticalPreloadWindow = 50

    private func preloadVerticalWindow(from page: Int) {
        let start = page + 1
        let end = min(start + Self.verticalPreloadWindow, detail.pages.count)
        guard start < end else { return }
        for index in start..<end {
            preloadPage(detail.pages[index])
        }
    }

    private func preloadPage(_ page: ExternalGalleryPage) {
        guard !preloadedIndices.contains(page.index) else { return }
        preloadedIndices.insert(page.index)
        let galleryId = detail.id
        Task {
            guard let url = try? await provider.pageImageURL(galleryId: galleryId, page: page) else { return }
            RemoteImageLoader.preload(candidates: [url])
        }
    }

    // MARK: Интерфейс (топ/бабл/низ) — 1-в-1 стиль MangaReaderView.overlayUI/
    // topBar/pageBubble/bottomBar, без глав/закладки/комментариев-в-ридере
    // (у внешних сайтов этих понятий нет, см. doc-comment типа).

    private var overlayUI: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
    }

    private var topBar: some View {
        ZStack {
            titleBadge
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(fg)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.leading, 16)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
    }

    private static let titleBadgeSideMargin: CGFloat = 84
    private var titleBadgeMaxWidth: CGFloat {
        max(120, UIScreen.main.bounds.width - Self.titleBadgeSideMargin * 2)
    }

    private var titleBadge: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(detail.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(.tail)
            if !detail.type.isEmpty {
                Text(detail.type.capitalized)
                    .font(.caption2)
                    .foregroundStyle(fg.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: titleBadgeMaxWidth)
        .glassEffect(.regular, in: Capsule())
    }

    private var pageBubbleCurrent: Int { pageMode == 1 ? verticalPage : currentPage }

    private var pageBubble: some View {
        Text("\(pageBubbleCurrent)/\(detail.pages.count)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    private var bottomBar: some View {
        HStack {
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
}

// MARK: - Страница горизонтального режима (асинхронное разрешение URL + ZoomableImageScrollView)

/// Оборачивает `ZoomableImageScrollView` (см. MangaReaderView.swift —
/// переиспользуется НАПРЯМУЮ, тот же UIKit-зум/пан/двойной тап) —
/// `candidates` там синхронный `[URL]`, а у внешних провайдеров URL
/// страницы разрешается асинхронно (см. ExternalSiteProvider.pageImageURL).
private struct ExternalHorizontalPageImage: View {
    let provider: any ExternalSiteProvider
    let galleryId: Int
    let page: ExternalGalleryPage
    let fitWidth: Bool
    let doubleTapZoom: Bool
    let ringColor: UIColor
    let onTap: (CGFloat) -> Void
    let onZoomChanged: (Bool) -> Void

    @State private var resolvedURL: URL?

    var body: some View {
        GeometryReader { geo in
            ZoomableImageScrollView(
                candidates: resolvedURL.map { [$0] } ?? [],
                fitWidth: fitWidth,
                doubleTapZoom: doubleTapZoom,
                onTap: onTap,
                onZoomChanged: onZoomChanged,
                ringColor: ringColor,
                viewportHeight: geo.size.height
            )
        }
        .task {
            resolvedURL = try? await provider.pageImageURL(galleryId: galleryId, page: page)
        }
    }
}

/// Та же обёртка для вертикального режима — `VerticalPageImage`
/// (MangaReaderView.swift, переиспользуется напрямую).
private struct ExternalVerticalPageImage: View {
    let provider: any ExternalSiteProvider
    let galleryId: Int
    let page: ExternalGalleryPage

    @State private var resolvedURL: URL?

    var body: some View {
        VerticalPageImage(
            candidates: resolvedURL.map { [$0] } ?? [],
            width: page.width > 0 ? page.width : nil,
            height: page.height > 0 ? page.height : nil
        )
        .task {
            resolvedURL = try? await provider.pageImageURL(galleryId: galleryId, page: page)
        }
    }
}

private struct ExternalVerticalPagePosition: Equatable {
    let pageIndex: Int
    let midY: CGFloat
}

private struct ExternalVerticalPagePositionKey: PreferenceKey {
    static var defaultValue: [ExternalVerticalPagePosition] = []
    static func reduce(value: inout [ExternalVerticalPagePosition], nextValue: () -> [ExternalVerticalPagePosition]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Настройки читалки (1-в-1 стиль MangaReaderView.ReaderSettingsSheet,
// без «Сервера картинок» — у hitomi/e-hentai нет альтернативных зеркал)

private struct ExternalReaderSettingsSheet: View {
    @Binding var fitWidth: Bool
    @Binding var preloadCount: Int
    @Binding var pageMode: Int
    @Binding var readerTheme: Int
    @Binding var doubleTapZoom: Bool
    @Binding var hidePageNumber: Bool
    @Binding var disableSwipe: Bool
    @Binding var smoothPaging: Bool
    @Binding var verticalGap: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showPaging = false
    private let gapHaptic = UIImpactFeedbackGenerator(style: .light)

    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }
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
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.headline)
                                    .foregroundStyle(palette.foreground)
                                    .frame(width: 40, height: 40)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                        }
                    }

                    label("Тип листания")
                    Picker("", selection: $pageMode) {
                        Text("Влево").tag(0); Text("Вверх").tag(1); Text("Вправо").tag(2)
                    }.pickerStyle(.segmented)

                    label("Тема читалки")
                    Picker("", selection: $readerTheme) {
                        Text("Светлая").tag(1); Text("Тёмная").tag(0); Text("Системная").tag(2)
                    }.pickerStyle(.segmented)

                    if pageMode != 1 {
                        label("Вместить изображение")
                        Picker("", selection: $fitWidth) {
                            Text("По высоте").tag(false); Text("По ширине").tag(true)
                        }.pickerStyle(.segmented)
                    }

                    label("Предзагрузка страниц")
                    Picker("", selection: $preloadCount) {
                        Text("1").tag(1); Text("3").tag(3); Text("5").tag(5)
                    }.pickerStyle(.segmented)

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

                    toggleRow("Увеличить двойным нажатием", isOn: $doubleTapZoom)
                    toggleRow("Скрыть номер страниц", isOn: $hidePageNumber)

                    Spacer(minLength: 0)
                }
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

    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(palette.secondary).padding(.horizontal, 4)
    }

    private func toggleRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).foregroundStyle(palette.foreground)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

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
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 20)
        }
        .presentationDetents([.height(Self.pagingSheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .tint(Theme.accent)
    }
}
