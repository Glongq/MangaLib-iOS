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
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: gridHorizontalPadding
            )
            ScrollView {
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
            .scrollIndicators(.hidden)
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
        .padding(.top, 12)
        .padding(.bottom, 24)
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
        .padding(.top, 12)
        .padding(.bottom, 24)
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
            .overlay(alignment: .topTrailing) {
                RatingChip(rating: item.rating?.value, fontSize: 9, horizontalPadding: 6, verticalPadding: 3, outerPadding: 6)
            }
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
