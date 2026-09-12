import SwiftUI
import UIKit

/// The result query — tag/series/... (see ExternalTagBrowserView) OR a free
/// text search (see ExternalSearchView/ExternalCombinedCatalogView,
/// capabilities.hasSearch) — the same grid screen serves both
/// cases, the only difference is which protocol method gets called for
/// the next page of IDs (see fetchPage).
enum ExternalCatalogQuery {
    case tag(namespace: ExternalTagNamespace, value: String)
    /// `excludedCategoryBits` — see EHentaiCategory/EHentaiCategoryPicker;
    /// sites without capabilities.hasCategoryFilter simply ignore it (see
    /// ExternalSiteProvider.fetchIdsBySearch(excludedCategoryBits:)
    /// default implementation), so this is one shared case rather than a
    /// separate one per site. 0 means no restriction (enum cases don't
    /// support default parameter values, so the caller always passes it
    /// explicitly).
    case search(query: String, excludedCategoryBits: Int)
}

/// One item of the COMBINED result set (see ExternalCombinedCatalogView) —
/// a gallery ID alone isn't unique across sites (hitomi and e-hentai each
/// have their own unrelated integer spaces), so a grid item's identity is
/// ALWAYS the pair (site, id), never a bare Int.
struct ExternalCatalogItem: Identifiable, Hashable {
    let site: ExternalSite
    let galleryId: Int
    var id: String { "\(site.rawValue)#\(galleryId)" }
}

/// Passed to ExternalCatalogGridView.onResultsCount after every loaded
/// page — see its doc-comment.
struct ExternalCatalogItemsSummary {
    /// Items on the CURRENT page (after the pageSize cap, see loadNextBatch).
    let count: Int
    let hasMore: Bool
    /// Approximate total matches across every enabled site — a REAL
    /// number where a site states one (e-hentai, see
    /// ExternalSiteProvider.lastKnownEstimatedTotal), else a lower-bound
    /// guess from page-count math (see
    /// ExternalCatalogGridView.estimatedTotalCount).
    let estimatedTotal: Int
    /// True only when EVERY enabled site contributed a real total — the
    /// common case is a single e-hentai query. False the moment even one
    /// site had to fall back to the page-count guess (label it "≈"/"not
    /// less than" rather than presenting it as exact).
    let isEstimateExact: Bool
}

/// Grid of titles from an external site (or SEVERAL at once — see `sites`
/// and ExternalCombinedCatalogView) for a single tag/series/character/group/
/// artist, or a free-text query (see the plan, Part 6 + the combined catalog).
/// The ID list is paginated (see fetchPage), cards load lazily as the user
/// scrolls via fetchGalleryDetail — the same "load more on the last items'
/// onAppear" principle as the old MangaCatalogView, but written fresh,
/// independently (see the plan — keep overlap with the old code to a
/// minimum).
struct ExternalCatalogGridView: View {
    let sites: [ExternalSite]
    /// The query is a FUNCTION of the site, not one shared value. Per
    /// direct feedback (Aug 31): in a combined result set ("All sites")
    /// each site must have its OWN independent query — a tag/search typed
    /// for imhentai in "Filters" must not leak into the e-hentai/hitomi/
    /// 3hentai query, and vice versa (see ExternalCombinedCatalogView.query(for:)).
    /// The plain single-site call (ExternalTagBrowserView/
    /// ExternalSearchView) simply ignores the site parameter — there it's
    /// always the same one anyway.
    let queryForSite: (ExternalSite) -> ExternalCatalogQuery
    let title: String
    /// true — embedded DIRECTLY into the search screen (see ExternalSearchView/
    /// ExternalCombinedCatalogView, per direct feedback "titles should appear
    /// right there", without a separate navigation) — no title/background of
    /// its own, the parent screen already provides them. false (default) —
    /// as before, a standalone screen you navigate to (see ExternalTagBrowserView).
    var embedded: Bool = false

    /// Extra button(s) from the parent screen shown in the shared bottom
    /// glass panel (see controlsBar) — currently this is "Filters" on
    /// ExternalSearchView/ExternalCombinedCatalogView (the e-hentai category
    /// capsule). `AnyView`, not a generic parameter on the whole struct — the
    /// type of that view must not leak into every call site that creates
    /// ExternalCatalogGridView (that would mean generic plumbing everywhere
    /// just for one optional button).
    var leadingControls: AnyView?

