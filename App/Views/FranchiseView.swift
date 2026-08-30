import SwiftUI

/// Экран франшизы — по прямой просьбе "как раздел персонажа, только без
/// обложки сверху и с другими данными": в отличие от CharacterView/TeamView
/// у франшизы НЕТ картинки вообще (см. Franchise) — поэтому здесь нет ни
/// hero-баннера, ни своей стеклянной кнопки "назад" поверх него: обычная
/// системная навигационная панель (системный back + свайп-назад бесплатно),
/// подписка — кнопкой в трейлинге тулбара вместо кнопки поверх баннера.
/// Остальное — 1-в-1 CharacterView: центрированное название+альт.название,
/// чипы метаданных (Тайтлов/Подписчиков), поиск/тип контента/фильтры/
/// сортировка, грид тайтлов франшизы.
struct FranchiseView: View {
    let slugURL: String
    let fallbackName: String?

    @StateObject private var vm: FranchiseViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12

    init(slugURL: String, fallbackName: String? = nil) {
        self.slugURL = slugURL
        self.fallbackName = fallbackName
        _vm = StateObject(wrappedValue: FranchiseViewModel(slugURL: slugURL))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: 16
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock

                    metaRow(availableWidth: proxy.size.width - 32)

                    titlesControls
                    grid(cardWidth: cardWidth)
                        .dismissKeyboardOnFirstTap(active: searchFocused) { searchFocused = false }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { subscribeButton }
        }
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showFilters) {
            FilterView(initial: vm.filter) { vm.apply(filter: $0) }
        }
    }

    // MARK: Заголовок

    private var titleBlock: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(vm.detail?.name ?? fallbackName ?? "")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let alt = vm.detail?.altName, !alt.isEmpty {
                Text(alt)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Там, где у команды/персонажа кнопка на баннере — здесь просто в
    /// тулбаре (у франшизы нет баннера, под который её накладывать). Тот же
    /// эндпоинт/стиль текста, что и TeamView.subscribeButton — реальный
    /// POST /favorites {source_type:"franchise"} (см. FranchiseViewModel).
    private var subscribeButton: some View {
        Button { vm.toggleSubscription() } label: {
            HStack(spacing: 6) {
                if vm.isTogglingSubscription {
                    ProgressView().scaleEffect(0.7)
                } else if vm.isSubscribed {
                    ZStack {
                        Image(systemName: "bell.fill")
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                            .offset(x: 7, y: -7)
                    }
                } else {
                    Image(systemName: "bell")
                }
                Text(vm.isSubscribed ? "Увед. включены" : "Подписаться")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .disabled(vm.isTogglingSubscription)
    }

    // MARK: Метаданные — чипы (1-в-1 CharacterView.metaRow/infoBlock)

    private func metaRow(availableWidth: CGFloat) -> some View {
        let items: [(heading: String, value: String)] = [
            vm.detail?.titlesCount.map { ("Тайтлов", "\($0)") },
            vm.detail?.subscribersCount.map { ("Подписчиков", "\($0)") }
        ].compactMap { $0 }

        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    infoBlock(item.heading, value: item.value)
                }
            }
            .frame(minWidth: availableWidth, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private func infoBlock(_ heading: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    // MARK: Поиск + управление (тип контента / фильтры / сортировка) — 1-в-1 CharacterView

    private var titlesControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            HStack(spacing: 8) {
                siteMenu
                Spacer(minLength: 0)
                filtersButton
                sortMenu
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("", text: $vm.query,
                      prompt: Text("Поиск по названию").foregroundColor(Theme.textSecondary))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
            if !vm.query.isEmpty {
                Button { vm.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    /// В отличие от CharacterView/TeamView — здесь у выбора сайта СРАЗУ
    /// видно число тайтлов ("Манга 6"), по прямой просьбе с референса.
    private var siteMenu: some View {
        Menu {
            Picker("Тип", selection: $vm.siteFilter) {
                ForEach(vm.availableFilters) { f in
                    Text(filterLabel(f)).tag(f)
                }
            }
        } label: {
            pill(icon: "square.grid.2x2", text: filterLabel(vm.siteFilter))
        }
    }

    private var filtersButton: some View {
        Button { showFilters = true } label: {
            pill(icon: "slider.horizontal.3", text: "Фильтры", badge: vm.filter.activeCount)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Сортировка", selection: $vm.sort) {
                ForEach(CharacterTitleSort.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            pill(icon: "arrow.up.arrow.down", text: nil)
        }
    }

    private func pill(icon: String, text: String?, badge: Int = 0) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            if let text {
                Text(text).font(.footnote.weight(.medium)).lineLimit(1)
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Theme.accent, in: Circle())
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private func siteLabel(_ s: LibSite) -> String {
        switch s {
        case .mangalib:  return "Манга"
        case .ranobelib: return "Новеллы"
        case .hentailib: return "Хентай"
        case .slashlib:  return "Слэш"
        }
    }

    private func filterLabel(_ f: FranchiseViewModel.SiteFilter) -> String {
        switch f {
        case .all: return "Все"
        case .site(let s):
            guard let count = vm.titlesCount(for: s) else { return siteLabel(s) }
            return "\(siteLabel(s)) \(count)"
        }
    }

    // MARK: Грид тайтлов

    @ViewBuilder
    private func grid(cardWidth: CGFloat) -> some View {
        if let error = vm.errorMessage, vm.titles.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: error, retry: { vm.reloadNow() }, minHeight: 140)
        } else if vm.titles.isEmpty && vm.didLoadOnce && !vm.isLoading {
            StateView(icon: "books.vertical", title: "Нет тайтлов", minHeight: 140)
        } else {
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: gridColumnsCount)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vm.titles) { item in
                    NavigationLink {
                        MangaDetailView(
                            slug: item.apiSlug,
                            fallbackTitle: item.displayTitle,
                            coverURL: item.cover?.bestURL,
                            item: item
                        )
                    } label: {
                        MangaCardView(item: item, width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .onAppear { vm.loadMoreIfNeeded(item) }
                }
            }

            if vm.isLoading && vm.titles.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if vm.isLoadingMore {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }
}

#Preview {
    NavigationStack {
        FranchiseView(slugURL: "308--originalnye-raboty", fallbackName: "Оригинальные работы")
    }
    .preferredColorScheme(.dark)
}
