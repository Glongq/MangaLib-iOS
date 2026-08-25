import SwiftUI

/// Страница переводчика (команды) — по прямой просьбе собрана из двух
/// существующих экранов: шапка (аватар слева в формате обложки 2:3 +
/// хиро-фон сзади, затемнённый так же, как в профиле пользователя, справа —
/// соцсети вместо счётчиков "создано тайтлов/…") взята из ProfileView (см.
/// AccountInfoView.swift), а метаданные/описание/список тайтлов с поиском,
/// фильтрами и сортировкой — из CharacterView (тот же паттерн, тот же
/// каталожный запрос, только target_model=team вместо character).
struct TeamView: View {
    let slugURL: String
    let fallbackName: String?
    let coverURL: URL?

    @StateObject private var vm: TeamViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showFilters = false
    @State private var selectedTab: Tab = .titles
    @FocusState private var searchFocused: Bool

    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12
    /// Эталон обложки 2:3 (см. Theme.coverAspectRatio/coverCornerRadius) — по
    /// прямой просьбе: аватар команды в формате обложки, а не круглый, как у
    /// пользователя.
    private let avatarWidth: CGFloat = 108

    private enum Tab: String, CaseIterable, Identifiable {
        case titles = "Тайтлы"
        case updates = "Обновления"
        var id: String { rawValue }
    }