    /// Plain (non-combined) call — a single site, the most common case
    /// (ExternalTagBrowserView/ExternalSearchView). Here `query` really is
    /// one value for the whole call — we wrap it in a constant function.
    init(site: ExternalSite, query: ExternalCatalogQuery, title: String, embedded: Bool = false, leadingControls: AnyView? = nil) {
        self.sites = [site]
        self.queryForSite = { _ in query }
        self.title = title
        self.embedded = embedded
        self.leadingControls = leadingControls
    }

    /// Combined result set — SEVERAL sites at once (see
    /// ExternalCombinedCatalogView) — each page is merged across all
    /// given sites together (see loadNextBatch), but each site has its
    /// OWN query (see the queryForSite doc-comment).
    init(sites: [ExternalSite], queryForSite: @escaping (ExternalSite) -> ExternalCatalogQuery, title: String, embedded: Bool = false, leadingControls: AnyView? = nil) {
        self.sites = sites
        self.queryForSite = queryForSite
        self.title = title
        self.embedded = embedded
        self.leadingControls = leadingControls
    }

    /// Fluent setter for onResultsCount (see its doc-comment) — kept out of
    /// both initializers above since it's an optional hook only
    /// ExternalSearchView's "Found X titles" banner needs; every other call
    /// site (ExternalTagBrowserView, ExternalCombinedCatalogView, ...) just
    /// leaves it at its `nil` default.
    func onResultsCount(_ handler: @escaping (ExternalCatalogItemsSummary) -> Void) -> Self {
        var copy = self
        copy.onResultsCount = handler
        return copy
    }

    /// Фиксированное локальное кол-во тайтлов на "страницу" — по прямому
    /// запросу ("фикс. кол-во тайтлов"). ЧЕСТНО работает как настоящий
    /// лимит только там, где сайт реально это позволяет (hitomi — точный
    /// byte-offset в .nozomi, см. HitomiProvider.fetchNozomiList) — все
    /// остальные провайдеры (e-hentai/imhentai/3hentai/hentaiPill/
    /// simplyHentai) СКРЕЙПЯТ обычную HTML-страницу листинга и физически не
    /// могут запросить у сайта "ровно 40" — они честно игнорируют `limit` и
    /// отдают столько, сколько сайт сам показывает на своей странице (см.
    /// комментарии `limit` в каждом провайдере) — конкретное число там
    /// задаёт сам сайт, не мы.
    private static let pageSize = 45

    @State private var items: [ExternalCatalogItem] = []
    /// Next-page cursor PER SITE — a missing key means "not yet queried",
    /// a nil cursor is used for the first request (see fetchPage).
    @State private var cursors: [ExternalSite: String] = [:]
    /// Sites that MAY still have a next page — as soon as a site returns
    /// nextCursor == nil (or fails with an error) it's removed from here,
    /// so we don't keep hammering it with repeated loads.
    @State private var pending: Set<ExternalSite> = []
    @State private var details: [String: ExternalGalleryDetail] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var jumpPageText = ""
    /// Текущая страница (1-based) — по прямому запросу ("когда долистал —
    /// кнопка к странице X или назад") результат теперь листается ЯВНО
    /// постранично (см. pageFooter/goToPage), а не бесконечным
    /// автодогружением при подскролле к концу, как было раньше.
    @State private var currentPage = 1
    /// Показать после того, как страница уже загружена: как минимум один
    /// сайт из `sites` ЕЩЁ имеет следующую страницу (см. loadNextBatch —
    /// сайт остаётся в `pending`, пока не вернёт nextCursor == nil или не
    /// ошибётся) — единственный источник правды о "есть ли ещё", без
    /// придуманного общего количества страниц (ни один провайдер не
    /// возвращает суммарный total, см. ExternalSiteProvider.fetchIdsByTag/
    /// fetchIdsBySearch — только (ids, nextCursor)).
    private var hasNextPage: Bool { !pending.isEmpty }
    /// Обратная навигация работает для ЛЮБОЙ страницы, где currentPage > 1,
    /// НЕЗАВИСИМО от hasNextPage — переход всегда идёт заново через
    /// cursorForPage (см. goToPage), а не кэш уже просмотренных страниц.
    private var hasPreviousPage: Bool { currentPage > 1 }
    /// Reports this page's result count upward (see ExternalSearchView/
    /// ExternalCombinedCatalogView — the "Found ~N titles" banner shown
    /// after pressing Return in search). Called once per loaded page, with
    /// a summary that's exact ONLY when every enabled site contributed a
    /// real site-reported total (see ExternalCatalogItemsSummary.isEstimateExact).
    var onResultsCount: ((ExternalCatalogItemsSummary) -> Void)? = nil
    /// OPAQUE sort key (see ExternalSiteProvider.
    /// fetchIdsByTag(sortKey:), HitomiProvider.SortOption.rawValue) — nil =
    /// default sort order (by date added). Only for sites with
    /// capabilities.hasSortOptions (currently only hitomi, see showsSortMenu).
    @State private var sortKey: String?

