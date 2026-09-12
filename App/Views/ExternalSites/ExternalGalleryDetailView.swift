import SwiftUI
import UIKit

/// Gallery detail card for an external site (see the plan, PART B) —
/// visually COPIES the text/chip/tab style of the regular title detail card
/// (MangaDetailView) — per direct feedback ("keep all the text style
/// exactly like the regular manga one, just adapted for this"): the same
/// "Type" line under the title (as in MangaCardView), the same infoRow row
/// of Type/Language/... chips (see MangaDetailView.infoRow/infoBlock), the
/// same CollapsibleChips for tags/characters/series, the same underlined
/// tabBar instead of the system Picker(.segmented), the same
/// RatingChip-like badge on the cover, the same blockTitle/relatedCard
/// style for "Similar Titles". Does NOT import MangaDetailView (a different
/// data shape, ExternalGalleryDetail, not MangaItem/MangaDetail, see the
/// plan on isolation from the old networking code) — the style was copied
/// line by line, not reused as code.
struct ExternalGalleryDetailView: View {
    let site: ExternalSite
    let id: Int
    /// If the detail was already loaded in the grid (see ExternalCatalogGridView),
    /// don't load it again — just use it right away.
    var preloaded: ExternalGalleryDetail?

    /// Local bookmarks (see the ExternalBookmarksStore doc-comment — external
    /// sites have no accounts, so there are no server-side bookmarks either,
    /// hence a fully local list) — the "Add to bookmarks" button in
    /// actionButtons below.
    @ObservedObject private var bookmarksStore = ExternalBookmarksStore.shared

    @State private var detail: ExternalGalleryDetail?
    @State private var errorMessage: String?
    @State private var tab: Tab = .about
    @State private var previewPage: Int = 1
    @State private var previewJumpText = ""
    @Namespace private var tabIndicator

    /// Reader — ONLY `.fullScreenCover`, not pushed via NavigationLink
    /// (a 1-to-1 match for MangaDetailView.readerOpen/.fullScreenCover) —
    /// it used to be a NavigationLink, which meant the reader stayed
    /// INSIDE the current tab's NavigationStack and the app's tab bar
    /// (Bookmarks/Catalog/...) wasn't hidden, it stuck out over the
    /// reader's UI (per a complaint with a screenshot, Aug 30).
    @State private var readerOpen: ReaderOpen?

    private struct ReaderOpen: Identifiable {
        let id = UUID()
        let initialPage: Int?
    }

    /// Navigating via a chip (Group/Series/Characters/Artist/Female/Male/
    /// Mixed/Other, see aboutTab) — a push (not .fullScreenCover like the
    /// reader: this is a regular catalog, the tab bar/navigation stays the
    /// same as when navigating from ExternalTagBrowserView) to
    /// ExternalCatalogGridView, filtered to THIS specific value ON THE
    /// SAME SITE the card was opened from (per direct feedback on Aug 31 —
    /// "scoped to the site right away", i.e. that exact site's own
    /// namespace/provider, not a shared/guessed one).
    // Hashable (not just Identifiable) — .navigationDestination(item:)
    // specifically requires Hashable (unlike .sheet(item:)/.fullScreenCover
    // (item:), for which Identifiable is enough) — without this the build
    // fails ("requires that 'TagCatalogTarget' conform to 'Hashable'", CI).
    private struct TagCatalogTarget: Identifiable, Hashable {
        let id = UUID()
        let namespace: ExternalTagNamespace
        let value: String
        let title: String
    }

    @State private var tagCatalogTarget: TagCatalogTarget?

    private func openTagCatalog(namespace: ExternalTagNamespace, value: String, title: String) {
        tagCatalogTarget = TagCatalogTarget(namespace: namespace, value: value, title: title)
    }

