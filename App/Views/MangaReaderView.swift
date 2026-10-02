import SwiftUI
import UIKit

/// Reader palette for dark, light, and system themes.
struct ReaderPalette {
    let isLight: Bool
    /// Use black in dark mode and a slightly gray canvas in light mode.
    var pageBackground: Color { isLight ? Color(white: 0.93) : .black }
    /// Menu colors follow the fixed reader theme, independently of the app theme.
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

/// Lightweight team profile model used by the chapter credits sheet.
private struct SelectedTeam: Identifiable {
    let id: Int
    let slugURL: String
    let name: String
    let coverURL: URL?
}

/// Full-screen manga reader with page gestures and overlay controls.
struct MangaReaderView: View {

    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    /// A page selection belongs to one chapter throughout a swipe.
    private struct PagerSelection: Hashable {
        let chapterIndex: Int
        let page: Int
    }

    @State private var selectedPage: PagerSelection
    private var currentPage: Int { selectedPage.page }
    @State private var isPreparingImageServers = true
    @State private var imageServerError: String?
    @State private var loadedPageMode: Int?

    /// When moving backward, land on the previous chapter's end page.
    @State private var pendingLandOnEnd = false
    /// Tracks which chapter has already received its initial page selection, including cached chapters with equal page counts.
    @State private var pagesAppliedForIndex: Int?
    @State private var showUI = true
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showComments = false
    /// Team profile selected from the chapter credits chip.
    @State private var selectedTeam: SelectedTeam?
    /// Translation rating sheet opened from the chapter actions.
    @State private var showTranslationRating = false
    /// Tracks whether comments on the chapter end page have been revealed.
    @State private var endCommentsRevealed = false
    @State private var isPagingZoomed = false
    /// Local bookmark button fill state, reset when the chapter changes.
    @State private var bookmarkFilled = false

    /// Image fitting is stored by manga type: width for manhwa by default, height otherwise.
    @AppStorage private var fitWidth: Bool

    /// Number of upcoming images to preload across reader modes.
    @AppStorage("reader_preload_count") private var preloadCount = 3

    /// Changing the image server recreates the page content.
    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0
    /// Page mode: horizontal, vertical, or reverse horizontal.
    @AppStorage("reader_page_mode") private var pageMode = 0
    /// Reader theme: dark, light, or system.
    @AppStorage("reader_theme") private var readerTheme = 0
    /// Enables double-tap image zoom.
    @AppStorage("reader_double_tap_zoom") private var doubleTapZoom = true
    /// Hides the page number indicator.
    @AppStorage("reader_hide_page_number") private var hidePageNumber = false
    /// Disables swipe-based page changes.
    @AppStorage("reader_disable_swipe") private var disableSwipe = false
    /// Animates page changes initiated by tapping when enabled.
    @AppStorage("reader_smooth_paging") private var smoothPaging = true
    /// Spacing between images in the continuous vertical reader.
    @AppStorage("reader_vertical_gap") private var verticalGap: Double = 0
    @AppStorage("reader_scroll_inertia_multiplier") private var scrollInertiaMultiplier = ReaderScrollInertia.defaultMultiplier

    /// Current vertical page for the page indicator and comments.
    @State private var verticalPage = 1
    @State private var verticalPreloadPosition: PagerSelection?

    /// Vertical zoom enlarges the actual content width so native horizontal panning remains available.
    @State private var vScale: CGFloat = 1
    @State private var vScaleBase: CGFloat = 1

    /// Edge taps change pages; center taps toggle the controls.
    @Environment(\.colorScheme) private var systemColorScheme