    /// Column count — the same shared Personalization setting (2/3/4/Auto)
    /// as the regular catalog (see MangaCatalogView/MangaCardView,
    /// CardsPerRow.swift) — same shared type, same @AppStorage key, per
    /// direct feedback "mirror how the personalization function works".
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto
    private var gridColumns: Int { cardsPerRow.columns }

    private let gridSpacing: CGFloat = 12
    /// The source badge only makes sense to show when there are MULTIPLE
    /// sites — in the plain single-site mode it's already obvious where a
    /// title is from (see ExternalTagBrowserView/ExternalSearchView, where
    /// sites is [x]).
    private var showsSourceBadge: Bool { sites.count > 1 }
    /// "Jump to page" (see ExternalSiteCapabilities.hasPageJump) — at
    /// least one of `sites` must support this, otherwise the row wouldn't
    /// do anything (see jump(toPage:) — sites without support are simply
    /// skipped there and start over from page one). Per direct feedback —
    /// always shown AT THE TOP, as a visible row, not tucked behind a
    /// button/alert.
    private var showsPageJump: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasPageJump } }
    /// Sorting (see ExternalSiteCapabilities.hasSortOptions) — currently
    /// confirmed by a live HAR capture only for hitomi (see HitomiProvider.
    /// SortOption); the button is shown if AT LEAST ONE of `sites` supports
    /// it — for e-hentai in a combined result set sortKey is simply and
    /// honestly ignored (see the ExternalSiteProvider extension default).
    private var showsSortMenu: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasSortOptions } }
    private var showsControlsBar: Bool { showsPageJump || showsSortMenu || leadingControls != nil }

    @FocusState private var isJumpFieldFocused: Bool

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .background(Theme.background.ignoresSafeArea())
            }
        }
        .task { await loadFirstPage() }
        .onChange(of: sortKey) { _, _ in resetAndReload() }
        // Bottom panel with glass pills — a 1-to-1 match for MangaCatalogView.
        // controlsBar/controlLabel (per direct feedback on Aug 30: "put the
        // filters button at the bottom... make the quick page-jump button a
        // glass button at the bottom too"), rather than regular chips up top
        // like it was before.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsControlsBar {
                controlsBar
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
        }
    }

    /// Sort order changed — restart the result set from page one (the same
    /// reset as jump(toPage:), just without synthesizing a page cursor).
    private func resetAndReload() {
        items = []
        details = [:]
        cursors = [:]
        currentPage = 1
        Task { await performInitialLoad() }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            leadingControls
            if showsPageJump {
                pageJumpButton
            }
            if showsSortMenu {
                sortMenuButton
            }
            Spacer(minLength: 0)
        }
    }

    /// The same glass-pill style as MangaCatalogView.controlLabel
    /// (Filters/Sort at the bottom of the regular catalog) — reused by
    /// both the parent screen's "Filters" (see leadingControls) and by
    /// "Pg."/"Sort" here: a single consistent look for every button in the
    /// bottom panel.
    private func controlPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// "Pg." — a pill that opens a bottom sheet with a text field + arrow
    /// (see jumpFieldSheet) instead of an inline row, so the input field
    /// doesn't stick out right in the bottom panel next to the other
    /// buttons. Tapping the pill opens the sheet; the keyboard is dismissed
    /// via a "Done" button in the sheet's own toolbar(.keyboard) (see
    /// jumpFieldSheet) — per direct feedback "make sure the keyboard can be
    /// dismissed".
    @State private var showJumpSheet = false

    /// Shows the CURRENT page number right on the pill ("Стр. N") instead
    /// of a bare "Стр." — per direct request to fix the page-jump visual:
    /// otherwise there was no way to tell what page you were even on
    /// without opening the sheet first.
    private var pageJumpButton: some View {
        Button {
            jumpPageText = ""
            showJumpSheet = true
        } label: {
            controlPill(icon: "arrow.right.to.line", text: "Стр. \(currentPage)")
        }
        .sheet(isPresented: $showJumpSheet) {
            jumpFieldSheet
        }
    }

    private var jumpFieldSheet: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Перейти на страницу")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Сейчас: страница \(currentPage)")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                TextField("№", text: $jumpPageText, prompt: Text("\(currentPage)").foregroundColor(Theme.textSecondary))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .focused($isJumpFieldFocused)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(width: 72, height: 44)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    if let page = Int(jumpPageText), page > 0 {
                        jump(toPage: page)
                        showJumpSheet = false
                    }
                } label: {
                    Text("Перейти")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(Int(jumpPageText) == nil || Int(jumpPageText) == currentPage)
            }
        }
        .padding(20)
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.visible)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { isJumpFieldFocused = true }
        // The (numberPad) keyboard doesn't provide a "Done" button on its
        // own — per direct feedback "make sure the keyboard can be
        // dismissed". The toolbar is attached HERE, on the sheet's own
        // content (not on ExternalCatalogGridView's outer body) — a
        // .sheet has its own independent hierarchy, an outer
        // toolbar(.keyboard) wouldn't show above its keyboard.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { isJumpFieldFocused = false }
            }
        }
    }

    /// Sort key — `String?` (nil = default), not the enum itself, since
    /// this is a SHARED field for any site (see the sortKey doc-comment
    /// above); the Picker inside works with HitomiProvider.SortOption via
    /// Binding(get:set:) — the only implementation today, see showsSortMenu.
    private var sortSelection: Binding<HitomiProvider.SortOption> {
        Binding(
            get: { sortKey.flatMap(HitomiProvider.SortOption.init(rawValue:)) ?? .dateAdded },
            set: { newValue in sortKey = newValue == .dateAdded ? nil : newValue.rawValue }
        )
    }

    private var sortMenuButton: some View {
        Menu {
            Picker("Сортировка", selection: sortSelection) {
                ForEach(HitomiProvider.SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            controlPill(icon: "arrow.up.arrow.down", text: sortSelection.wrappedValue.label)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            // Skeleton grid instead of a bare spinner — a 1-to-1 match for
            // MangaCatalogView.skeletonGrid (per direct feedback "skeletons
            // in the catalog section"), the same card width as the real
            // grid below (see grid below).
            skeletonGrid
        } else if let errorMessage, items.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await loadFirstPage() } }, fillScreen: true)
        } else if items.isEmpty {
            StateView(icon: "square.grid.2x2", title: "Тайтлов не найдено", fillScreen: true)
        } else {
            grid
        }
    }

    /// The number of placeholder cells isn't tied to real data (there is
    /// none yet) — just enough to fill the screen for any gridColumns
    /// value (2/3/4).
    private var skeletonGrid: some View {
        GeometryReader { proxy in
            let spacing = gridSpacing
            let totalSpacing = spacing * CGFloat(gridColumns - 1) + 24
            let cardWidth = ((proxy.size.width - totalSpacing) / CGFloat(gridColumns)).rounded(.down)
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: gridColumns)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(0..<12, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBox()
                                .frame(width: cardWidth, height: (cardWidth * 3 / 2).rounded())
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            SkeletonBar(width: cardWidth * 0.85, height: 12)
                            SkeletonBar(width: cardWidth * 0.5, height: 10)
                        }
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let spacing = gridSpacing
            let totalSpacing = spacing * CGFloat(gridColumns - 1) + 24
            let cardWidth = ((proxy.size.width - totalSpacing) / CGFloat(gridColumns)).rounded(.down)
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: gridColumns)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink {
                            ExternalGalleryDetailView(site: item.site, id: item.galleryId, preloaded: details[item.id])
                        } label: {
                            card(item: item, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .onAppear { onCardAppear(item) }
                    }
                }
                .padding(12)

                pageFooter
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Shown once you've scrolled down to the end of the current page —
    /// a "Back"/"To page X" pair instead of silently auto-loading more, per
    /// direct request. A spinner takes their place while performInitialLoad
    /// is fetching the page you just navigated to (isLoading stays true for
    /// that whole request, see jump(toPage:)/performInitialLoad).
    @ViewBuilder
    private var pageFooter: some View {
        if isLoading {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if hasPreviousPage || hasNextPage {
            HStack(spacing: 10) {
                if hasPreviousPage {
                    Button { goToPreviousPage() } label: {
                        Label("Назад", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
                }
                if hasNextPage {
                    Button { goToNextPage() } label: {
                        HStack(spacing: 6) {
                            Text("К странице \(currentPage + 1)")
                            Image(systemName: "chevron.right")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
    }

    // MARK: Text under the cover — sizes/fonts are a 1-to-1 match for
    // MangaCardView (titleFont/typeFont/textBlockHeight), see
    // card(item:width:) below.
    // DIFFERENCE from MangaCardView: that one computes block height PER ROW
    // (every card in the row is already visible at once, since
    // viewModel.results is already fully loaded) — here grid titles load
    // LAZILY, per card (onCardAppear → loadDetail), so at layout time
    // neighbors in the same row MAY still have no loaded detail at all —
    // an exact per-row height calculation would require knowing the final
    // titles UP FRONT. Instead EACH card reserves the MAXIMUM on its own
    // (2 lines of title + a type line, even when there's no type or the
    // detail is still loading) — same end result (the grid doesn't "shift",
    // per the complaint "it jumps around because some titles are
    // title-title-type and others are title-type", Aug 31), just without
    // the per-row space savings on rows with short titles.
    fileprivate static let textScale: CGFloat = 1.2
    fileprivate static var titleUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        return UIFont.systemFont(ofSize: base.pointSize * textScale, weight: .medium)
    }
    fileprivate static var typeUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption2)
        return UIFont.systemFont(ofSize: base.pointSize * textScale, weight: .regular)
    }
    fileprivate static var titleTypeSpacing: CGFloat { titleUIFont.leading }
    fileprivate static var textBlockHeight: CGFloat {
        (titleUIFont.lineHeight * 2 + titleTypeSpacing + typeUIFont.lineHeight).rounded(.up)
    }

    private func card(item: ExternalCatalogItem, width: CGFloat) -> some View {
        CatalogCard(item: item, detail: details[item.id], width: width, showsSourceBadge: showsSourceBadge)
    }

    /// Only loads the per-card detail (title/cover/pages) needed to render
    /// this specific cell. Used to also trigger auto-loading the next batch
    /// once you scrolled near the end (infinite scroll) — replaced by
    /// explicit Prev/Next buttons in pageFooter, per direct request ("when
    /// you've scrolled to the end there should be a 'to page X' button or
    /// a 'back' button", instead of silently loading more).
    private func onCardAppear(_ item: ExternalCatalogItem) {
        if details[item.id] == nil {
            Task { await loadDetail(item) }
        }
    }

    private func loadDetail(_ item: ExternalCatalogItem) async {
        let provider = ExternalSiteRegistry.provider(for: item.site)
        guard let detail = try? await provider.fetchGalleryDetail(id: item.galleryId) else { return }
        details[item.id] = detail
    }

    /// The same method for any site — no per-site "doesn't support this"
    /// exception: a site without hasSearch (e.g. hitomi) treats a `.search`
    /// query's text simply AS A TAG (fetchIdsByTag — that's exactly how
    /// hitomi searches by name: an unknown tag name just returns an empty
    /// list/404, which is a normal response, not an error, see
    /// HitomiProvider.fetchIdsByTag). `static`, without capturing `self` —
    /// called from parallel tasks in loadNextBatch (see below), no reason
    /// to needlessly capture the whole View struct in a @Sendable closure.
    private static func fetchPage(site: ExternalSite, cursor: String?, query: ExternalCatalogQuery, sortKey: String?) async throws -> (ids: [Int], nextCursor: String?) {
        let provider = ExternalSiteRegistry.provider(for: site)
        switch query {
        case let .tag(namespace, value):
            return try await provider.fetchIdsByTag(namespace: namespace, value: value, sortKey: sortKey, cursor: cursor, limit: pageSize)
        case let .search(text, excludedCategoryBits):
            if provider.capabilities.hasSearch {
                return try await provider.fetchIdsBySearch(query: text, excludedCategoryBits: excludedCategoryBits, sortKey: sortKey, cursor: cursor, limit: pageSize)
            } else {
                return try await provider.fetchIdsByTag(namespace: .tag, value: text, sortKey: sortKey, cursor: cursor, limit: pageSize)
            }
        }
    }

    private func loadFirstPage() async {
        guard items.isEmpty else { return }
        cursors = [:]
        await performInitialLoad()
    }

    /// Resets the result set and restarts it from a cursor that each
    /// provider (see cursorForPage) synthesizes itself for "page N" — for
    /// sites without capabilities.hasPageJump the cursor is simply not
    /// set, they honestly start over from page one (not a bug, see
    /// showsPageJump — the button is shown if AT LEAST one site supports it).
    /// Also updates `currentPage`, which drives pageFooter/pageJumpButton —
    /// the single source of truth for "what page am I looking at", whether
    /// you got here via Next/Back (see goToNextPage/goToPreviousPage) or an
    /// arbitrary jump (see jumpFieldSheet).
    private func jump(toPage page: Int) {
        guard page >= 1 else { return }
        items = []
        details = [:]
        cursors = sites.reduce(into: [ExternalSite: String]()) { result, site in
            if let cursor = ExternalSiteRegistry.provider(for: site).cursorForPage(page, limit: Self.pageSize) {
                result[site] = cursor
            }
        }
        currentPage = page
        Task { await performInitialLoad() }
    }

    private func goToNextPage() {
        guard hasNextPage else { return }
        jump(toPage: currentPage + 1)
    }

    private func goToPreviousPage() {
        guard hasPreviousPage else { return }
        jump(toPage: currentPage - 1)
    }

    private func performInitialLoad() async {
        isLoading = true
        errorMessage = nil
        pending = Set(sites)
        // `anySucceeded` — distinguishes a REAL network failure (no site
        // responded successfully) from an honest "0 matches" (the request
        // succeeded, it's just empty — e.g. searching hitomi for an exact
        // tag name that doesn't exist). This used to only check
        // `items.isEmpty && pending.isEmpty` — that condition is EQUALLY
        // true in both cases (a successful empty response also removes the
        // site from `pending`, see loadNextBatch), which meant any empty
        // hitomi search immediately showed "Check your connection and try
        // again" — it looks like a network error nudging you to hit
        // "Refresh", even though the network worked fine and there just
        // were no matches (per the complaint "the fallback suggests
        // hitting refresh too eagerly").
        let anySucceeded = await loadNextBatch()
        if items.isEmpty && pending.isEmpty && !anySucceeded {
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
        isLoading = false
        // Reports this page's result count upward (see onResultsCount doc-
        // comment) — always, even on an error/empty page, so a caller like
        // ExternalSearchView can show an honest "Found 0 titles" instead of
        // silently leaving a stale count from a previous search on screen.
        if let onResultsCount {
            let (total, isExact) = await estimatedTotalCount()
            onResultsCount(ExternalCatalogItemsSummary(count: items.count, hasMore: hasNextPage, estimatedTotal: total, isEstimateExact: isExact))
        }
    }

    /// See ExternalCatalogItemsSummary.estimatedTotal/isEstimateExact.
    private func estimatedTotalCount() async -> (total: Int, isExact: Bool) {
        var total = 0
        var allExact = true
        for site in sites {
            let provider = ExternalSiteRegistry.provider(for: site)
            if let exact = await provider.lastKnownEstimatedTotal() {
                total += exact
            } else {
                allExact = false
                // Lower bound: full pages already paged through (this
                // site's own typical native page size, see
                // ExternalSiteCapabilities.typicalPageSize) plus whatever
                // it actually contributed to the CURRENT page — "at least
                // this many", never an invented exact figure.
                let seenThisPage = items.filter { $0.site == site }.count
                let priorPages = max(0, currentPage - 1)
                total += priorPages * provider.capabilities.typicalPageSize + seenThisPage
            }
        }
        return (total, allExact)
    }

    /// Queries all sites in `pending` IN PARALLEL (the first page is just
    /// "all sites from `sites`" at the start), merges the result by
    /// INTERLEAVING across sites (not "all of one site first, then all of
    /// the other" — otherwise a combined grid would look like two separate
    /// grids stitched together instead of one unified result). Returns
    /// whether at least one site responded SUCCESSFULLY (even with an
    /// empty list) — see performInitialLoad, where this distinguishes a
    /// real network failure from an honest "0 matches". `@discardableResult`
    /// — loadMoreIfNeeded doesn't need this flag (there's nothing left to
    /// report about an error there, the screen is already showing
    /// something).
    @discardableResult
    private func loadNextBatch() async -> Bool {
        let sitesToQuery = Array(pending)
        guard !sitesToQuery.isEmpty else { return true }
        // A snapshot PER SITE up front (before withTaskGroup) — the same
        // approach that currentQuery used before, just now with a
        // per-site value from the function (see the queryForSite
        // doc-comment).
        let queriesBySite = Dictionary(uniqueKeysWithValues: sitesToQuery.map { ($0, queryForSite($0)) })
        let currentSortKey = sortKey
        let cursorsSnapshot = cursors

        let results = await withTaskGroup(of: (ExternalSite, [Int], String?, Bool).self) { group in
            for site in sitesToQuery {
                let cursor = cursorsSnapshot[site]
                let siteQuery = queriesBySite[site] ?? .search(query: "", excludedCategoryBits: 0)
                group.addTask {
                    do {
                        let page = try await Self.fetchPage(site: site, cursor: cursor, query: siteQuery, sortKey: currentSortKey)
                        return (site, page.ids, page.nextCursor, true)
                    } catch {
                        return (site, [], nil, false)
                    }
                }
            }
            var collected: [(ExternalSite, [Int], String?, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var idsBySite: [ExternalSite: [Int]] = [:]
        var anySucceeded = false
        for (site, ids, nextCursor, succeeded) in results {
            if succeeded { anySucceeded = true }
            if succeeded, let nextCursor {
                cursors[site] = nextCursor
            } else {
                // Either the site honestly said "nothing more", or the
                // request failed — either way we don't query this site
                // again, but whatever it ALREADY returned in this batch
                // (if succeeded) still makes it into the result set.
                pending.remove(site)
            }
            idsBySite[site] = ids
        }

        let maxCount = idsBySite.values.map(\.count).max() ?? 0
        var merged: [ExternalCatalogItem] = []
        for index in 0..<maxCount {
            for site in sites {
                guard let ids = idsBySite[site], index < ids.count else { continue }
                merged.append(ExternalCatalogItem(site: site, galleryId: ids[index]))
            }
        }

        let existing = Set(items.map(\.id))
        let newItems = merged.filter { !existing.contains($0.id) }
        // Capped to pageSize TOTAL, not per site — in the combined "All
        // sites" catalog (see ExternalCombinedCatalogView) a single batch
        // is one native listing page from EACH enabled site at once, which
        // could otherwise add up to several hundred titles in "page 1" and
        // still feel like unbounded infinite scroll despite the pageSize
        // constant. The trade-off (spelled out here rather than silently):
        // for scraped sites that ignore `limit` (see the pageSize doc-
        // comment) whatever doesn't fit on this page is simply DROPPED,
        // not carried over to page 2 — Next always jumps to that site's own
        // next native page (via cursorForPage), never "the rest of this
        // one". Only genuinely lossless for hitomi, whose single-site batch
        // never exceeds pageSize in the first place (real limit).
        let capacity = max(0, Self.pageSize - items.count)
        items.append(contentsOf: newItems.prefix(capacity))
        return anySucceeded
    }
}

/// A single grid card — pulled out into its own View struct (rather than
/// just a function, as before), because it now needs its OWN state: whether
/// the title ended up truncated at 2 lines (see updateTruncation) and
/// whether the full-title sheet is open (per direct feedback on Sep 1 —
/// "add the ability to open a sheet with the full title if it doesn't fit
/// on the title's card"). A helper function (as it was) can't have @State —
/// that binds to a View instance, not to a function call inside someone
/// else's body.
private struct CatalogCard: View {
    let item: ExternalCatalogItem
    let detail: ExternalGalleryDetail?
    let width: CGFloat
    let showsSourceBadge: Bool

    @State private var isTitleTruncated = false
    @State private var showFullTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            titleBlock
        }
        .frame(width: width, alignment: .top)
    }

    private var cover: some View {
        Group {
            if let cover = detail?.coverURL {
                ExternalImage(url: cover) { SkeletonBox() }
                    .scaledToFill()
            } else {
                SkeletonBox()
            }
        }
        .frame(width: width, height: (width * 3 / 2).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipped()
        .overlay(alignment: .topLeading) {
            if showsSourceBadge {
                Text(item.site.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
        }
        // Page count — as a chip at the bottom right of the cover (per
        // direct feedback on Sep 1 — "everywhere, show the page count
        // right away as a separate chip at the bottom right of the
        // cover"), the same visual style as the source badge
        // (showsSourceBadge) above, just a different corner. Appears only
        // once the title's detail is ALREADY loaded (see onCardAppear →
        // loadDetail) — pages are only known from there, before that we
        // honestly show nothing (we don't make up a number).
        .overlay(alignment: .bottomTrailing) {
            if let count = detail?.pages.count, count > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "square.stack.fill").font(.system(size: 8, weight: .semibold))
                    Text("\(count)").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
        }
    }

    // Title + type — the same approach as in the regular catalog
    // (MangaCardView: title, immediately under it the type in a secondary
    // color), the type stays IN ENGLISH, exactly as the site itself gives
    // it (hitomi returns "manga"/"doujinshi"/"misc"/... lowercase,
    // e-hentai — "Manga"/... capitalized) — we don't translate it or
    // change its casing.
    // While the detail hasn't loaded yet — a SkeletonBar (the same shimmer
    // animation as the cover/skeletonGrid above), NOT "…" (per the
    // complaint "the skeleton is literally just three dots", Aug 31).
    private var titleBlock: some View {
        Group {
            if let detail {
                VStack(alignment: .leading, spacing: ExternalCatalogGridView.titleTypeSpacing) {
                    Button {
                        guard isTitleTruncated else { return }
                        showFullTitle = true
                    } label: {
                        Text(detail.title)
                            .font(Font(ExternalCatalogGridView.titleUIFont))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(width: width, alignment: .topLeading)
                            .background(titleMeasurement(detail.title))
                    }
                    .buttonStyle(.plain)
                    // The tap only works when the title ACTUALLY didn't
                    // fit — otherwise the card would look tappable in
                    // places where there's nothing to open.
                    .disabled(!isTitleTruncated)

                    Text(detail.type.isEmpty ? " " : detail.type)
                        .font(Font(ExternalCatalogGridView.typeUIFont))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                        .opacity(detail.type.isEmpty ? 0 : 1)
                }
            } else {
                VStack(alignment: .leading, spacing: ExternalCatalogGridView.titleTypeSpacing) {
                    SkeletonBar(width: width * 0.85, height: ExternalCatalogGridView.titleUIFont.lineHeight)
                    SkeletonBar(width: width * 0.5, height: ExternalCatalogGridView.typeUIFont.lineHeight)
                }
            }
        }
        .frame(width: width, height: ExternalCatalogGridView.textBlockHeight, alignment: .top)
        .sheet(isPresented: $showFullTitle) {
            if let detail {
                ExternalGalleryTitleSheet(title: detail.title)
            }
        }
    }

    /// An invisible backing layer under the title — determines whether the
    /// FULL text (without the 2-line limit) would actually take up more
    /// space than the Text itself (that one is clamped by lineLimit(2), so
    /// its OWN rendered size is always ≤ the height of two lines —
    /// comparing against itself would be pointless). Instead — an
    /// independent calculation via NSString.boundingRect at the same width
    /// and the same font as the visible Text.
    private func titleMeasurement(_ title: String) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { updateTruncation(title: title, width: proxy.size.width) }
                .onChange(of: proxy.size.width) { _, newWidth in updateTruncation(title: title, width: newWidth) }
        }
    }

    private func updateTruncation(title: String, width: CGFloat) {
        guard width > 0 else { return }
        let twoLineHeight = (ExternalCatalogGridView.titleUIFont.lineHeight * 2).rounded(.up)
        let bounding = (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: ExternalCatalogGridView.titleUIFont],
            context: nil
        )
        isTitleTruncated = bounding.height.rounded(.up) > twoLineHeight + 1
    }
}

/// Full title of an external site's gallery — opened by tapping the
/// truncated title on a card (see CatalogCard.titleBlock). Unlike
/// TitleNamesSheet (several labeled fields — Russian/original/English/
/// alternative, specific to the main MangaLib catalog) external sites only
/// have ONE title field (see ExternalGalleryDetail.title) — here it's just
/// the full text without truncation.
private struct ExternalGalleryTitleSheet: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Название")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    NavigationStack {
        ExternalCatalogGridView(site: .hitomi, query: .tag(namespace: .tag, value: "full color"), title: "full color")
    }
    .preferredColorScheme(.dark)
}
