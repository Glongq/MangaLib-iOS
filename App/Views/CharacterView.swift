import SwiftUI

/// Экран персонажа — тот же "полный стиль", что и у страницы переводчика
/// (см. TeamView), по прямой просьбе, только со своими данными: хиро-фон +
/// плавающая обложка-аватар (2:3, размер = карточка тайтла в гриде ниже) по
/// центру экрана, кнопка "назад" — toolbar-элемент над прозрачным системным
/// navigation bar (см. .toolbar в body, та же схема, что в TeamView/
/// MangaDetailView), название по центру с тапом на sheet со всеми
/// названиями, метаданные чипами, описание, список тайтлов с поиском/
/// фильтрами/сортировкой.
///
/// Чего у персонажа НЕТ (в отличие от команды) — соответствующие блоки
/// TeamView просто отсутствуют здесь, а не имитируются пустыми:
/// - "background" (хиро-фон) в GET /character/{slug_url} не подтверждён —
///   фон всегда падает на blur-обложку (тот же fallback-путь, что и у
///   команды без фона).
/// - Соцсети (vk/discord/website) — таких полей у персонажа нет.
/// - Участники — это команда, не персонаж.
/// - Кнопка подписки на месте "..." — эндпоинт подписки на персонажа нигде
///   не подтверждён перехватом, поэтому в правом верхнем углу шапки только
///   пусто, без выдуманной кнопки.
/// - Переключатель "Тайтлы"/"Обновления" — у персонажа только один список
///   (тайтлы, где он есть), второй вкладки не из чего делать.
struct CharacterView: View {
    let slugURL: String
    let fallbackName: String?
    let coverURL: URL?

    @StateObject private var vm: CharacterViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFilters = false
    @State private var showCharacterNames = false
    @FocusState private var searchFocused: Bool

    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12

    private static let heroTitleSpacing: CGFloat = 10
    /// Расстояние от верха баннера до аватара — фиксированное (см.
    /// TeamView.heroAvatarTopOffset — тот же приём и то же число).
    private static let heroAvatarTopOffset: CGFloat = 120
    /// Та же величина, что и у MangaDetailView.metaChipHeight/TeamView.metaChipHeight.
    private static let metaChipHeight: CGFloat = 44