    /// Colors shared by the reader canvas and menus.
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }
    private var readerIsLight: Bool { palette.isLight }
    private var readerBackground: Color { palette.pageBackground }
    /// Foreground color follows the selected reader theme.
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
        let initialIndex = min(max(startIndex, 0), max(chapters.count - 1, 0))
        _selectedPage = State(initialValue: PagerSelection(chapterIndex: initialIndex, page: 1))
        _viewModel = StateObject(wrappedValue: ReaderViewModel(
            slug: slug, chapters: chapters, startIndex: startIndex,
            mangaId: mangaId, mangaTitle: mangaTitle, coverURL: coverURL,
            preferredBranchId: preferredBranchId, siteId: siteId
        ))
        self.mangaTitle = mangaTitle
        _fitWidth = AppStorage(wrappedValue: Self.defaultFitWidth(forType: mangaTypeName), Self.fitWidthKey(forType: mangaTypeName))
    }

    private let mangaTitle: String?

    /// Manhwa defaults to fitting images by width; other types fit by height.
    private static func defaultFitWidth(forType typeName: String?) -> Bool {
        typeName == "Манхва"
    }

    /// Store fitting preferences separately for each manga type.
    private static func fitWidthKey(forType typeName: String?) -> String {
        "reader_fit_width_\(typeName ?? "unknown")"
    }

    var body: some View {
        ZStack {
            readerBackground.ignoresSafeArea()

            content
                // Recreate pages when the image server changes.
                .id(serverChoice)

            // Keep reader controls mounted while fading and blurring them.
            overlayUI
                .opacity(showUI ? 1 : 0)
                .blur(radius: showUI ? 0 : 12)
                .allowsHitTesting(showUI)
                .animation(.easeInOut(duration: 0.16), value: showUI)

            // The page indicator remains visible when the controls are hidden.
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

            // Show the bookmark toast outside the glass container to avoid layout shifts.
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

            // Inline comments appear over the vertical reader and load for the current page.
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
        // Ignore only the bottom safe area so the controls retain their top alignment.
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(!showUI)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: pageMode) { await prepareAndLoadReader() }
        // Switch between reading modes without leaving the reader.
        .onChange(of: pageMode) { _, _ in
            verticalPreloadPosition = nil
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            // Reset bookmark button fill for the new chapter.
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkFilled = false }
            endCommentsRevealed = false
            isPagingZoomed = false
            // Apply landing immediately when cached pages are already available.
            applyLandingIfNeeded()
        }
        // Apply landing again when network-loaded pages arrive.
        .onChange(of: viewModel.pages.count) { _, _ in
            applyLandingIfNeeded()
        }
        .onChange(of: viewModel.segments.last?.index) { _, _ in
            guard pageMode == 1, let segment = viewModel.segments.last else { return }
            preloadUpcoming(in: segment.pages, from: -1)
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet(
                chapters: viewModel.chapters,
                currentIndex: viewModel.currentIndex,
                currentBranchId: viewModel.preferredBranchId,
                onSelect: { index in
                    showChapters = false
                    // Chapter list selection always opens at page one.
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
                verticalGap: $verticalGap,
                scrollInertiaMultiplier: $scrollInertiaMultiplier
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

    // MARK: Page preloading

    @MainActor
    private func prepareAndLoadReader() async {
        isPreparingImageServers = true
        imageServerError = nil

        if let chapter = viewModel.currentChapter {
            let branchId = viewModel.preferredBranchId ?? chapter.primaryBranchId
            let offlinePages = DownloadsManager.shared.localPageFiles(
                slug: viewModel.slug, chapterId: chapter.id, branchId: branchId
            )
            let siteId = viewModel.siteId ?? SiteSession.shared.activeSite.rawValue
            if offlinePages.isEmpty {
                guard await ReaderImageServerConfiguration.ensureAvailable(for: siteId) else {
                    guard !Task.isCancelled else { return }
                    imageServerError = "Не удалось получить серверы изображений. Проверьте соединение и повторите попытку."
                    isPreparingImageServers = false
                    return
                }
            } else if !ReaderImageServerConfiguration.isAvailable(for: siteId) {
                // Offline pages can open immediately while server discovery runs in the background.
                Task { _ = await ReaderImageServerConfiguration.ensureAvailable(for: siteId) }
            }
        }

        guard !Task.isCancelled else { return }
        isPreparingImageServers = false
        let mode = pageMode
        if mode == 1 {
            await viewModel.startVertical()
        } else if viewModel.pages.isEmpty || loadedPageMode != mode {
            await viewModel.load()
        }
        guard !Task.isCancelled else { return }
        loadedPageMode = mode
        applyLandingIfNeeded()
    }

    /// Preload the next `preloadCount` images after a zero-based page index.
    private func preloadUpcoming(in pages: [PageItem], from page: Int) {
        guard preloadCount > 0 else { return }
        let start = page + 1
        let end = min(start + preloadCount, pages.count)
        guard start < end else { return }
        for index in start..<end {
            RemoteImageLoader.preload(candidates: viewModel.imageURLs(for: pages[index]))
        }
    }

    private func preloadUpcoming(from page: Int) {
        preloadUpcoming(in: viewModel.pages, from: page)
    }

    // MARK: Reader content

    @ViewBuilder
    private var content: some View {
        if isPreparingImageServers {
            ProgressView().tint(fg)
        } else if let imageServerError {
            errorView(imageServerError) { Task { await prepareAndLoadReader() } }
        } else if pageMode == 1 {
            verticalContent
        } else if viewModel.isLoading && viewModel.pages.isEmpty {
            ProgressView().tint(fg)
        } else if let error = viewModel.errorMessage, viewModel.pages.isEmpty {
            errorView(error) { Task { await viewModel.load() } }
        } else if viewModel.pages.isEmpty {
            Text("Нет страниц").foregroundStyle(fg)
        } else if disableSwipe {
            // Show only the selected page when swipe paging is disabled.
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

    // MARK: Continuous vertical reader

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
        ReaderVerticalCollectionView(
            items: verticalItems,
            gap: CGFloat(verticalGap),
            scale: vScale,
            inertiaMultiplier: scrollInertiaMultiplier,
            appearanceRevision: readerAppearanceRevision,
            onVisiblePage: { chapterIndex, pageIndex in
                guard pageMode == 1,
                      viewModel.segments.contains(where: { $0.index == chapterIndex }) else { return }
                if chapterIndex != viewModel.currentIndex {
                    viewModel.markCurrentChapter(chapterIndex)
                }
                verticalPage = pageIndex + 1
                let position = PagerSelection(chapterIndex: chapterIndex, page: pageIndex + 1)
                if verticalPreloadPosition != position,
                   let segment = viewModel.segments.first(where: { $0.index == chapterIndex }) {
                    verticalPreloadPosition = position
                    preloadUpcoming(in: segment.pages, from: pageIndex)
                }
            },
            onFooter: { chapterIndex in
                guard pageMode == 1, viewModel.segments.last?.index == chapterIndex else { return }
                Task { await viewModel.appendNext() }
            },
            onPrefetch: { positions in
                for (chapterIndex, pageIndex) in positions {
                    guard let segment = viewModel.segments.first(where: { $0.index == chapterIndex }) else { continue }
                    preloadUpcoming(in: segment.pages, from: pageIndex - 1)
                }
            },
            content: { item, width, onImageSize in
                verticalItem(item, displayWidth: width, onImageSize: onImageSize)
            }
        )
            .overlay(alignment: .bottom) {
                if viewModel.isAppending {
                    ProgressView().tint(fg).padding(24)
                }
            }
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
                let target: CGFloat = vScale > 1 ? 1 : 1.4
                withAnimation(.easeOut(duration: 0.2)) { vScale = target }
                vScaleBase = target
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
            .ignoresSafeArea()
    }

    private var verticalItems: [ReaderVerticalItem] {
        var items: [ReaderVerticalItem] = []
        for segment in viewModel.segments {
            for (pageIndex, page) in segment.pages.enumerated() {
                items.append(.page(chapterIndex: segment.index, pageIndex: pageIndex, page: page))
            }
            items.append(.footer(chapterIndex: segment.index))
        }
        return items
    }

    @ViewBuilder
    private func verticalItem(_ item: ReaderVerticalItem, displayWidth: CGFloat,
                              onImageSize: @escaping (CGSize) -> Void) -> some View {
        switch item {
        case .page(let chapterIndex, let pageIndex, let page):
            VerticalPageImage(
                candidates: viewModel.imageURLs(for: page),
                width: page.width,
                height: page.height,
                displayWidth: displayWidth,
                onImageLoaded: { onImageSize($0.size) }
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .id("\(chapterIndex)-\(pageIndex)")
        case .footer(let chapterIndex):
            if let segment = viewModel.segments.first(where: { $0.index == chapterIndex }) {
                chapterEndFooter(segment).frame(height: 120)
            }
        }
    }

    private func nextChapterAfter(_ index: Int) -> ChapterItem? {
        let n = index + 1
        return viewModel.chapters.indices.contains(n) ? viewModel.chapters[n] : nil
    }

    // Chapter footer shows the completed chapter and the next available chapter.
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

    /// Single-page mode uses the same page indices as the pager, including transition pages.
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
        let chapterIndex = viewModel.currentIndex
        return ReaderPageCollectionView(
            chapterIndex: chapterIndex,
            pageCount: viewModel.pages.count,
            hasPrevious: viewModel.hasPrevious,
            hasNext: nextChapter != nil,
            selectedPage: currentPage,
            isScrollEnabled: !isPagingZoomed,
            contentRevision: pageContentRevision,
            transitionProgress: viewModel.transitionImageProgress,
            onSelect: { page in
                selectPage(PagerSelection(chapterIndex: chapterIndex, page: page))
            },
            content: { page in pagerPage(page) }
        )
        .id(chapterIndex)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func pagerPage(_ page: Int) -> some View {
        if page == 0 {
            prevTriggerPage
        } else if viewModel.pages.indices.contains(page - 1) {
            horizontalPage(index: page - 1, page: viewModel.pages[page - 1])
        } else if page == viewModel.pages.count + 1 {
            endPage
        } else {
            nextTriggerPage
        }
    }

    private var readerAppearanceRevision: Int {
        var hasher = Hasher()
        hasher.combine(readerTheme)
        hasher.combine(systemColorScheme == .light)
        return hasher.finalize()
    }

    private var pageContentRevision: Int {
        var hasher = Hasher()
        hasher.combine(readerAppearanceRevision)
        hasher.combine(fitWidth)
        hasher.combine(doubleTapZoom)
        hasher.combine(scrollInertiaMultiplier)
        hasher.combine(viewModel.pages)
        hasher.combine(viewModel.chapterLikesCount)
        hasher.combine(viewModel.chapterIsLiked)
        hasher.combine(endCommentsRevealed)
        return hasher.finalize()
    }

    private func horizontalPage(index: Int, page: PageItem) -> some View {
        ReaderHorizontalPageContent(
            index: index,
            candidates: viewModel.imageURLs(for: page),
            pageWidth: page.width,
            pageHeight: page.height,
            chapterId: viewModel.currentChapter?.id,
            siteId: viewModel.siteId,
            fitWidth: fitWidth,
            doubleTapZoom: doubleTapZoom,
            inertiaMultiplier: scrollInertiaMultiplier,
            ringColor: UIColor(fg),
            onTap: handleReaderTap,
            onZoomChanged: { isPagingZoomed = $0 }
        )
        .id("\(viewModel.currentIndex)-\(index)")
    }

    /// Edge taps navigate and center taps toggle controls.
    private func handleReaderTap(_ xFraction: CGFloat) {
        if xFraction < 0.2 {
            goToPage(currentPage - 1)
        } else if xFraction > 0.8 {
            goToPage(currentPage + 1)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() }
        }
    }

    /// Animate tap-based page changes only when smooth paging is enabled.
    private func goToPage(_ target: Int) {
        let minTag = viewModel.hasPrevious ? 0 : 1
        let maxTag = viewModel.pages.count + 1 + (nextChapter != nil ? 1 : 0)
        let clamped = min(max(target, minTag), maxTag)
        guard clamped != currentPage else { return }
        let selection = PagerSelection(chapterIndex: viewModel.currentIndex, page: clamped)
        if smoothPaging {
            // Tap paging animation duration is 0.167 seconds.
            withAnimation(.easeInOut(duration: 0.167)) { selectPage(selection) }
        } else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { selectPage(selection) }
        }
    }

    private func selectPage(_ selection: PagerSelection) {
        guard selection.chapterIndex == viewModel.currentIndex,
              selection != selectedPage else { return }

        selectedPage = selection
        isPagingZoomed = false

        guard pageMode != 1, !viewModel.isLoading, !viewModel.pages.isEmpty,
              pagesAppliedForIndex == selection.chapterIndex else { return }

        if viewModel.pages.indices.contains(selection.page - 1) {
            preloadUpcoming(from: selection.page - 1)
        }

        let pageCount = viewModel.pages.count
        if selection.page == pageCount + 1, nextChapter != nil {
            let nextIndex = selection.chapterIndex + 1
            Task { await viewModel.loadTransitionPreview(for: nextIndex) }
        }
        if selection.page == pageCount + 2 {
            openNext(from: selection.chapterIndex)
        } else if selection.page == 0 {
            openPrevious(from: selection.chapterIndex)
        }
    }

    // Transition pages preload the neighboring chapter after the user reaches them.
    private var nextTriggerPage: some View {
        readerBackground
            .overlay { transitionSpinner }
    }

    private var prevTriggerPage: some View {
        readerBackground
            .overlay { transitionSpinner }
            .task { await viewModel.loadTransitionPreview(for: viewModel.currentIndex - 1) }
    }

    /// Show image preloading progress on chapter transition pages.
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

    // The chapter end page extends into comments below the first screen.
    private var endPage: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    endHeader
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }

                    if let ch = viewModel.currentChapter, !viewModel.pages.isEmpty {
                        // Load end-page comments only when their marker becomes visible.
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

    /// Chapter end header contains the next-chapter action.
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
                let sourceIndex = viewModel.currentIndex
                Button {
                    openNext(from: sourceIndex)
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

    /// Show teams credited on this chapter, not teams from another chapter.
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
                            // Without a team slug, show the name without navigation.
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

    /// Chapter appreciation and translation rating actions.
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

    private func openNext(from sourceIndex: Int) {
        guard sourceIndex == viewModel.currentIndex else { return }
        let targetIndex = sourceIndex + 1
        guard viewModel.chapters.indices.contains(targetIndex) else { return }
        pendingLandOnEnd = false
        Task { await viewModel.goTo(index: targetIndex) }
    }

    /// Opens the previous chapter at its end page.
    private func openPrevious(from sourceIndex: Int) {
        guard sourceIndex == viewModel.currentIndex else { return }
        let targetIndex = sourceIndex - 1
        guard viewModel.chapters.indices.contains(targetIndex) else { return }
        pendingLandOnEnd = true
        Task { await viewModel.goTo(index: targetIndex) }
    }

    /// Apply the initial page for each loaded chapter exactly once, including cached transitions.
    private func applyLandingIfNeeded() {
        guard !viewModel.pages.isEmpty, pagesAppliedForIndex != viewModel.currentIndex else { return }
        pagesAppliedForIndex = viewModel.currentIndex
        selectedPage = PagerSelection(
            chapterIndex: viewModel.currentIndex,
            page: pendingLandOnEnd ? viewModel.pages.count + 1 : 1
        )
        pendingLandOnEnd = false
        if pageMode != 1 { preloadUpcoming(from: currentPage - 1) }
        if pageMode != 1, currentPage == viewModel.pages.count + 1, nextChapter != nil {
            let nextIndex = viewModel.currentIndex + 1
            Task { await viewModel.loadTransitionPreview(for: nextIndex) }
        }
    }

    // MARK: Reader overlay

    private var overlayUI: some View {
        // The page indicator is rendered outside the control overlay.
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
    }

    // Keep exit and title controls in separate centered glass capsules.
    private var topBar: some View {
        ZStack {
            // Hide the title while the bookmark toast appears.
            titleBadge
                .opacity(viewModel.bookmarkToast == nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: viewModel.bookmarkToast)

            HStack {
                Button { dismiss() } label: {
                    // Use the larger exit icon size requested for the reader.
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(fg)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                // Align the exit control with the screen edge and glass capsule spacing.
                .padding(.leading, 16)
                Spacer(minLength: 0)
            }
        }
        // Raise the top control by four points.
        .padding(.top, 2)
    }

    // Measure the title capsule width from its two text lines so it stays centered without truncation.
    private static let titleBadgeSideMargin: CGFloat = 84 // 48 for the button, 16 for its inset, and 20 to keep glass elements separate.
    private var titleBadgeMaxWidth: CGFloat {
        max(120, UIScreen.main.bounds.width - Self.titleBadgeSideMargin * 2)
    }

    private static var titleBadgeTitleFont: UIFont {
        UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .semibold)
    }
    private static var titleBadgeSubtitleFont: UIFont { UIFont.preferredFont(forTextStyle: .caption2) }

    private static func textWidth(_ text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return box.width.rounded(.up)
    }

    /// Measure title capsule width from its longest text line and horizontal padding.
    private var titleBadgeWidth: CGFloat {
        let title = mangaTitle ?? viewModel.currentChapter?.name ?? "Глава"
        let subtitle = viewModel.currentChapter?.shortTitle ?? ""
        let titleWidth = Self.textWidth(title, font: Self.titleBadgeTitleFont)
        let subtitleWidth = Self.textWidth(subtitle, font: Self.titleBadgeSubtitleFont)
        let contentWidth = max(titleWidth, subtitleWidth) + 32 // Include 16 points of horizontal padding on each side.
        return min(contentWidth, titleBadgeMaxWidth)
    }

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
        .frame(width: titleBadgeWidth)
        .glassEffect(.regular, in: Capsule())
    }

    // Horizontal page numbers use real page indices; vertical numbers follow the visible cell.
    private var pageBubbleCurrent: Int { pageMode == 1 ? verticalPage : currentPage }

    // Use the current vertical segment to determine its page count.
    private var pageBubbleTotal: Int {
        if pageMode == 1 {
            return viewModel.segments.first(where: { $0.index == viewModel.currentIndex })?.pages.count ?? 0
        }
        return viewModel.pages.count
    }

    // Hide the indicator on virtual chapter-end and transition pages.
    private var pageBubble: some View {
        Text("\(pageBubbleCurrent)/\(pageBubbleTotal)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    // Keep the three controls on their separate bottom glass surfaces.
    private var bottomBar: some View {
        // Each bottom control has its own circular glass background.
        HStack {
            readerButton(icon: "line.3.horizontal") { showChapters = true }
            Spacer()
            // The comments button is available only in vertical mode.
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

    /// Bookmark button adds or removes the current title and updates its fill state.
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

// MARK: Chapter list

/// Chapter list sheet with sorting, team selection, and chapter rows.
struct ChapterListSheet: View {
    let chapters: [ChapterItem]
    let currentIndex: Int
    /// The branch ID currently selected in the reader.
    let currentBranchId: Int?
    let onSelect: (Int) -> Void
    /// Change to an already resolved translation branch, or use the default branch.
    let onSelectTranslator: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var descending = true   // Newest chapters appear first.
    /// Selected translation team filters the chapter list.
    @State private var selectedTeamId: Int?

    // Match the chapter list theme to the reader theme.
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
        // Preselect the translation team currently used by the reader.
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

    /// Show distinct translation teams in the list header when multiple are available.
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

    /// Resolve the stable branch ID belonging to a translation team.
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
        // Changing the team changes the active translation, not only the chapter filter.
        .onChange(of: selectedTeamId) { _, newValue in
            onSelectTranslator(newValue.flatMap { branchId(forTeam: $0) })
        }
    }

    // Chapter list header follows the reader settings sheet layout.
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

    /// Sorting control doubles as a team selector when multiple translations exist.
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

    // Format chapter row titles with volume and chapter numbers.
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
                // Show the selection checkmark in place of the date on the active chapter.
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

/// Reader settings: page mode, theme, image server, fit, preload, paging,
/// scroll inertia, double-tap zoom, and page number visibility.
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
    @Binding var scrollInertiaMultiplier: Double

    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showPaging = false
    @State private var inertiaInput = ""
    @FocusState private var inertiaInputFocused: Bool
    /// Keep haptic feedback prepared for the gap slider.
    private let gapHaptic = UIImpactFeedbackGenerator(style: .light)

    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    /// Size the paging settings sheet to its content.
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
                            // Use the same glass close button as the other reader sheets.
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.headline)
                                    .foregroundStyle(palette.foreground)
                                    .frame(width: 40, height: 40)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                        }
                    }

                    // Page mode setting.
                    label("Тип листания")
                    Picker("", selection: $pageMode) {
                        Text("Влево").tag(0); Text("Вверх").tag(1); Text("Вправо").tag(2)
                    }.pickerStyle(.segmented)

                    // Reader theme setting.
                    label("Тема читалки")
                    Picker("", selection: $readerTheme) {
                        Text("Светлая").tag(1); Text("Тёмная").tag(0); Text("Системная").tag(2)
                    }.pickerStyle(.segmented)

                    // Image server setting.
                    label("Сервер картинок")
                    Picker("", selection: $serverChoice) {
                        ForEach(ImageServerChoice.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)

                    // Image fitting applies only outside vertical mode.
                    if pageMode != 1 {
                        label("Вместить изображение")
                        Picker("", selection: $fitWidth) {
                            Text("По высоте").tag(false); Text("По ширине").tag(true)
                        }.pickerStyle(.segmented)
                    }

                    // Upcoming image preloading setting.
                    label("Предзагрузка страниц")
                    Picker("", selection: $preloadCount) {
                        Text("1").tag(1); Text("3").tag(3); Text("5").tag(5)
                    }.pickerStyle(.segmented)

                    // Vertical image spacing setting.
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

                    inertiaField

                    // Double-tap zoom.
                    toggleRow("Увеличить двойным нажатием", isOn: $doubleTapZoom)

                    // Page number visibility.
                    toggleRow("Скрыть номер страниц", isOn: $hidePageNumber)

                    Spacer(minLength: 0)
                }
                // Match the horizontal inset used by the other settings sections.
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
    // Use footnote typography and the standard caption spacing.
    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(palette.secondary).padding(.horizontal, 4)
    }
    // Match toggle labels to the surrounding settings typography.
    private func toggleRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).foregroundStyle(palette.foreground)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var inertiaField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Инерция прокрутки").foregroundStyle(palette.foreground)
                Spacer()
                Text("×").foregroundStyle(palette.secondary)
                TextField("8", text: $inertiaInput)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($inertiaInputFocused)
                    .onChange(of: inertiaInput) { _, value in
                        guard let multiplier = Double(value.replacingOccurrences(of: ",", with: ".")),
                              ReaderScrollInertia.allowedMultipliers.contains(multiplier) else { return }
                        scrollInertiaMultiplier = multiplier
                    }
                    .onChange(of: inertiaInputFocused) { _, focused in
                        if !focused { inertiaInput = formattedInertiaMultiplier }
                    }
            }
            caption("×1 — стандартная инерция iOS. ×1,5 — примерно на 50% больший путь после отпускания пальца при той же скорости. Диапазон: ×1–20.")
            if !inertiaInput.isEmpty && !isInertiaInputValid {
                caption("Введите число от 1 до 20.")
            }
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear { inertiaInput = formattedInertiaMultiplier }
    }

    private var formattedInertiaMultiplier: String {
        scrollInertiaMultiplier.formatted(.number.precision(.fractionLength(0...3)))
    }

    private var isInertiaInputValid: Bool {
        guard let value = Double(inertiaInput.replacingOccurrences(of: ",", with: ".")) else { return false }
        return ReaderScrollInertia.allowedMultipliers.contains(value)
    }

    /// Vertical image gap slider with haptic steps.
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

    /// Paging settings sheet.
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
            // Use the same inset as the main settings sheet.
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 20)
        }
        .presentationDetents([.height(Self.pagingSheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .tint(Theme.accent)
    }
}

// MARK: Native image zoom

/// UIKit image scroll view handles pinch, pan, and double-tap zoom while the outer page view handles unzoomed scrolling.
struct ZoomableImageScrollView: UIViewRepresentable {
    let candidates: [URL]
    let fitWidth: Bool
    let doubleTapZoom: Bool
    var doubleTapScale: CGFloat = 2.5
    /// Pass single-tap horizontal position to the reader for navigation or control toggling.
    let onTap: (CGFloat) -> Void
    /// Report zoom state so the outer vertical scroll can be disabled during image panning.
    var onZoomChanged: ((Bool) -> Void)? = nil
    /// Loading ring color follows the reader palette.
    var ringColor: UIColor = .white
    /// Keep the loading ring within the first visible screen of a tall image.
    var viewportHeight: CGFloat = 0
    /// Optional access to the decoded image view lets external readers attach overlays that zoom with the image.
    var onImageViewReady: ((UIImageView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, fitWidth: fitWidth, doubleTapZoom: doubleTapZoom, doubleTapScale: doubleTapScale, onZoomChanged: onZoomChanged, onImageViewReady: onImageViewReady) }

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
        ring.ringColor = ringColor
        scroll.addSubview(ring)

        let retryButton = UIButton(type: .system)
        retryButton.setTitle("Не удалось загрузить страницу · Повторить", for: .normal)
        retryButton.tintColor = ringColor
        retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        retryButton.isHidden = true
        retryButton.sizeToFit()
        retryButton.addTarget(context.coordinator, action: #selector(Coordinator.retryLoad), for: .touchUpInside)
        scroll.addSubview(retryButton)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        context.coordinator.ringView = ring
        context.coordinator.retryButton = retryButton
        context.coordinator.viewportHeight = viewportHeight

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
        context.coordinator.onImageViewReady = onImageViewReady
        context.coordinator.doubleTapZoom = doubleTapZoom
        context.coordinator.doubleTapScale = doubleTapScale
        context.coordinator.ringView?.ringColor = ringColor
        context.coordinator.retryButton?.tintColor = ringColor
        context.coordinator.viewportHeight = viewportHeight
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
        weak var retryButton: UIButton?
        var viewportHeight: CGFloat = 0
        var onTap: (CGFloat) -> Void
        var onZoomChanged: ((Bool) -> Void)?
        var onImageViewReady: ((UIImageView) -> Void)?
        var fitWidth: Bool
        var doubleTapZoom: Bool
        var doubleTapScale: CGFloat
        var currentKey: URL?
        private var currentCandidates: [URL] = []
        private var loadTask: Task<Void, Never>?
        private var lastBounds: CGSize = .zero
        private var lastReportedZoomed = false

        init(onTap: @escaping (CGFloat) -> Void, fitWidth: Bool, doubleTapZoom: Bool, doubleTapScale: CGFloat, onZoomChanged: ((Bool) -> Void)? = nil, onImageViewReady: ((UIImageView) -> Void)? = nil) {
            self.onTap = onTap
            self.fitWidth = fitWidth
            self.doubleTapZoom = doubleTapZoom
            self.doubleTapScale = doubleTapScale
            self.onZoomChanged = onZoomChanged
            self.onImageViewReady = onImageViewReady
        }

        func load(candidates: [URL]) {
            currentCandidates = candidates
            currentKey = candidates.first
            loadTask?.cancel()
            retryButton?.isHidden = true
            if let key = currentKey, let cached = RemoteImageCache.shared.image(for: key) {
                ringView?.isHidden = true
                imageView?.image = cached
                layoutImage(resetZoom: true)
                return
            }
            imageView?.image = nil
            ringView?.progress = 0
            ringView?.isHidden = false
            let key = currentKey
            loadTask = Task { [weak self] in
                // Give visible image requests high network priority.
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
                    self.retryButton?.isHidden = img != nil
                    self.layoutImage(resetZoom: true)
                }
            }
        }

        @objc func retryLoad() { load(candidates: currentCandidates) }

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
            guard doubleTapZoom else { return } // Double-tap zoom is disabled.
            guard let scroll = scrollView, let imageView, imageView.image != nil else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = g.location(in: imageView)
                let newScale = min(doubleTapScale, scroll.maximumZoomScale)
                let w = scroll.bounds.width / newScale
                let h = scroll.bounds.height / newScale
                scroll.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
            }
        }

        func boundsChanged() {
            guard let scroll = scrollView, scroll.bounds.size != lastBounds else { return }
            lastBounds = scroll.bounds.size
            // Do not relayout an image during zoom.
            layoutImage(resetZoom: scroll.zoomScale <= scroll.minimumZoomScale + 0.01)
        }

        /// Fit and center the decoded image by width or height.
        func layoutImage(resetZoom: Bool) {
            guard let scroll = scrollView, let imageView, let image = imageView.image else {
                // Center the loading ring when no image is available.
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
            onImageViewReady?(imageView)
        }

        private func centerImage() {
            guard let scroll = scrollView, let imageView else { return }
            let bounds = scroll.bounds.size
            let content = imageView.frame.size
            let insetX = max((bounds.width - content.width) / 2, 0)
            let insetY = max((bounds.height - content.height) / 2, 0)
            scroll.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        /// Position the loading ring within the visible viewport of a tall page.
        private func centerRing() {
            guard let scroll = scrollView, let ringView else { return }
            let refHeight = viewportHeight > 0 ? min(scroll.bounds.height, viewportHeight) : scroll.bounds.height
            ringView.center = CGPoint(x: scroll.bounds.midX, y: refHeight / 2)
            retryButton?.center = ringView.center
        }
    }
}

