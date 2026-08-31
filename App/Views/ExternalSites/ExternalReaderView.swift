import SwiftUI
import UIKit

/// Full-screen reader for an external site — per a direct request
/// (08/30), a PORT of the REAL MangaReaderView reader, 1-to-1 in feel:
/// the same horizontal pager with genuine UIKit zoom
/// (ZoomableImageScrollView), the same continuous vertical mode
/// (VerticalPageImage + pinch-zoom of the whole feed), the same tap
/// zones (edges page through, center shows/hides the UI), the same
/// palette/glass/settings — and even the same `@AppStorage` keys
/// ("reader_theme"/"reader_page_mode"/...), so the user's choices in
/// MangaLib's regular reader carry over here with no separate setting.
///
/// `ZoomableImageScrollView`/`VerticalPageImage`/`RemoteImageLoader`/
/// `ReaderPalette` are reused DIRECTLY from MangaReaderView.swift, not
/// copied: they're pure UI/networking primitives with no dependency on
/// LibSite models (they take `candidates: [URL]`, not `PageItem`), the
/// same principle already applied to
/// SkeletonBox/StateView/CollapsibleChips/RatingChip in this layer.
///
/// What was NOT ported (deliberately — hitomi/e-hentai simply don't
/// have these concepts, see ExternalSiteCapabilities): chapter/translator
/// list (a gallery is ONE continuous run of pages, not a set of
/// chapters), translation like/rating, bookmarking (hasBookmarks:
/// false), inline per-page comments (hitomi has no comments at all;
/// e-hentai's are attached to the TITLE as a whole — already shown in
/// the card's "Комментарии" tab, see ExternalGalleryDetailView), an
/// "image server" setting (both sites have exactly one real page
/// source, no alternate mirrors/CDNs to choose from).
struct ExternalReaderView: View {
    let site: ExternalSite
    let detail: ExternalGalleryDetail

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var currentPage: Int
    @State private var verticalPage: Int
    @State private var showUI = true
    @State private var showSettings = false
    /// Quick page jump (see ExternalReaderPageJumpSheet) — per a direct
    /// request (08/31), in the same spot/with the same icon as "Chapter
    /// list" in the original reader (line.3.horizontal, see bottomBar),
    /// but opens a page-thumbnail grid + page-number pager instead of a
    /// chapter list (hitomi/e-hentai/3hentai have no concept of chapters
    /// at all).
    @State private var showPageJump = false
    /// The page the vertical reader needs to scroll to (see
    /// verticalReader.onChange) — AFTER a selection in
    /// ExternalReaderPageJumpSheet (simpler in horizontal mode: goToPage
    /// is enough there, TabView switches to the target tag on its own).
    @State private var pendingJumpPage: Int?
    @State private var isCurrentPageZoomed = false
    /// Indices of pages for which preloading has ALREADY been started
    /// (see preloadPage) — without this, on every slight verticalPage
    /// scroll the window (see preloadVerticalWindow) would get
    /// recalculated and re-trigger the very same already-requested
    /// pages.
    @State private var preloadedIndices: Set<Int> = []
    @State private var vScale: CGFloat = 1
    @State private var vScaleBase: CGFloat = 1
    @State private var didScrollToInitial = false