    init(slugURL: String, fallbackName: String? = nil, coverURL: URL? = nil) {
        self.slugURL = slugURL
        self.fallbackName = fallbackName
        self.coverURL = coverURL
        _vm = StateObject(wrappedValue: TeamViewModel(slugURL: slugURL))
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(width: proxy.size.width)

                    VStack(alignment: .leading, spacing: 18) {
                        nameAndStats
                        membersSection

                        if let desc = vm.detail?.description, !desc.isEmpty {
                            ExpandableDescription(text: desc)
                        } else if vm.isLoadingDetail {
                            ProgressView().tint(Theme.accent)
                        }

                        tabSwitcher

                        if selectedTab == .titles {
                            titlesControls
                            grid(cardWidth: cardWidth)
                        } else {
                            updatesPlaceholder
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 90)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.detail?.name ?? fallbackName ?? "Переводчик")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showFilters) {
            FilterView(initial: vm.filter) { vm.apply(filter: $0) }
        }
    }

    // MARK: Шапка (хиро-фон + аватар 2:3 + соцсети)

    private func header(width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: vm.detail?.background?.bestURL) { img in
                img.resizable().scaledToFill()
            } placeholder: { Theme.surfaceElevated } failure: { Theme.surfaceElevated }
            .frame(width: width, height: 230)
            .clipped()
            // То же затемнение, что и у баннера профиля (см. ProfileView.
            // bannerGradient) — здесь без адаптивной яркости (там она нужна
            // была для читаемости своего оверлея "Готово"/заголовка поверх
            // баннера; тут заголовок — обычный системный navigationTitle).
            .overlay(
                LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.22), .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            )

            HStack(alignment: .bottom, spacing: 14) {
                RemoteImage(url: vm.detail?.cover?.bestURL ?? coverURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "person.2.fill").font(.title2).foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: avatarWidth, height: (avatarWidth * Theme.coverAspectRatio).rounded())
                .clipShape(RoundedRectangle(cornerRadius: Theme.coverCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.coverCornerRadius, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

                Spacer(minLength: 0)

                socialLinks
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(height: 230)
    }

    /// Справа, где у пользователя в профиле "Создано тайтлов/Загружено
    /// глав/Кол-во комментариев" — по прямой просьбе здесь ссылки на
    /// соцсети, только если реально есть (vk/discord/website — все три
    /// подтверждены перехватом). Своих иконок VK/Discord в приложении нет —
    /// текстовые плашки с названием площадки, как временное решение (см.
    /// список "что уточнить").
    @ViewBuilder
    private var socialLinks: some View {
        let links = socialLinkItems
        if !links.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(links, id: \.label) { link in
                    Link(destination: link.url) {
                        HStack(spacing: 6) {
                            Image(systemName: link.icon).font(.caption.weight(.semibold))
                            Text(link.label).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
    }

    private var socialLinkItems: [(label: String, icon: String, url: URL)] {
        var result: [(label: String, icon: String, url: URL)] = []
        if let vk = vm.detail?.vk, let url = URL(string: vk) {
            result.append(("VK", "person.2.fill", url))
        }
        if let discord = vm.detail?.discord, let url = URL(string: discord) {
            result.append(("Discord", "message.fill", url))
        }
        if let website = vm.detail?.website, let url = URL(string: website) {
            result.append(("Сайт", "link", url))
        }
        return result
    }

    // MARK: Имя + метаданные (как в карточке персонажа)

    private var nameAndStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let altName = vm.detail?.altName, !altName.isEmpty {
                Text(altName).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if !(vm.detail?.stats ?? []).isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(vm.detail?.stats ?? []) { stat in
                            statColumn(value: stat.short, label: stat.label ?? "")
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.hidden)
            }
            subscribeButton
        }
    }

    /// Подписаться/отписаться от переводчика — ПОДТВЕРЖДЕНО перехватом:
    /// стартовое состояние тянется реальным GET /favorites/team/{id}
    /// (TeamViewModel.loadSubscriptionStatus), переключение — тем же
    /// POST /favorites, что и у колокольчика в чипе главы (TeamChipView).
    private var subscribeButton: some View {
        Button { vm.toggleSubscription() } label: {
            HStack(spacing: 6) {
                if vm.isTogglingSubscription {
                    ProgressView().scaleEffect(0.7).tint(vm.isSubscribed ? Theme.textPrimary : .white)
                } else {
                    Image(systemName: vm.isSubscribed ? "checkmark" : "bell")
                }
                Text(vm.isSubscribed ? "Вы подписаны" : "Подписаться")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(vm.isSubscribed ? Theme.textPrimary : .white)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(vm.isSubscribed ? AnyShapeStyle(Theme.surfaceElevated) : AnyShapeStyle(Theme.accent), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isTogglingSubscription)
        .padding(.top, 2)
    }

    /// Участники команды — по прямой просьбе чипы с ролью и ссылкой на
    /// профиль. ПОДТВЕРЖДЕНО отдельным эндпоинтом GET /teams/{slug}/users
    /// (не путать с анонимным полем "users" внутри самого GET /teams/{slug} —
    /// там только роль без id/имени, поэтому оно вообще не декодируется, см.
    /// TeamMemberEntry). Тап открывает ProfileView(userId:) — тот же экран
    /// профиля, что и везде в приложении.
    @ViewBuilder
    private var membersSection: some View {
        if !vm.members.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Участники (\(vm.members.count))").font(.headline).foregroundStyle(Theme.textPrimary)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(vm.members) { member in
                            NavigationLink { ProfileView(userId: member.userId) } label: {
                                memberChip(member)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func memberChip(_ member: TeamMemberEntry) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RemoteImage(url: member.avatarURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.surface).overlay(Image(systemName: "person.fill").font(.caption2).foregroundStyle(Theme.textSecondary))
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                // Декоративная рамка аватара — ПОДТВЕРЖДЕНО перехватом
                // (avatar_frame встречается у части участников), поверх, без
                // обрезки (рамки — прозрачный PNG чуть шире самого аватара).
                if let frameURL = member.avatarFrameURL {
                    RemoteImage(url: frameURL) { img in
                        img.resizable().scaledToFit()
                    } placeholder: { Color.clear }
                    .frame(width: 38, height: 38)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 0) {
                Text(member.username)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let role = member.rolesString, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private func statColumn(value: String?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: Переключатель Тайтлы / Обновления

    private var tabSwitcher: some View {
        Picker("", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    /// "Обновления" — эндпоинт последних глав именно ЭТОЙ команды в
    /// перехвате не подтверждён (только общая /latest-updates без фильтра по
    /// команде) — честная заглушка вместо выдумывания запроса.
    private var updatesPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text("Раздел в разработке").font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
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
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var siteMenu: some View {
        Menu {
            Picker("Тип", selection: $vm.siteFilter) {
                ForEach(vm.availableFilters) { f in
                    Text(Self.filterLabel(f)).tag(f)
                }
            }
        } label: {
            pill(icon: "square.grid.2x2", text: Self.filterLabel(vm.siteFilter))
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
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private static func siteLabel(_ s: LibSite) -> String {
        switch s {
        case .mangalib:  return "Манга"
        case .ranobelib: return "Новеллы"
        case .hentailib: return "Хентай"
        case .slashlib:  return "Слэш"
        }
    }

    private static func filterLabel(_ f: TeamViewModel.SiteFilter) -> String {
        switch f {
        case .all: return "Все"
        case .site(let s): return siteLabel(s)
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
