import SwiftUI

/// The "Bookmarks" section for "Other Sites" (hitomi.la, e-hentai.org,
/// 3hentai.net, imhentai.xxx — see App/ExternalSites/) — an ENTIRELY LOCAL
/// list (see the ExternalBookmarksStore doc comment: these sites have no
/// accounts, so bookmarks can't sync with a server, they can only
/// live on the device), per direct request (Aug 31) — this replaces the
/// former "Unavailable" placeholder in BookmarksView.body for external mode.
///
/// "Everything else matches the default bookmarks screen where it overlaps" — visually mirrors
/// BookmarksView (see its doc comment): the same card-tile architecture
/// (exact width computed via MangaCardView.gridCardWidth, the same shared
/// @AppStorage("personalization_cards_per_row")), the same list/grid
/// toggle, the same .searchable() under a large title. What does NOT match
/// (honestly, there's no equivalent): folders (BookmarkFolder — a server-side concept of the 5
/// standard folders on the real site, there's nowhere to get that here),
/// multi-select/bulk operations, reading progress/personal rating (external
/// titles simply don't have that — see ExternalGalleryDetail, neither a user
/// rating nor reading progress is stored). A card is ALWAYS labeled with its
/// source (site.displayName) — per direct request, since bookmarks can come
/// from several different sites at once.
struct ExternalBookmarksView: View {
    @ObservedObject private var store = ExternalBookmarksStore.shared
    @State private var query = ""
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    @AppStorage("external_bookmarks_view_mode") private var viewMode: BookmarksViewMode = .grid
    @AppStorage("external_bookmarks_sort_option") private var sortOption: ExternalBookmarksSortOption = .dateAdded
    @AppStorage("external_bookmarks_sort_direction") private var sortDirection: BookmarksSortDirection = .newestFirst
    /// The same shared Personalization setting as the regular catalog/
    /// bookmarks (2/3/4/Auto) — a shared @AppStorage key, not a separate one of its own.
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto

    @State private var showViewSortSheet = false

    private var gridColumnsCount: Int { cardsPerRow.columns }
    private static let gridSpacing: CGFloat = 12
    private static let gridHorizontalPadding: CGFloat = 12

