import SwiftUI

/// Экран "Избранное" (Меню → Профиль → Избранное) — раньше вела на StubView
/// (заглушку), теперь реальный постраничный список с поиском, 5 категорий
/// снизу (Команды/Люди/Персонажи/Франшизы/Издатели, см. FavoritesCategory).
/// По прямой просьбе: Команды/Франшизы/Издатели — СПИСКОМ (тот же стиль
/// строки, что и в DirectoryListView/FranchiseListView), Люди/Персонажи —
/// КАРТОЧКАМИ (сеткой, как обложки тайтлов).
struct FavoritesListView: View {
    let userId: Int

    @StateObject private var vm = FavoritesListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared

    // Та же настройка Персонализации (2/3/4/Авто), что и в остальных сетках
    // приложения — влияет на карточную сетку (Люди/Персонажи).
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto
    private var gridColumnsCount: Int { cardsPerRow.columns }
    private let gridSpacing: CGFloat = 12
    private let gridHorizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Избранное")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.query, prompt: "Поиск по названию")
        .safeAreaInset(edge: .bottom, spacing: 0) { categoryBar }
        .tint(Theme.accent)
        .task { vm.loadInitialIfNeeded(userId: userId) }
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.errorMessage, vm.items.isEmpty {
            errorState(error)
        } else if vm.items.isEmpty && vm.isLoading {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.items.isEmpty && vm.didLoadOnce {
            ContentUnavailableView.search(text: vm.query)
        } else if vm.category.isGrid {
            cardGrid
        } else {
            list
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
            Button { vm.retry(userId: userId) } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Категории — 5 капсул внизу экрана

    /// 1-в-1 нижние кнопки-табы FriendsView.tabBar/tabButton (по прямой
    /// просьбе выровнять): стеклянные капсулы, авто-ширина + горизонтальный
    /// скролл.
    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(FavoritesCategory.allCases) { category in
                    categoryCapsule(category)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func categoryCapsule(_ category: FavoritesCategory) -> some View {
        let active = vm.category == category
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { vm.category = category }
        } label: {
            Text(category.title)
                .font(.footnote.weight(active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.background : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: Theme.pillControlHeight)
                .glassEffect(active ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Список (Команды / Франшизы / Издатели)

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(vm.items) { entity in
                    listRow(entity)
                        .onAppear { vm.loadMoreIfNeeded(currentItem: entity, userId: userId) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)

            if vm.isLoadingMore {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func listRow(_ entity: DirectoryEntity) -> some View {
        // Франшиза никогда не присылает обложку (см. FavoriteEntry) — своя
        // безобложечная строка, 1-в-1 стиль FranchiseListView.row; у
        // остальных категорий обложка есть — строка со миниатюрой слева,
        // 1-в-1 стиль DirectoryListView.rowContent.
        destination(for: entity) {
            if vm.category == .franchise {
                franchiseRowContent(entity)
            } else {
                coverRowContent(entity)
            }
        }
    }

    private static let rowCoverWidth: CGFloat = 64
    private static let rowCoverHeight: CGFloat = 96

    private func coverRowContent(_ entity: DirectoryEntity) -> some View {
        HStack(spacing: 0) {
            RemoteImage(url: entity.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: vm.category.placeholderIcon).foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.rowCoverWidth, height: Self.rowCoverHeight)
            .clipped()
            .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 16))

            VStack(alignment: .leading, spacing: 6) {
                Text(entity.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                statsChipsRow(entity)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            removeButton(entity).padding(.trailing, 10)
        }
        .frame(height: Self.rowCoverHeight)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    private func franchiseRowContent(_ entity: DirectoryEntity) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entity.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                statsChipsRow(entity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            removeButton(entity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Убрать из избранного — красная мусорка справа в строке (по прямой
    /// просьбе). Обычный Button ВНУТРИ лейбла NavigationLink — тот же приём,
    /// что и у subscribeBell в DirectoryListView/FranchiseListView: тап по
    /// нему не запускает переход на карточку сущности, система сама отдаёт
    /// приоритет вложенной кнопке.
    private func removeButton(_ entity: DirectoryEntity) -> some View {
        Button {
            vm.remove(entity)
        } label: {
            ZStack {
                Circle().fill(Theme.surface)
                if vm.isRemoving(entity.id) {
                    ProgressView().scaleEffect(0.7).tint(.red)
                } else {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(vm.isRemoving(entity.id))
    }

    /// Короткие чипы-метаданные — 1-в-1 DirectoryListView.statsChipsRow
    /// (иконка + готовое короткое значение с сервера).
    private static let statIconOrder: [(tag: String, icon: String)] = [
        ("titles", "book.closed.fill"),
        ("likes", "heart.fill"),
        ("subscribes", "person.3.fill")
    ]

    private func statsChipsRow(_ entity: DirectoryEntity) -> some View {
        var used = Set<String>()
        var chips: [(id: String, icon: String, value: String)] = []
        for (tag, icon) in Self.statIconOrder {
            if let stat = entity.stats.first(where: { $0.tag == tag }), let short = stat.short {
                chips.append((tag, icon, short))
                used.insert(tag)
            }
        }
        for stat in entity.stats where !used.contains(stat.tag ?? "") {
            if let short = stat.short {
                chips.append((stat.id, "circle.fill", short))
            }
        }
        return HStack(spacing: 6) {
            ForEach(chips, id: \.id) { chip in
                HStack(spacing: 4) {
                    Image(systemName: chip.icon).font(.system(size: 10, weight: .semibold))
                    Text(chip.value).font(.caption2.weight(.medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Theme.surface, in: Capsule())
            }
        }
    }

    // MARK: Карточки (Люди / Персонажи)

    private var cardGrid: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: gridHorizontalPadding
            )
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: gridColumnsCount)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(vm.items) { entity in
                        destination(for: entity) { personCard(entity, width: cardWidth) }
                            .onAppear { vm.loadMoreIfNeeded(currentItem: entity, userId: userId) }
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)

                if vm.isLoadingMore {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func personCard(_ entity: DirectoryEntity, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: entity.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: vm.category.placeholderIcon).foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: width, height: (width * 3 / 2).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            .overlay(alignment: .topTrailing) { removeBadge(entity) }

            Text(entity.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)
        }
        .frame(width: width, alignment: .top)
    }

    /// Убрать из избранного — красная мусорка справа сверху обложки (по
    /// прямой просьбе, "на персонажей на обложку справа сверху"), тот же
    /// приём "Button внутри лейбла NavigationLink", что и у removeButton в
    /// списках.
    private func removeBadge(_ entity: DirectoryEntity) -> some View {
        Button {
            vm.remove(entity)
        } label: {
            ZStack {
                Circle().fill(.black.opacity(0.55))
                if vm.isRemoving(entity.id) {
                    ProgressView().scaleEffect(0.55).tint(.white)
                } else {
                    Image(systemName: "trash.fill").font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(vm.isRemoving(entity.id))
        .padding(6)
    }

    // MARK: Навигация — те же экраны, что и у обычных списков

    @ViewBuilder
    private func destination<Label: View>(for entity: DirectoryEntity, @ViewBuilder label: () -> Label) -> some View {
        switch vm.category.targetModel {
        case "team":
            NavigationLink {
                TeamView(slugURL: entity.slugURL, fallbackName: entity.displayName, coverURL: entity.coverURL)
            } label: { label() }
            .buttonStyle(.plain)
        case "character":
            NavigationLink {
                CharacterView(slugURL: entity.slugURL, fallbackName: entity.displayName, coverURL: entity.coverURL)
            } label: { label() }
            .buttonStyle(.plain)
        case "franchise":
            NavigationLink {
                FranchiseView(slugURL: entity.slugURL, fallbackName: entity.displayName)
            } label: { label() }
            .buttonStyle(.plain)
        default:
            NavigationLink {
                DirectoryDetailView(kind: vm.category == .people ? .people : .publisher, slugURL: entity.slugURL, fallbackName: entity.displayName, coverURL: entity.coverURL)
            } label: { label() }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    NavigationStack {
        FavoritesListView(userId: 1)
    }
    .preferredColorScheme(.dark)
}