    init(slugURL: String, fallbackName: String? = nil, coverURL: URL? = nil) {
        self.slugURL = slugURL
        self.fallbackName = fallbackName
        self.coverURL = coverURL
        _vm = StateObject(wrappedValue: CharacterViewModel(slugURL: slugURL))
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
                VStack(alignment: .leading, spacing: 0) {
                    heroHeader(avatarSize: cardWidth)

                    VStack(alignment: .leading, spacing: 18) {
                        metaRow(availableWidth: proxy.size.width - 32)

                        if let desc = vm.detail?.description, !desc.isEmpty {
                            ExpandableDescription(text: desc)
                        } else if vm.isLoadingDetail {
                            ProgressView().tint(Theme.accent)
                        }

                        titlesControls
                        grid(cardWidth: cardWidth)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 90)
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "characterScroll")
            .background(Theme.background)
            .ignoresSafeArea(edges: .top)
            // РЕАЛЬНЫЙ системный navigation bar (не .toolbar(.hidden...), как
            // было) — прозрачный, без заголовка. Та же причина, что и в
            // MangaDetailView/TeamView: полностью скрытый бар ломал
            // интерактивный свайп-назад с экранов с .searchable() (напр.
            // DirectoryListView) — "просвечивал" поиск сквозь эту карточку.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // placement: .navigation — см. тот же фикс и объяснение в
                // MangaDetailView.body (.topBarLeading + navigationBarBackButtonHidden
                // не гасил системную кнопку "назад" надёжно — задваивалась).
                ToolbarItem(placement: .navigation) { backButton }
            }
        }
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showFilters) {
            FilterView(initial: vm.filter) { vm.apply(filter: $0) }
        }
        .sheet(isPresented: $showCharacterNames) {
            // Тот же sheet, что и у названия тайтла/команды (см.
            // TeamView.showTeamNames) — по прямой просьбе. У персонажа нет
            // отдельного englishName/списка альтернативных названий,
            // подтверждённых перехватом — только name (основное) и rus_name.
            TitleNamesSheet(rusName: vm.detail?.rusName, originalName: vm.detail?.name ?? fallbackName, engName: nil, otherNames: [])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Шапка (1-в-1 TeamView.heroHeader)

    /// avatarSize — ширина карточки в гриде тайтлов ниже (cardWidth), тот же
    /// приём, что и в TeamView.heroHeader.
    private func heroHeader(avatarSize: CGFloat) -> some View {
        let avatarHeight = (avatarSize * 3 / 2).rounded()
        return VStack(alignment: .center, spacing: 0) {
            Color.clear.frame(height: Self.heroAvatarTopOffset)

            VStack(alignment: .center, spacing: Self.heroTitleSpacing) {
                RemoteImage(url: vm.detail?.cover?.bestURL ?? coverURL, priority: URLSessionTask.highPriority) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: avatarSize, height: avatarHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

                titleBlockOverlay
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .background(alignment: .top) {
            // Та же "тянущаяся шапка" под rubber-band overscroll, что и у
            // тайтла/команды. У персонажа нет отдельного поля фона —
            // effectiveURL падает на обложку (с блюром), как и у команды
            // без background.
            GeometryReader { proxy in
                let stretch = max(0, proxy.frame(in: .named("characterScroll")).minY)
                let effectiveURL = vm.detail?.cover?.bestURL ?? coverURL

                Group {
                    if let effectiveURL {
                        RemoteImage(url: effectiveURL, priority: URLSessionTask.highPriority) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            SkeletonBox()
                        } failure: {
                            Theme.surfaceElevated
                        }
                    } else {
                        Theme.background
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height + stretch)
                .overlay(Color.black.opacity(0.1))
                .blur(radius: 5)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.28),
                            .init(color: Theme.background.opacity(0.35), location: 0.5),
                            .init(color: Theme.background.opacity(0.75), location: 0.72),
                            .init(color: Theme.background, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(y: -stretch)
            }
        }
    }

    /// По центру, тап открывает sheet со всеми названиями — 1-в-1
    /// TeamView.titleBlockOverlay.
    private var titleBlockOverlay: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(vm.detail?.name ?? fallbackName ?? "")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let orig = vm.detail?.altName, !orig.isEmpty {
                Text(orig).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).lineLimit(1)
            } else if let rus = vm.detail?.rusName, !rus.isEmpty {
                Text(rus).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { showCharacterNames = true }
    }

    /// Кнопка "назад" — настоящий toolbar-элемент (см. .toolbar в body), тот
    /// же стиль/размер, что и TeamView.backButton/MangaDetailView. Кнопки на
    /// месте "..."/подписки здесь нет — эндпоинт подписки на персонажа нигде
    /// не подтверждён (см. комментарий у структуры).
    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: Circle())
    }

    // MARK: Метаданные — чипы (как у тайтла/команды), по центру

    private func metaRow(availableWidth: CGFloat) -> some View {
        let items: [(heading: String, value: String)] = [
            vm.detail?.titlesCount.map { ("Тайтлов", Self.grouped($0)) },
            vm.detail?.subscribersCount.map { ("Подписчиков", Self.grouped($0)) }
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
        .frame(height: Self.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Поиск + управление (тип контента / фильтры / сортировка)

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

    /// НЕ стеклянный — по прямой просьбе (обычная плашка Theme.surfaceElevated).
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

    /// НЕ стеклянный — по прямой просьбе (обычная плашка Theme.surfaceElevated).
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

    private static func siteLabel(_ s: LibSite) -> String {
        switch s {
        case .mangalib:  return "Манга"
        case .ranobelib: return "Новеллы"
        case .hentailib: return "Хентай"
        case .slashlib:  return "Слэш"
        }
    }

    /// Число тайтлов рядом с названием сайта ("Манга 6") — как попросили,
    /// по образцу FranchiseView. Не static (нужен доступ к vm.titlesCount).
    private func filterLabel(_ f: CharacterViewModel.SiteFilter) -> String {
        switch f {
        case .all: return "Все"
        case .site(let s):
            guard let count = vm.titlesCount(for: s) else { return Self.siteLabel(s) }
            return "\(Self.siteLabel(s)) \(count)"
        }
    }

    // MARK: Грид тайтлов

    @ViewBuilder
    private func grid(cardWidth: CGFloat) -> some View {
        if let error = vm.errorMessage, vm.titles.isEmpty {
            VStack(spacing: 10) {
                Text(error).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        } else if vm.titles.isEmpty && vm.didLoadOnce && !vm.isLoading {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                Text("Нет тайтлов").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
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