    /// 0 — left, 1 — up (continuous), 2 — right; the same values/key as
    /// MangaReaderView.pageMode.
    @AppStorage("reader_page_mode") private var pageMode = 0
    @AppStorage("reader_theme") private var readerTheme = 0
    @AppStorage("reader_double_tap_zoom") private var doubleTapZoom = true
    @AppStorage("reader_hide_page_number") private var hidePageNumber = false
    @AppStorage("reader_disable_swipe") private var disableSwipe = false
    @AppStorage("reader_smooth_paging") private var smoothPaging = true
    @AppStorage("reader_vertical_gap") private var verticalGap: Double = 0
    @AppStorage("reader_preload_count") private var preloadCount = 3
    /// Its own key (not the shared "reader_fit_width_{type}" from
    /// MangaReaderView) — hitomi/e-hentai have no notion of
    /// "Манга"/"Манхва" with different defaults.
    @AppStorage("external_reader_fit_width") private var fitWidth = false

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }
    private var fg: Color { palette.foreground }
    private var readerBackground: Color { palette.pageBackground }

    /// `initialPage` — open directly on this page (1-based,
    /// `ExternalGalleryPage.index`) — a tap on a thumbnail in the title
    /// card's preview grid (see
    /// ExternalGalleryDetailView.previewGridSection).
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
        .sheet(isPresented: $showPageJump) {
            ExternalReaderPageJumpSheet(pages: detail.pages, currentPage: pageBubbleCurrent) { page in
                showPageJump = false
                performPageJump(to: page)
            }
        }
        .preferredColorScheme(readerTheme == 2 ? nil : (palette.isLight ? .light : .dark))
    }

    /// Jumps to a specific page (see ExternalReaderPageJumpSheet) —
    /// horizontal modes just reuse goToPage (TabView switches to the
    /// target tag on its own, without paging through the ones in
    /// between), the vertical one goes through pendingJumpPage (see
    /// verticalReader.onChange — ScrollViewReader.scrollTo can't be
    /// called directly from here, the proxy lives inside verticalReader
    /// itself).
    private func performPageJump(to page: Int) {
        let clamped = min(max(page, 1), detail.pages.count)
        if pageMode == 1 {
            verticalPage = clamped
            pendingJumpPage = clamped
        } else {
            goToPage(clamped)
        }
    }

    // MARK: Content (pages)

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

    /// Same logic as MangaReaderView.horizontalPageHeight — in "fit
    /// width" mode, with known dimensions, a page can be taller than the
    /// screen (scrolled the rest of the way by the same outer ScrollView
    /// as here).
    private func horizontalPageHeight(geo: GeometryProxy, page: ExternalGalleryPage) -> CGFloat {
        guard fitWidth, page.width > 0, page.height > 0 else { return geo.size.height }
        let scaled = geo.size.width * CGFloat(page.height) / CGFloat(page.width)
        return max(scaled, geo.size.height)
    }

    /// Tapping the left/right side pages through; tapping the center shows/hides the UI.
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

    // MARK: Vertical (continuous) mode

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
                // A jump from ExternalReaderPageJumpSheet (see
                // performPageJump) — the proxy only lives here, inside
                // ScrollViewReader, so we react to pendingJumpPage here
                // rather than directly in performPageJump.
                .onChange(of: pendingJumpPage) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .top)
                    pendingJumpPage = nil
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

    // MARK: Preloading

    /// Resolving a page URL is asynchronous (for e-hentai it's a real
    /// network request for the H@H link, see
    /// EHentaiProvider.pageImageURL), so unlike
    /// MangaReaderView.preloadUpcoming (a ready-made formula, synchronous)
    /// here each page gets its own lightweight task.
    private func preloadUpcoming(from page: Int) {
        guard preloadCount > 0 else { return }
        let start = page + 1
        let end = min(start + preloadCount, detail.pages.count)
        guard start < end else { return }
        for index in start..<end {
            preloadPage(detail.pages[index])
        }
    }

    /// Vertical mode — a window ahead of the current page (per a direct
    /// request — not ALL at once, but the next 50), recalculated as the
    /// user scrolls (see .onChange(of: verticalPage)).
    private static let verticalPreloadWindow = 50

    private func preloadVerticalWindow(from page: Int) {
        let start = page + 1
        let end = min(start + Self.verticalPreloadWindow, detail.pages.count)
        guard start < end else { return }
        for index in start..<end {
            preloadPage(detail.pages[index])
        }
    }

    /// `preloadExternalImage` (ExternalImage.swift), NOT
    /// RemoteImageLoader.preload — that one uses the Referer from
    /// MangaNetworkService (the currently active MangaLib site), which
    /// is wrong for
    /// tn.gold-usergeneratedcontent.net/ehgt.org/*.hath.network — the CDN
    /// responded with 404/403, and preloading silently did nothing
    /// (complaint "I see seams", 08/30). See its doc-comment — the
    /// image is stored in the same RemoteImageCache.shared that
    /// ZoomableImageScrollView/VerticalPageImage check, so those
    /// (reused from MangaReaderView.swift) views simply find it already
    /// there.
    private func preloadPage(_ page: ExternalGalleryPage) {
        guard !preloadedIndices.contains(page.index) else { return }
        preloadedIndices.insert(page.index)
        let galleryId = detail.id
        Task {
            guard let url = try? await provider.pageImageURL(galleryId: galleryId, page: page) else { return }
            await preloadExternalImage(url)
        }
    }

    // MARK: UI (top bar/bubble/bottom bar) — 1-to-1 style with
    // MangaReaderView.overlayUI/topBar/pageBubble/bottomBar, without
    // chapters/bookmarking/in-reader comments (external sites have no
    // such concepts, see the type's doc-comment).

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
            // line.3.horizontal — the same spot/icon as "Список глав" in
            // the original reader (see MangaReaderView.bottomBar — same
            // left position there), it just opens not a chapter list
            // (that concept doesn't exist here at all) but a quick page
            // jump.
            readerButton(icon: "line.3.horizontal") { showPageJump = true }
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