    private var filtered: [ExternalBookmark] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? store.bookmarks : store.bookmarks.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        return sorted(base)
    }

    private func sorted(_ items: [ExternalBookmark]) -> [ExternalBookmark] {
        switch sortOption {
        case .dateAdded:
            return items.sorted { sortDirection == .newestFirst ? $0.addedAt > $1.addedAt : $0.addedAt < $1.addedAt }
        case .title:
            return items.sorted { a, b in
                let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
                return sortDirection == .newestFirst ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Закладки")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Поиск в закладках")
            .toolbar {
                if !store.bookmarks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showViewSortSheet = true } label: {
                            Image(systemName: "gearshape").frame(width: 30, height: 30)
                        }
                    }
                }
            }
            .sheet(isPresented: $showViewSortSheet) {
                ExternalBookmarksViewSortSheet(viewMode: $viewMode, sortOption: $sortOption, sortDirection: $sortDirection)
            }
            .navigationDestination(for: ExternalBookmark.self) { bm in
                ExternalGalleryDetailView(site: bm.site, id: bm.galleryId)
            }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var content: some View {
        if store.bookmarks.isEmpty {
            // ScrollView (not a bare StateView) — otherwise .navigationTitle
            // disappears entirely, the same trick used in BookmarksView.
            ScrollView {
                StateView(icon: "bookmark", title: "Пусто", description: "Добавляйте тайтлы через кнопку «Добавить в закладки» на странице тайтла.", fillScreen: true)
                    .containerRelativeFrame(.vertical)
            }
            .scrollIndicators(.hidden)
        } else {
            Group {
                switch viewMode {
                case .list: listContent
                case .grid: gridContent
                }
            }
            .dismissKeyboardOnFirstTap(active: isSearching) { dismissSearch() }
        }
    }

    // MARK: Tapping a row/card opens the title detail; a long
    // press/swipe removes it from bookmarks (no folders — no separate
    // selection sheet like regular bookmarks have, just a direct removal).

    @ViewBuilder
    private func tapTarget<Content: View>(_ bm: ExternalBookmark, @ViewBuilder content: () -> Content) -> some View {
        if isSearching {
            Button { dismissSearch() } label: { content() }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: bm) { content() }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        store.remove(site: bm.site, id: bm.galleryId)
                    } label: {
                        Label("Убрать из закладок", systemImage: "bookmark.slash")
                    }
                }
        }
    }

    // MARK: List

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filtered) { bm in
                    tapTarget(bm) { row(bm) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    static let coverWidth: CGFloat = 80
    static let coverHeight: CGFloat = (coverWidth * 3 / 2).rounded()

    private func row(_ bm: ExternalBookmark) -> some View {
        HStack(spacing: 12) {
            ExternalImage(url: bm.coverURL.flatMap(URL.init(string:))) { SkeletonBox() }
                .scaledToFill()
                .frame(width: Self.coverWidth, height: Self.coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(bm.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(bm.site.displayName)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.trailing, 12)
        .frame(height: Self.coverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Grid — the same exact-width-computation architecture as
    // MangaCatalogView.grid/BookmarksView.gridContent (see their comments).

    private var gridContent: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: Self.gridSpacing,
                containerPadding: Self.gridHorizontalPadding
            )
            let items = filtered
            let rows = stride(from: 0, to: items.count, by: gridColumnsCount).map { start in
                Array(items[start..<min(start + gridColumnsCount, items.count)])
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            ForEach(rowItems) { bm in
                                tapTarget(bm) { gridCell(bm, width: cardWidth) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func gridCell(_ bm: ExternalBookmark, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ExternalImage(url: bm.coverURL.flatMap(URL.init(string:))) { SkeletonBox() }
                .scaledToFill()
                .frame(width: width, height: (width * 3 / 2).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipped()
                .overlay(alignment: .topLeading) { siteBadge(bm) }

            Text(bm.title)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)
        }
        .frame(width: width, alignment: .top)
    }

    /// The title's source — ALWAYS visible (not only when several sites
    /// are enabled at once, like showsSourceBadge in
    /// ExternalCatalogGridView) — per direct request: "the card should always
    /// show which site the title is from".
    private func siteBadge(_ bm: ExternalBookmark) -> some View {
        Text(bm.site.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }
}

/// The sort field — a separate type from BookmarksSortOption (that one is tied
/// to the server-side `sort_by` fields of real Lib.social bookmarks; here there's only
/// date added/title, nothing else to sort by).
enum ExternalBookmarksSortOption: String, CaseIterable, Identifiable {
    case dateAdded, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dateAdded: return "По дате добавления"
        case .title: return "По названию"
        }
    }
}

/// The "View"/"Sort" sheet — the same general style as BookmarksView.
/// ViewSortSheet (list/grid + sort field + direction,
/// BookmarksSortDirection reused as-is — the same "newest/oldest first" concept,
/// no point introducing a second identical enum),
/// simplified to fewer fields (no folders/rating/reading progress).
private struct ExternalBookmarksViewSortSheet: View {
    @Binding var viewMode: BookmarksViewMode
    @Binding var sortOption: ExternalBookmarksSortOption
    @Binding var sortDirection: BookmarksSortDirection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Вид") {
                    Picker("Вид", selection: $viewMode) {
                        Text("Список").tag(BookmarksViewMode.list)
                        Text("Плитка").tag(BookmarksViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.surfaceElevated)
                }
                Section("Сортировка") {
                    ForEach(ExternalBookmarksSortOption.allCases) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Text(option.title).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if sortOption == option {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Theme.surfaceElevated)
                    }
                }
                Section {
                    Picker("Направление", selection: $sortDirection) {
                        ForEach(BookmarksSortDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.surfaceElevated)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Вид и сортировка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    ExternalBookmarksView()
        .preferredColorScheme(.dark)
}
