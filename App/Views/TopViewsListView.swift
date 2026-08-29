import SwiftUI

/// Экран «Сейчас читают» (Меню → Каталог → Сейчас читают) — раньше вела на
/// StubView (заглушку), теперь реальный полноэкранный постраничный список.
/// По прямой просьбе (правки после первой версии, со скриншотом):
/// вкладки Новинки/Набирающие популярность/Популярное — 3 капсулы ВНИЗУ
/// экрана (не под шапкой), справа сверху обложки — рейтинг ТЕМ ЖЕ чипом,
/// что и в Каталоге/Закладках (RatingChip, размер 9/6/3/6), выбор периода
/// (За день/неделю/месяц) в toolbar — БЕЗ своего фона (см. periodMenu —
/// иначе он накладывается на системное стекло toolbar двойным слоем).
struct TopViewsListView: View {
    @StateObject private var vm = TopViewsListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared

    // Та же настройка Персонализации (2/3/4/Авто), что и в остальных сетках
    // приложения (см. CardsPerRow) — на скриншоте 3 колонки, это её "Авто".
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto
    private var gridColumnsCount: Int { cardsPerRow.columns }
    private let gridSpacing: CGFloat = 12
    private let gridHorizontalPadding: CGFloat = 16

    // Название/тип под обложкой — ТЕ ЖЕ шрифты, что и в MangaCardView
    // (эталон Каталога/Закладок: caption1/caption2 × 1.2, см. её
    // titleUIFont/typeUIFont) — раньше здесь были свои .caption(.semibold)/
    // .caption2, из-за чего масштаб текста визуально не совпадал с
    // остальными вкладками (по прямой просьбе выровнено).
    private static let textScale: CGFloat = 1.2
    private var titleFont: Font { Font(Self.titleUIFont) }
    private var typeFont: Font { Font(Self.typeUIFont) }
    private static var titleUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        return UIFont.systemFont(ofSize: base.pointSize * textScale, weight: .medium)
    }
    private static var typeUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption2)
        return UIFont.systemFont(ofSize: base.pointSize * textScale, weight: .regular)
    }
    private static var titleTypeSpacing: CGFloat { titleUIFont.leading }
    private static func textBlockHeight(twoLineTitle: Bool) -> CGFloat {
        let titleHeight = titleUIFont.lineHeight * (twoLineTitle ? 2 : 1)
        let typeHeight = typeUIFont.lineHeight
        return (titleHeight + titleTypeSpacing + typeHeight).rounded(.up)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Сейчас читают")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { periodMenu }
        }
        .safeAreaInset(edge: .bottom) { tabsBar }
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.errorMessage, vm.items.isEmpty {
            errorState(error)
        } else if vm.items.isEmpty && vm.isLoading {
            skeletonGrid
        } else if vm.items.isEmpty && vm.didLoadOnce {
            emptyState
        } else {
            grid
        }
    }

    // MARK: Вкладки (Новинки / Набирающие популярность / Популярное) — внизу

    /// 3 капсулы внизу экрана (не под шапкой, как в первой версии) — по
    /// прямой просьбе. .safeAreaInset(edge: .bottom) в body — контент
    /// ScrollView сам поджимается, не заезжает под бар и не перекрывается им.
    private var tabsBar: some View {
        HStack(spacing: 8) {
            ForEach(TopViewsSort.allCases) { sort in
                tabCapsule(sort)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.thinMaterial)
    }

    private func tabCapsule(_ sort: TopViewsSort) -> some View {
        let active = vm.sort == sort
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { vm.sort = sort }
        } label: {
            Text(sort.title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.background : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: Theme.pillControlHeight)
                .background(active ? Theme.accent : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Период (За день / За неделю / За месяц)

    /// БЕЗ .background() — ToolbarItem в iOS 26 сам оборачивает содержимое в
    /// системное стеклянное закругление; свой непрозрачный фон поверх него
    /// давал двойное наложение ("накладывается что-то" — жалоба). Тут только
    /// содержимое, стекло — от системы, как и у остальных toolbar-кнопок в
    /// приложении (см. actionMenu в MangaDetailView — тоже без своего фона).
    private var periodMenu: some View {
        Menu {
            Picker("Период", selection: $vm.period) {
                ForEach(TopViewsPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(vm.period.title)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: Сетка
    //
    // 1-в-1 устройство сетки MangaCatalogView.grid (эталон) — НЕ LazyVGrid
    // (тот вариант визуально "съезжал" — жалоба), а явные HStack-ряды через
    // stride, посчитанные из ОДНОГО GeometryReader на весь экран. rowNeedsTwoLines
    // — решение на весь ряд сразу (см. MangaCardView.rowNeedsTwoLines), нужно
    // видеть все карточки ряда, поэтому ряды явные, не плоский ForEach.

    private var grid: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: gridHorizontalPadding
            )
            let rows = stride(from: 0, to: vm.items.count, by: gridColumnsCount).map { start in
                Array(vm.items[start..<min(start + gridColumnsCount, vm.items.count)])
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                        let rowNeedsTwoLines = rowItems.contains {
                            MangaCardView.titleLineCount($0.displayTitle, width: cardWidth) > 1
                        }
                        HStack(alignment: .top, spacing: gridSpacing) {
                            ForEach(rowItems) { item in
                                NavigationLink {
                                    MangaDetailView(slug: item.apiSlug, fallbackTitle: item.displayTitle, coverURL: item.cover?.bestURL, item: item)
                                } label: {
                                    topViewsCard(item, width: cardWidth, rowNeedsTwoLines: rowNeedsTwoLines)
                                }
                                .buttonStyle(.plain)
                                .onAppear { Task { await vm.loadMoreIfNeeded(current: item) } }
                            }
                        }
                    }
                    if vm.isLoadingMore {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var skeletonGrid: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: gridHorizontalPadding
            )
            let placeholderCount = 12
            let rows = stride(from: 0, to: placeholderCount, by: gridColumnsCount).map { start in
                Array(start..<min(start + gridColumnsCount, placeholderCount))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowIndices in
                        HStack(alignment: .top, spacing: gridSpacing) {
                            ForEach(rowIndices, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    SkeletonBox()
                                        .frame(width: cardWidth, height: (cardWidth * 3 / 2).rounded())
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    SkeletonBar(width: cardWidth * 0.85, height: 12)
                                    SkeletonBar(width: cardWidth * 0.5, height: 10)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "flame").font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text("Пока пусто").font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button { vm.retry() } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.horizontal, gridHorizontalPadding)
    }

    // MARK: Карточка «Сейчас читают»

    /// Своя карточка (не MangaCardView) — обложка+название+тип в том же
    /// стиле, что и везде, но рейтинг — ТОТ ЖЕ чип, что в Каталоге/Закладках
    /// (RatingChip, справа сверху, 9/6/3/6 — по прямой просьбе "по размерам
    /// одинаковая с чипами в вкладках закладки каталог"); число просмотров —
    /// свой чип слева снизу (глаз+число), той же высоты капсулы, что и
    /// RatingChip (тот же fontSize/паддинги), чтобы оба чипа на обложке были
    /// визуально одного калибра.
    private func topViewsCard(_ item: MangaItem, width: CGFloat, rowNeedsTwoLines: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: width, height: (width * 3 / 2).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            .overlay(alignment: .topTrailing) {
                RatingChip(rating: item.rating?.value, fontSize: 9, horizontalPadding: 6, verticalPadding: 3, outerPadding: 6)
            }
            .overlay(alignment: .bottomLeading) { topViewsViewsBadge(item.topViewsCount) }

            // Название+тип — та же логика "всегда вплотную, недостающая
            // высота уходит пустым местом ниже жанра", что и в MangaCardView
            // (см. её textBlockHeight/rowNeedsTwoLines).
            VStack(alignment: .leading, spacing: Self.titleTypeSpacing) {
                Text(item.displayTitle)
                    .font(titleFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .topLeading)

                Text(item.type?.label ?? " ")
                    .font(typeFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                    .opacity(item.type?.label == nil ? 0 : 1)
            }
            .frame(width: width, alignment: .top)
            .frame(minHeight: Self.textBlockHeight(twoLineTitle: rowNeedsTwoLines), alignment: .top)
        }
        .frame(width: width, alignment: .top)
    }

    @ViewBuilder
    private func topViewsViewsBadge(_ views: Int?) -> some View {
        if let views {
            HStack(spacing: 3) {
                Image(systemName: "eye.fill").font(.system(size: 8))
                Text("\(views)").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }
}

#Preview {
    NavigationStack {
        TopViewsListView()
    }
    .preferredColorScheme(.dark)
}
