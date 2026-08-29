import SwiftUI

/// Экран «Сейчас читают» (Меню → Каталог → Сейчас читают) — раньше вела на
/// StubView (заглушку), теперь реальный полноэкранный постраничный список,
/// 1-в-1 референс с реального сайта (по прямой просьбе, со скриншотом):
/// вкладки Новинки/Набирающие популярность/Популярное под заголовком, справа
/// сверху — выбор периода (За день/неделю/месяц), сетка карточек с рейтингом
/// слева сверху обложки и числом просмотров слева снизу. НЕ переиспользует
/// MangaCardView — та бэйджит рейтинг СПРАВА сверху и завязана на статус
/// закладки (тут не нужен), у этого экрана своя, отдельная раскладка чипов
/// на обложке (см. topViewsCard ниже), как на реальном сайте.
struct TopViewsListView: View {
    @StateObject private var vm = TopViewsListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @Namespace private var tabIndicator

    // Та же настройка Персонализации (2/3/4/Авто), что и в остальных сетках
    // приложения (см. CardsPerRow) — на скриншоте 3 колонки, это её "Авто".
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto
    private var gridColumnsCount: Int { cardsPerRow.columns }
    private let gridSpacing: CGFloat = 12
    private let gridHorizontalPadding: CGFloat = 16

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
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: gridHorizontalPadding
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tabsRow
                        .padding(.horizontal, gridHorizontalPadding)

                    if let error = vm.errorMessage, vm.items.isEmpty {
                        errorState(error)
                    } else if vm.items.isEmpty && vm.isLoading {
                        skeletonGrid(cardWidth: cardWidth)
                    } else if vm.items.isEmpty && vm.didLoadOnce {
                        emptyState
                    } else {
                        grid(cardWidth: cardWidth)
                        if vm.isLoadingMore {
                            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Вкладки (Новинки / Набирающие популярность / Популярное)

    private var tabsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(TopViewsSort.allCases) { sort in
                    tabButton(sort)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func tabButton(_ sort: TopViewsSort) -> some View {
        let active = vm.sort == sort
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.sort = sort }
        } label: {
            Text(sort.title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    if active {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "topViewsTabIndicator", in: tabIndicator)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Период (За день / За неделю / За месяц)

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
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.surfaceElevated, in: Capsule())
        }
    }

    // MARK: Сетка

    private func grid(cardWidth: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: gridColumnsCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(vm.items) { item in
                NavigationLink {
                    MangaDetailView(slug: item.apiSlug, fallbackTitle: item.displayTitle, coverURL: item.cover?.bestURL, item: item)
                } label: {
                    topViewsCard(item, width: cardWidth)
                }
                .buttonStyle(.plain)
                .onAppear { Task { await vm.loadMoreIfNeeded(current: item) } }
            }
        }
        .padding(.horizontal, gridHorizontalPadding)
    }

    private func skeletonGrid(cardWidth: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: gridColumnsCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(0..<gridColumnsCount * 4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBox()
                        .frame(width: cardWidth, height: (cardWidth * 3 / 2).rounded())
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    SkeletonBar(width: cardWidth, height: 12)
                    SkeletonBar(width: cardWidth * 0.6, height: 10)
                }
            }
        }
        .padding(.horizontal, gridHorizontalPadding)
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

    /// Своя карточка (не MangaCardView) — 1-в-1 референс скриншота: рейтинг
    /// скруглённым квадратом слева сверху обложки (не капсулой справа, как
    /// у MangaCardView.ratingBadge — на этом конкретном экране реального
    /// сайта рейтинг именно так), число просмотров тёмной капсулой с иконкой
    /// глаза слева снизу, название (до 2 строк) и тип тайтла под обложкой.
    private func topViewsCard(_ item: MangaItem, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: item.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: width, height: (width * 3 / 2).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipped()
            .overlay(alignment: .topLeading) { topViewsRatingBadge(item.rating?.value) }
            .overlay(alignment: .bottomLeading) { topViewsViewsBadge(item.topViewsCount) }

            Text(item.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)

            if let typeLabel = item.type?.label, !typeLabel.isEmpty {
                Text(typeLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .top)
    }

    /// Тот же цвет по значению, что и у RatingChip (см. её color(for:)) —
    /// своя копия здесь: форма бэйджа на этом экране другая (скруглённый
    /// прямоугольник, не капсула), переиспользовать саму RatingChip как есть
    /// нельзя, а красится оценка везде одинаково.
    private func topViewsRatingColor(_ value: Double) -> Color {
        switch value {
        case 7.0...:      return .green
        case 5.0..<7.0:   return .yellow
        case 0.001..<5.0: return .red
        default:          return .gray
        }
    }

    @ViewBuilder
    private func topViewsRatingBadge(_ rating: Double?) -> some View {
        if let rating {
            Text(String(format: "%.1f", rating))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(topViewsRatingColor(rating), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(6)
        }
    }

    @ViewBuilder
    private func topViewsViewsBadge(_ views: Int?) -> some View {
        if let views {
            HStack(spacing: 3) {
                Image(systemName: "eye.fill").font(.system(size: 9))
                Text("\(views)").font(.system(size: 11, weight: .semibold))
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