// MARK: - Horizontal-mode page (asynchronous URL resolution + ZoomableImageScrollView)

/// Wraps `ZoomableImageScrollView` (see MangaReaderView.swift — reused
/// DIRECTLY, the same UIKit zoom/pan/double-tap) — there `candidates` is
/// a synchronous `[URL]`, while external providers resolve a page URL
/// asynchronously (see ExternalSiteProvider.pageImageURL).
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
            guard let url = try? await provider.pageImageURL(galleryId: galleryId, page: page) else { return }
            // Warm RemoteImageCache with the CORRECT (per-host) Referer
            // session BEFORE handing the url to ZoomableImageScrollView —
            // without this, the CURRENT (visible right now) page, unlike
            // the ones preloaded ahead of time (see preloadPage), had no
            // chance of ending up in the cache beforehand: page 1 is
            // never preloaded at all (the preload window starts from the
            // next one), so ZoomableImageScrollView/RemoteImageLoader
            // inside it would ALWAYS try to fetch it themselves — with
            // the wrong session's Referer (see preloadExternalImage
            // doc-comment) — 404, the image fails to decode, and the
            // first (sometimes the second too, if TabView renders it
            // before preloading catches up) page of the reader just
            // stayed a black background (complaint on 08/31).
            await preloadExternalImage(url)
            resolvedURL = url
        }
    }
}

/// The same wrapper for vertical mode — `VerticalPageImage`
/// (MangaReaderView.swift, reused directly).
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
            guard let url = try? await provider.pageImageURL(galleryId: galleryId, page: page) else { return }
            // See ExternalHorizontalPageImage.task — the same race with
            // the wrong Referer for the CURRENTLY visible (not
            // preloaded ahead of time) page, the same fix: warm the
            // cache with the CORRECT session before handing the url to
            // VerticalPageImage.
            await preloadExternalImage(url)
            resolvedURL = url
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

// MARK: - Reader settings (1-to-1 style with
// MangaReaderView.ReaderSettingsSheet, without "Image server" — hitomi/e-hentai
// have no alternate mirrors)

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

// MARK: - Quick page jump (bottomBar.line.3.horizontal, 08/31)