/// Scroll view subclass reports layout changes to the image coordinator.
final class LayoutCallbackScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Circular indicator reflects real image download progress.
final class RingProgressView: UIView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    /// Keep a visible minimum progress arc before bytes arrive.
    var progress: CGFloat = 0 {
        didSet { progressLayer.strokeEnd = max(0.02, min(1, progress)) }
    }

    /// Tint the progress ring for the active reader theme.
    var ringColor: UIColor = .white {
        didSet {
            trackLayer.strokeColor = ringColor.withAlphaComponent(0.25).cgColor
            progressLayer.strokeColor = ringColor.cgColor
        }
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

/// Vertical reader image uses shared caching and aspect-ratio placeholders.
struct VerticalPageImage: View {
    let candidates: [URL]
    /// Server pixel dimensions reserve the correct height before a long page loads.
    let width: Int?
    let height: Int?
    var displayWidth: CGFloat? = nil
    /// Optional callback exposes the decoded image for external OCR readers.
    var onImageLoaded: ((UIImage) -> Void)? = nil
    @State private var image: UIImage?
    /// Download progress drives the image loading ring.
    @State private var progress: Double = 0
    @State private var failed = false
    @State private var retryAttempt = 0

    // Use the current reader theme for image loading progress.
    @AppStorage("reader_theme") private var readerTheme = 0
    @Environment(\.colorScheme) private var systemColorScheme
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    /// Estimate placeholder height from server dimensions to prevent jumps during image loading.
    private var placeholderHeight: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 480 }
        return (displayWidth ?? UIScreen.main.bounds.width) * CGFloat(height) / CGFloat(width)
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
                    .overlay {
                        if failed {
                            Button("Не удалось загрузить страницу · Повторить") { retryAttempt += 1 }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(palette.foreground)
                        } else {
                            pageProgressRing
                        }
                    }
            }
        }
        .task(id: "\(candidates.first?.absoluteString ?? "")-\(retryAttempt)") {
            progress = 0
            failed = false
            image = candidates.lazy.compactMap { RemoteImageCache.shared.image(for: $0) }.first
            if let image {
                onImageLoaded?(image)
                return
            }
            // Fetch visible images with high network priority.
            let loadedImage = await RemoteImageLoader.fetchImage(candidates: candidates, priority: URLSessionTask.highPriority) { p in
                Task { @MainActor in progress = p }
            }
            guard !Task.isCancelled else { return }
            image = loadedImage
            if let image { onImageLoaded?(image) }
            else { failed = true }
        }
    }

    /// Show real download progress with a palette-aware ring.
    private var pageProgressRing: some View {
        let fg = palette.foreground
        return ZStack {
            Circle().stroke(fg.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(fg, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
        .animation(.linear(duration: 0.15), value: progress)
    }
}

/// Bookmark toast displayed in the reader overlay.
struct BookmarkAddedToast: View {
    var text: String = "Добавлено в закладки"
    var systemImage: String = "bookmark.fill"

    var body: some View {
        // Match the bookmark toast capsule to the download toast style.
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
