import SwiftUI

/// Раздел «Закладки» для «Других сайтов» (hitomi.la, e-hentai.org,
/// 3hentai.net, imhentai.xxx — см. App/ExternalSites/) — ЦЕЛИКОМ ЛОКАЛЬНЫЙ
/// список (см. ExternalBookmarksStore doc-comment: у этих сайтов нет
/// аккаунтов, значит закладки не могут синхронизироваться с сервером,
/// только жить на устройстве), по прямой просьбе (31.08) — заменяет собой
/// прежнюю заглушку «Недоступно» в BookmarksView.body для внешнего режима.
///
/// «Всё остальное как в деф закладках, что совпадает» — визуально повторяет
/// BookmarksView (см. её doc-comment): та же архитектура карточки-плитки
/// (точный расчёт ширины через MangaCardView.gridCardWidth, тот же общий
/// @AppStorage("personalization_cards_per_row")), тот же список/плитка
/// переключатель, тот же .searchable() под крупным заголовком. НЕ совпадает
/// (честно нет аналога): папки (BookmarkFolder — серверная концепция 5
/// стандартных папок реального сайта, здесь неоткуда её взять),
/// мультивыбор/bulk-операции, прогресс чтения/личная оценка (у внешних
/// тайтлов такого просто нет — см. ExternalGalleryDetail, ни рейтинга
/// пользователя, ни прогресса чтения не хранится). Карточка ВСЕГДА подписана
/// источником (site.displayName) — по прямой просьбе, закладки могут быть
/// сразу с нескольких разных сайтов.
struct ExternalBookmarksView: View {
    @ObservedObject private var store = ExternalBookmarksStore.shared
    @State private var query = ""
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    @AppStorage("external_bookmarks_view_mode") private var viewMode: BookmarksViewMode = .grid
    @AppStorage("external_bookmarks_sort_option") private var sortOption: ExternalBookmarksSortOption = .dateAdded
    @AppStorage("external_bookmarks_sort_direction") private var sortDirection: BookmarksSortDirection = .newestFirst
    /// Та же общая настройка Персонализации, что и у обычного каталога/
    /// закладок (2/3/4/Авто) — общий @AppStorage-ключ, не свой отдельный.
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
            // ScrollView (не голый StateView) — иначе .navigationTitle
            // пропадает целиком, тот же приём, что и в BookmarksView.
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

    // MARK: Тап на строку/карточку — открыть карточку тайтла, долгое
    // нажатие/свайп — убрать из закладок (нет папок — нет отдельного листа
    // выбора, как у обычных закладок, просто прямое удаление).

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

    // MARK: Список

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

    // MARK: Плитка — та же архитектура точного расчёта ширины, что и
    // MangaCatalogView.grid/BookmarksView.gridContent (см. их комментарии).

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

    /// Источник тайтла — ВСЕГДА виден (не только когда несколько сайтов
    /// одновременно включено, как у showsSourceBadge в
    /// ExternalCatalogGridView) — по прямой просьбе: "на карточке пусть
    /// пишется с какого сайта это тайтл".
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

/// Поле сортировки — отдельный тип от BookmarksSortOption (то завязано на
/// серверные `sort_by`-поля реальных закладок Lib.social, здесь только
/// дата добавления/название, больше сортировать не по чему).
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

/// Щит «Вид»/«Сортировка» — тот же общий стиль, что и BookmarksView.
/// ViewSortSheet (список/плитка + поле сортировки + направление,
/// BookmarksSortDirection переиспользован как есть — то же самое понятие
/// "сначала новые/старые", ни к чему заводить второй одинаковый enum),
/// упрощённый под меньшее число полей (нет папок/рейтинга/прогресса чтения).
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