/// A preview grid of ALL pages (3 columns, tap jumps immediately and
/// closes the sheet) + a fixed (not scrolling with the grid) page-number
/// pager at the bottom ("1 2 3 … 67 69", the same truncated logic as
/// ExternalGalleryDetailView.paginationSequence — a 1-to-1 approach,
/// just over the ACTUAL reading pages here, not over the title card's
/// preview-grid batches, since the reader is already open — no need to
/// duplicate that pagination). The grid sits inside a `ScrollView`, and
/// the sheet uses `.presentationDetents([.large])` so it doesn't grow
/// endlessly downward with a large page count (per a direct request).
private struct ExternalReaderPageJumpSheet: View {
    let pages: [ExternalGalleryPage]
    let currentPage: Int
    let onSelect: (Int) -> Void

    @State private var jumpText = ""

    private static let columns = 3
    private static let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            Text("Страницы")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                grid
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Theme.separator)

            paginationRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Thumbnail grid

    private var grid: some View {
        let availableWidth = UIScreen.main.bounds.width - 32
        let totalSpacing = Self.spacing * CGFloat(Self.columns - 1)
        let cellWidth = ((availableWidth - totalSpacing) / CGFloat(Self.columns)).rounded(.down)
        let cellHeight = (cellWidth * 4 / 3).rounded()
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.spacing), count: Self.columns)

        return LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(pages, id: \.index) { page in
                Button {
                    onSelect(page.index)
                } label: {
                    thumb(page, width: cellWidth, height: cellHeight)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func thumb(_ page: ExternalGalleryPage, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = page.thumbnailURL, let offsetX = page.thumbnailSpriteOffsetX {
                    // e-hentai: a sprite covering a batch of pages,
                    // offsetX is the tile we need (see
                    // ExternalGalleryDetailView.previewThumb — same
                    // approach).
                    ExternalSpriteThumbnail(url: url, offsetX: offsetX, tileWidth: page.width, tileHeight: page.height) { SkeletonBox() }
                        .scaledToFill()
                } else if let url = page.thumbnailURL {
                    ExternalImage(url: url) { SkeletonBox() }
                        .scaledToFill()
                } else {
                    SkeletonBox()
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()
            .overlay {
                if page.index == currentPage {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 2)
                }
            }

            Text("\(page.index)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 14)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    // MARK: Number pager + "jump to page" field

    private var paginationRow: some View {
        HStack(spacing: 8) {
            ScrollViewReader { pagerProxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(paginationSequence.enumerated()), id: \.offset) { _, item in
                            if let page = item {
                                Button {
                                    onSelect(page)
                                } label: {
                                    Text("\(page)")
                                        .font(.footnote.weight(page == currentPage ? .semibold : .regular))
                                        .foregroundStyle(page == currentPage ? Theme.background : Theme.textPrimary)
                                        .frame(width: 28, height: 28)
                                        .background(page == currentPage ? Theme.accent : Theme.surfaceElevated, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .id(page)
                            } else {
                                Text("…")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 20, height: 28)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        pagerProxy.scrollTo(currentPage, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 0)

            TextField("№", text: $jumpText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .frame(width: 44, height: 28)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button {
                if let page = Int(jumpText), page > 0 {
                    onSelect(min(page, pages.count))
                    jumpText = ""
                }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Int(jumpText) != nil ? Theme.accent : Theme.textSecondary.opacity(0.4))
            }
            .disabled(Int(jumpText) == nil)
        }
    }

    /// "1 2 3 … 67 69" — 1-to-1 truncated logic with
    /// ExternalGalleryDetailView.paginationSequence (see its
    /// doc-comment), just over ACTUAL reading pages here.
    private var paginationSequence: [Int?] {
        let total = pages.count
        guard total > 7 else { return (1...max(total, 1)).map { $0 } }
        var keep: Set<Int> = [1, 2, total - 1, total, currentPage - 1, currentPage, currentPage + 1]
        keep = keep.filter { $0 >= 1 && $0 <= total }
        let sorted = keep.sorted()
        var result: [Int?] = []
        var previous = 0
        for page in sorted {
            if page - previous > 1 { result.append(nil) }
            result.append(page)
            previous = page
        }
        return result
    }
}