    private enum Tab: Hashable { case about, comments }

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    /// ~20 pages per "screen" of the preview grid's pagination — the same
    /// number that e-hentai's own thumbnail strip actually returns at once
    /// (confirmed by a HAR capture, see EHentaiProvider.fetchGalleryDetail);
    /// for hitomi the exact number isn't HAR-confirmed — we use the same
    /// value rather than making up a new one.
    private static let previewPageSize = 21
    private static let previewColumns = 3
    /// infoRow chip height — a 1-to-1 match for MangaDetailView.metaChipHeight
    /// (avatar/heading+value in two rows), see infoBlock below.
    private static let metaChipHeight: CGFloat = 44
    /// "Similar Titles" card — a 1-to-1 match for MangaDetailView.similarCardHeight/
    /// similarCoverWidth/similarCardWidthFraction.
    fileprivate static let relatedCardHeight: CGFloat = 132
    fileprivate static let relatedCoverWidth: CGFloat = relatedCardHeight * 2 / 3
    private static let relatedCardWidthFraction: CGFloat = 0.72

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background.ignoresSafeArea())
            .task {
                if let preloaded { detail = preloaded; return }
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            detailBody(detail)
        } else if let errorMessage {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await load() } }, fillScreen: true)
        } else {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailBody(_ detail: ExternalGalleryDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                coverSection(detail)
                titleBlock(detail)
                actionButtons(detail)

                // See the plan PART B.5 — hitomi/3hentai have no concept
                // of comments at all (not a single comment-related request
                // in either site's HAR), the tab isn't shown at all there,
                // all content is always "About". Driven by
                // capabilities.hasComments, not a hardcoded specific site
                // (`site == .ehentai`, as it was before) — otherwise every
                // new site without comments would require editing this
                // exact line.
                if provider.capabilities.hasComments {
                    tabBar
                }

                switch tab {
                case .about:
                    aboutTab(detail)
                case .comments:
                    commentsTab(detail)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .fullScreenCover(item: $readerOpen) { open in
            ExternalReaderView(site: site, detail: detail, initialPage: open.initialPage)
        }
        .navigationDestination(item: $tagCatalogTarget) { target in
            ExternalCatalogGridView(site: site, query: .tag(namespace: target.namespace, value: target.value), title: target.title)
        }
    }

    // MARK: Top of the card (B.1) — a 1-to-1 match for MangaDetailView.heroHeader/titleBlock

    @ViewBuilder
    private func coverSection(_ detail: ExternalGalleryDetail) -> some View {
        if let cover = detail.coverURL {
            ExternalImage(url: cover) { SkeletonBox() }
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Rating — right on the cover, bottom left (see
                // MangaDetailView.coverRatingBadge) — only for e-hentai,
                // hitomi has no such field.
                .overlay(alignment: .bottomLeading) { ratingBadge(detail) }
        }
    }

    @ViewBuilder
    private func ratingBadge(_ detail: ExternalGalleryDetail) -> some View {
        if let average = detail.ratingAverage {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                Text(String(format: "%.2f", average))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                if let count = detail.ratingCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    /// Title + type on a line below it — a 1-to-1 match for the catalog
    /// card's style (see MangaCardView.body: title, immediately under it
    /// the type as secondary-colored text), per direct feedback to adapt
    /// this same style here.
    private func titleBlock(_ detail: ExternalGalleryDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.type.isEmpty {
                Text(detail.type.capitalized)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// "Add to bookmarks" + "Read" — a 1-to-1 match for
    /// MangaDetailView.actionButtons (the same 50/50 split, the same
    /// .bordered/.borderedProminent approach: a gray bordered bookmark
    /// button on the left, a filled accent "Read" button on the right).
    /// Unlike the regular card — no FOLDER choice (see the
    /// ExternalBookmarksStore doc-comment: external sites' local bookmarks
    /// are a simple list, no folders), so tapping toggles immediately,
    /// with no selection sheet.
    private func actionButtons(_ detail: ExternalGalleryDetail) -> some View {
        let inList = bookmarksStore.isBookmarked(site: detail.site, id: detail.id)
        return HStack(spacing: 8) {
            Button {
                bookmarksStore.toggle(detail)
            } label: {
                Label(inList ? "В закладках" : "Добавить в закладки", systemImage: inList ? "bookmark.fill" : "bookmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.bordered)
            .tint(inList ? Theme.accent : Theme.textSecondary)

            // "Start" — a 1-to-1 match for MangaDetailView.readerLink
            // (native .borderedProminent + Theme.accent, not a
            // hand-rolled Capsule). A Button, not a NavigationLink — it
            // opens a `.fullScreenCover` (see readerOpen).
            Button {
                readerOpen = ReaderOpen(initialPage: nil)
            } label: {
                Text("Читать (\(detail.pages.count) стр.)")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    // MARK: "About"/"Comments" tabs — a 1-to-1 match for MangaDetailView.tabBar/
    // tabButton (underlined flat tabs, matchedGeometryEffect), no third
    // "Chapters" tab (per direct feedback — "there won't be a concept of
    // Chapters here").

    private var tabBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                tabButton("О тайтле", .about)
                tabButton("Комментарии", .comments)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let active = tab == value
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { tab = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.bottom, 13)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tabIndicator", in: tabIndicator)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Tab «О тайтле»

    private func aboutTab(_ detail: ExternalGalleryDetail) -> some View {
        let categories = tagsByCategory(detail)
        return VStack(alignment: .leading, spacing: 18) {
            infoRow(detail)
            // Tapping a chip — opens THIS site's catalog right away,
            // filtered to that specific value (see TagCatalogTarget/
            // openTagCatalog, per direct feedback on Aug 31 "tapping a
            // chip should open that tag/genre right away, scoped to the
            // site"). Namespace — its own per category (see
            // ExternalTagNamespace); the value is the plain display name,
            // EACH provider converts it to its own real query itself
            // (for hitomi it's already the right format, for 3hentai —
            // slugification + appending gender, see
            // ThreeHentaiProvider.slugify/withGenderSuffix).
            if !detail.groups.isEmpty {
                chipsBlock("Группа", detail.groups.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .group, value: name, title: name) })
                })
            }
            // The order and split below — per direct feedback (Aug 30):
            // tags are split ENTIRELY into separate subcategories each
            // with its own heading (not one shared "Tags" block), in this
            // order — Series(parody)/Characters(character)/Language(language)/
            // Artist(artist)/Female(female)/Male(male)/Mixed(mixed)/
            // Other(other), each tag in its own separate chip.
            if !detail.series.isEmpty {
                chipsBlock("Серия", detail.series.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .series, value: name, title: name) })
                })
            }
            if !detail.characters.isEmpty {
                chipsBlock("Персонажи", detail.characters.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .character, value: name, title: name) })
                })
            }
            // Language — WITHOUT navigation: no provider has a confirmed
            // namespace for language as a distinct kind (ExternalTagNamespace
            // doesn't know one at all) — honestly non-tappable, rather than
            // a guessed (and likely wrong) destination.
            if let language = detail.language, !language.isEmpty { chipsBlock("Язык", [.init(text: language)]) }
            if !detail.artists.isEmpty {
                chipsBlock("Автор", detail.artists.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .artist, value: name, title: name) })
                })
            }
            if !categories.female.isEmpty {
                chipsBlock("Женское", categories.female.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .female, value: tag.name, title: tag.name) })
                })
            }
            if !categories.male.isEmpty {
                chipsBlock("Мужское", categories.male.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .male, value: tag.name, title: tag.name) })
                })
            }
            // A "Mixed" tag (both female AND male true) — it's ambiguous
            // which of the two real namespaces it belongs to (the site
            // doesn't provide a separate "mixed" kind) — we use .female as
            // a reasonable approximation (the first of the two options
            // that actually exist), rather than inventing a nonexistent
            // third one.
            if !categories.mixed.isEmpty {
                chipsBlock("Смешанное", categories.mixed.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .female, value: tag.name, title: tag.name) })
                })
            }
            if !categories.other.isEmpty {
                chipsBlock("Другое", categories.other.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .tag, value: tag.name, title: tag.name) })
                })
            }
            if !detail.pages.isEmpty { previewGridSection(detail) }
            relatedSection(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// female/male both true — a "Mixed" tag (confirmed by hitomi's real
    /// `galleries/{id}.js`: `tags[]` there has BOTH fields true at once for
    /// some tags); neither one — neutral ("Other"). e-hentai's tag
    /// namespace is strictly single-valued (never both "female" and
    /// "male" on the same tag, see EHentaiProvider.parseMetadata) — there
    /// "Mixed" simply never gets populated, the section honestly doesn't
    /// show up.
    private func tagsByCategory(_ detail: ExternalGalleryDetail) -> (female: [ExternalGalleryTag], male: [ExternalGalleryTag], mixed: [ExternalGalleryTag], other: [ExternalGalleryTag]) {
        var female: [ExternalGalleryTag] = []
        var male: [ExternalGalleryTag] = []
        var mixed: [ExternalGalleryTag] = []
        var other: [ExternalGalleryTag] = []
        for tag in detail.tags {
            switch (tag.female, tag.male) {
            case (true, true): mixed.append(tag)
            case (true, false): female.append(tag)
            case (false, true): male.append(tag)
            case (false, false): other.append(tag)
            }
        }
        return (female, male, mixed, other)
    }

    // MARK: Info row — a 1-to-1 match for MangaDetailView.infoRow/infoBlock
    // (Type/Status/Year/Views/Format) — here it's Type/Posted/Length + the
    // fields that exist ONLY for e-hentai (Parent/Visibility/Size/Favorited);
    // Language is broken out into its own separate chip block (see
    // aboutTab — part of the general split by subcategories), not
    // duplicated here. hitomi simply has no such e-hentai fields, they're
    // just not added to the list.

    private func infoRow(_ detail: ExternalGalleryDetail) -> some View {
        let rawItems: [(heading: String, value: String?)] = [
            (heading: "Тип", value: detail.type.isEmpty ? nil : detail.type.capitalized),
            (heading: "Опубликовано", value: detail.posted),
            (heading: "Длина", value: "\(detail.pages.count) стр."),
            (heading: "Родитель", value: detail.parentId.map { "#\($0)" }),
            (heading: "Видимость", value: detail.visible),
            (heading: "Размер", value: detail.fileSize),
            (heading: "В избранном", value: detail.favoritedCount)
        ]
        let items: [(heading: String, value: String)] = rawItems.compactMap { item in
            guard let value = item.value, !value.isEmpty else { return nil }
            return (heading: item.heading, value: value)
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    infoBlock(item.heading, value: item.value)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func infoBlock(_ heading: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    // MARK: Chips (Group/Series/Characters/Tags) — a 1-to-1 match for
    // MangaDetailView ("Genres and tags"/"Franchise"): blockTitle + the
    // reused CollapsibleChips (the same shared component as in
    // MangaDetailView — a plain UI widget with no dependency on the old
    // networking models, same as SkeletonBox/StateView, which are already
    // reused in this layer).

    private func blockTitle(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(Theme.textPrimary)
    }

    private func chipsBlock(_ title: String, _ items: [CollapsibleChips.Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            blockTitle(title)
            CollapsibleChips(items: items)
        }
    }

    // MARK: Page preview grid + pagination + jump-to-page (B.3) — there's
    // no equivalent of this in the regular manga card (there's a chapter
    // list instead), the heading/fonts are matched to the same
    // blockTitle style for consistency.

    /// Width/spacing — FIXED numbers (not GeometryReader/.flexible()+
    /// aspectRatio like before): the whole section sits inside the same
    /// `.padding(16)` applied to all of the card's content (see
    /// detailBody), so the available width is COMPUTED ahead of time,
    /// without an extra geometry layer — the same approach as
    /// MangaReaderView.titleBadgeMaxWidth. The columns used to be
    /// `.flexible()` with the crop given only an aspectRatio and NO
    /// explicit .frame() — LazyVGrid couldn't reliably compute row height
    /// in a couple of spots (a race with asynchronous image loading),
    /// which made the grid "lag"/tiles overlap each other (complaint from
    /// Aug 30). An explicit .frame(width:height:) on each cell removes the
    /// possibility of that race entirely.
    private static let previewSpacing: CGFloat = 8

    private func previewGridSection(_ detail: ExternalGalleryDetail) -> some View {
        let pages = detail.pages
        let totalPaginationPages = max(1, Int((Double(pages.count) / Double(Self.previewPageSize)).rounded(.up)))
        let clampedPage = min(max(previewPage, 1), totalPaginationPages)
        let startIndex = (clampedPage - 1) * Self.previewPageSize
        let endIndex = min(startIndex + Self.previewPageSize, pages.count)
        let visiblePages = Array(pages[startIndex..<endIndex])

        let availableWidth = UIScreen.main.bounds.width - 32
        let totalSpacing = Self.previewSpacing * CGFloat(Self.previewColumns - 1)
        let cellWidth = ((availableWidth - totalSpacing) / CGFloat(Self.previewColumns)).rounded(.down)
        let cellHeight = (cellWidth * 4 / 3).rounded()
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.previewSpacing), count: Self.previewColumns)

        return VStack(alignment: .leading, spacing: 10) {
            blockTitle("Предпросмотр страниц")

            LazyVGrid(columns: columns, spacing: Self.previewSpacing) {
                ForEach(visiblePages, id: \.index) { page in
                    Button {
                        readerOpen = ReaderOpen(initialPage: page.index)
                    } label: {
                        previewThumb(page, width: cellWidth, height: cellHeight)
                    }
                    .buttonStyle(.plain)
                }
            }

            if totalPaginationPages > 1 {
                paginationRow(total: totalPaginationPages, current: clampedPage)
            }
        }
    }

    private func previewThumb(_ page: ExternalGalleryPage, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = page.thumbnailURL, let offsetX = page.thumbnailSpriteOffsetX {
                    // e-hentai: url is a shared sprite covering a batch of
                    // pages, offsetX picks out the right tile (see
                    // ExternalGalleryPage.thumbnailSpriteOffsetX/
                    // ExternalSpriteThumbnail) — WITHOUT this crop we'd
                    // show the same whole sprite on EVERY page of the batch.
                    ExternalSpriteThumbnail(
                        url: url, offsetX: offsetX, tileWidth: page.width, tileHeight: page.height
                    ) { SkeletonBox() }
                    .scaledToFill()
                } else if let url = page.thumbnailURL {
                    // hitomi: the url already points to that exact page's
                    // own image — no crop needed.
                    ExternalImage(url: url) { SkeletonBox() }
                        .scaledToFill()
                } else {
                    SkeletonBox()
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            Text("\(page.index)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 14)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    private func paginationRow(total: Int, current: Int) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(paginationSequence(total: total, current: current).enumerated()), id: \.offset) { _, item in
                        if let page = item {
                            Button {
                                previewPage = page
                            } label: {
                                Text("\(page)")
                                    .font(.footnote.weight(page == current ? .semibold : .regular))
                                    .foregroundStyle(page == current ? Theme.background : Theme.textPrimary)
                                    .frame(width: 28, height: 28)
                                    .background(page == current ? Theme.accent : Theme.surfaceElevated, in: Circle())
                            }
                            .buttonStyle(.plain)
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

            Spacer(minLength: 0)

            TextField("№", text: $previewJumpText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .frame(width: 44, height: 28)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button {
                if let page = Int(previewJumpText), page > 0 {
                    previewPage = min(page, total)
                    previewJumpText = ""
                }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Int(previewJumpText) != nil ? Theme.accent : Theme.textSecondary.opacity(0.4))
            }
            .disabled(Int(previewJumpText) == nil)
        }
    }

    /// "1 2 3 … 12" — the truncated sequence of page numbers for the
    /// preview grid's pagination, `nil` marks the "…" spot. A purely
    /// client-side calculation (all pages are already loaded into
    /// `detail.pages`), unlike ExternalCatalogGridView.pageJumpRow (that
    /// one does a real network request for a cursor) — here we just page
    /// through an already-ready array.
    private func paginationSequence(total: Int, current: Int) -> [Int?] {
        guard total > 7 else { return (1...total).map { $0 } }
        var keep: Set<Int> = [1, 2, total - 1, total, current - 1, current, current + 1]
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

    // MARK: Similar Titles (B.4) — a 1-to-1 match for
    // MangaDetailView.relatedSection/relatedCard (a wide card: cover on the
    // left spanning the full height of the backing, title+type on the
    // right, a horizontal slider).

    @ViewBuilder
    private func relatedSection(_ detail: ExternalGalleryDetail) -> some View {
        if !detail.related.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                blockTitle("Похожие тайтлы")
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(detail.related, id: \.self) { relatedId in
                                RelatedGalleryCard(site: site, id: relatedId, width: proxy.size.width * Self.relatedCardWidthFraction)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(height: Self.relatedCardHeight)
            }
        }
    }

    // MARK: Comments (B.5) — a 1-to-1 match for MangaDetailView.commentRow
    // (avatar + name/date, text below, a divider between adjacent
    // comments), no threads/votes/spoilers — e-hentai's comments are flat,
    // with no replies.

    @ViewBuilder
    private func commentsTab(_ detail: ExternalGalleryDetail) -> some View {
        if detail.comments.isEmpty {
            StateView(icon: "bubble.left", title: "Пока нет комментариев")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(detail.comments.enumerated()), id: \.offset) { index, comment in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    commentRow(comment)
                }
            }
        }
    }

    private func commentRow(_ comment: ExternalComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "person.fill").font(.footnote).foregroundStyle(Theme.textSecondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(comment.postedAt)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(comment.text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            detail = try await provider.fetchGalleryDetail(id: id)
        } catch {
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
    }
}

/// One card in "Similar Titles" (B.4) — a 1-to-1 match for
/// MangaDetailView.relatedCard (cover on the left spanning the full height
/// of the backing, title+type on the right), but with its own data
/// (ExternalGalleryDetail, not MangaItem) and it loads lazily via `.task`
/// (related is just an ID, full data is fetched the same way as in the
/// catalog grid, see ExternalCatalogGridView.loadDetail).
private struct RelatedGalleryCard: View {
    let site: ExternalSite
    let id: Int
    let width: CGFloat

    @State private var detail: ExternalGalleryDetail?

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }

    var body: some View {
        NavigationLink {
            ExternalGalleryDetailView(site: site, id: id, preloaded: detail)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let cover = detail?.coverURL {
                        ExternalImage(url: cover) { SkeletonBox() }
                            .scaledToFill()
                    } else {
                        SkeletonBox()
                    }
                }
                .frame(width: ExternalGalleryDetailView.relatedCoverWidth, height: ExternalGalleryDetailView.relatedCardHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail?.title ?? "…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if let type = detail?.type, !type.isEmpty {
                        Text(type.capitalized)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, height: ExternalGalleryDetailView.relatedCardHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            guard detail == nil else { return }
            detail = try? await provider.fetchGalleryDetail(id: id)
        }
    }
}

#Preview {
    NavigationStack {
        ExternalGalleryDetailView(site: .hitomi, id: 3267795)
    }
    .preferredColorScheme(.dark)
}
