import SwiftUI

/// Страница переводчика (команды) — шапка теперь 1-в-1 как в карточке
/// тайтла (см. MangaDetailView.heroHeader): растягивающийся хиро-фон,
/// плавающая обложка-аватар (2:3, как обычная обложка тайтла), название
/// поверх, своя стеклянная кнопка "назад" вместо системной шапки (её нет
/// вообще), и там же, где у тайтла "..." — кнопка подписки на уведомления.
/// Метаданные — те же чипы, что и у тайтла (infoBlock), включая отдельным
/// чипом количество участников. Список тайтлов с поиском/фильтрами/
/// сортировкой — из CharacterView (тот же паттерн, target_model=team).
struct TeamView: View {
    let slugURL: String
    let fallbackName: String?
    let coverURL: URL?

    @StateObject private var vm: TeamViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFilters = false
    @State private var showTeamNames = false
    @State private var profileUser: ProfileUserId?
    @State private var selectedTab: Tab = .titles
    @FocusState private var searchFocused: Bool

    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12

    private static let heroTitleSpacing: CGFloat = 10
    /// Расстояние от верха баннера до аватара — фиксированное, чтобы кнопка
    /// "назад"/подписки никогда не пересекались с аватаром (тот же приём,
    /// что и в MangaDetailView.heroCoverTopOffset).
    private static let heroAvatarTopOffset: CGFloat = 120
    /// Та же величина, что и MangaDetailView.metaChipHeight — своя копия,
    /// т.к. та константа fileprivate к своему файлу.
    private static let metaChipHeight: CGFloat = 44

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
                VStack(alignment: .leading, spacing: 0) {
                    heroHeader(avatarSize: cardWidth)

                    VStack(alignment: .leading, spacing: 18) {
                        socialLinks(availableWidth: proxy.size.width - 32)
                        metaRow(availableWidth: proxy.size.width - 32)
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
                    .padding(.top, 18)
                    .padding(.bottom, 90)
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "teamScroll")
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(edges: .top)
        }
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showFilters) {
            FilterView(initial: vm.filter) { vm.apply(filter: $0) }
        }
        .sheet(isPresented: $showTeamNames) {
            // Переиспользуем тот же sheet, что и у названия тайтла (см.
            // MangaDetailView.titleBlock) — по прямой просьбе. У команды нет
            // отдельных рус/оригинал/англ полей, только name + alt_name
            // (одна строка через запятую) — раскладываем её в otherNames.
            TitleNamesSheet(rusName: vm.detail?.name ?? fallbackName, originalName: nil, engName: nil, otherNames: teamOtherNames)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $profileUser) { pu in ProfileView(userId: pu.id) }
    }

    /// alt_name с сервера — одна строка через запятую ("DIT, дед, деды, …") —
    /// раскладывается в список для TitleNamesSheet.
    private var teamOtherNames: [String] {
        (vm.detail?.altName ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Шапка (1-в-1 MangaDetailView.heroHeader)

    /// avatarSize — ширина карточки в гриде тайтлов ниже (cardWidth), по
    /// прямой просьбе: аватар команды уменьшен до размера обложки тайтла в
    /// списке "тайтлы, где есть эта команда", а не увеличенный размер
    /// обложки, как в MangaDetailView.heroHeader. Высота — тот же формат
    /// 2:3, что и у карточки тайтла (см. MangaCardView.body: width*3/2).
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
                    ZStack { Theme.surfaceElevated; Image(systemName: "person.2.fill").foregroundStyle(Theme.textSecondary) }
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
            // тайтла — см. подробный комментарий в MangaDetailView.heroHeader.
            GeometryReader { proxy in
                let minY = proxy.frame(in: .named("teamScroll")).minY
                let stretch = max(0, minY)
                let realBG = vm.detail?.background?.bestURL
                let effectiveURL = realBG ?? vm.detail?.cover?.bestURL ?? coverURL

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
                // Блюр — только для запасной картинки (обложка вместо
                // настоящего фона команды), как и у тайтла.
                .blur(radius: realBG != nil ? 0 : 5)
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
        .overlay(alignment: .topLeading) { backButton }
        .overlay(alignment: .topTrailing) { subscribeButton }
    }

    /// По прямой просьбе — по центру (не слева, как в MangaDetailView), и
    /// тап открывает тот же sheet со всеми названиями, что и у тайтла (см.
    /// showTeamNames/TitleNamesSheet).
    private var titleBlockOverlay: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(vm.detail?.name ?? fallbackName ?? "")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let altName = vm.detail?.altName, !altName.isEmpty {
                Text(altName)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { showTeamNames = true }
    }

    /// Своя стеклянная кнопка "назад" вместо системной шапки — по прямой
    /// просьбе убрать шапку целиком, оставив только её. 1-в-1
    /// MangaDetailView.heroHeader (тот же стиль/позиция).
    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 54)
    }

    /// Там, где у тайтла кнопка "..." — здесь подписка на уведомления
    /// команды. ПОДТВЕРЖДЕНО перехватом: стартовое состояние — реальный
    /// GET /favorites/team/{id} (TeamViewModel.loadSubscriptionStatus),
    /// переключение — тот же POST /favorites, что и у колокольчика в чипе
    /// главы (TeamChipView). Обычное стекло в обоих состояниях (без
    /// акцента, по прямой просьбе) — текст меняется на "Увед. включены" со
    /// значком колокольчика с галкой.
    private var subscribeButton: some View {
        Button { vm.toggleSubscription() } label: {
            HStack(spacing: 6) {
                if vm.isTogglingSubscription {
                    ProgressView().scaleEffect(0.7)
                } else if vm.isSubscribed {
                    ZStack {
                        Image(systemName: "bell.fill")
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
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
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isTogglingSubscription)
        .padding(.trailing, 16)
        .padding(.top, 54)
    }

    // MARK: Метаданные — те же чипы, что у тайтла (MangaDetailView.infoBlock)

    /// Статистика команды + отдельным чипом количество участников (по
    /// прямой просьбе — "тоже в чипы метаданных вместе"). По центру (в
    /// отличие от чипов участников ниже, которые "от угла", т.е. слева) —
    /// availableWidth нужен явно: ScrollView(.horizontal) в осевом
    /// направлении предлагает контенту НЕОГРАНИЧЕННУЮ ширину, поэтому
    /// .frame(maxWidth: .infinity) сам по себе тут не центрирует (растёт до
    /// бесконечности вместо этого) — только minWidth с реальным числом.
    private func metaRow(availableWidth: CGFloat) -> some View {
        let statItems: [(heading: String, value: String)] = (vm.detail?.stats ?? []).compactMap { stat in
            guard let value = stat.short, let heading = stat.label else { return nil }
            return (heading, value)
        }
        let items = vm.members.isEmpty ? statItems : statItems + [(heading: "Участников", value: "\(vm.members.count)")]

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

    /// Ссылки на соцсети (vk/discord/website — все три подтверждены
    /// перехватом), только если реально есть. НЕ стеклянные — по прямой
    /// просьбе, обычная плашка (Theme.surfaceElevated), как у чипов
    /// метаданных ниже. По центру и ниже/мельче, чем раньше — та же техника
    /// принудительной ширины, что и у metaRow (см. комментарий там: у
    /// ScrollView(.horizontal) в осевом направлении контенту предлагается
    /// неограниченная ширина, поэтому центрирование требует minWidth с
    /// реальным числом, а не maxWidth: .infinity). Своих иконок VK/Discord в
    /// приложении нет — generic SF Symbols (см. список "что уточнить").
    private func socialLinks(availableWidth: CGFloat) -> some View {
        let links = socialLinkItems
        return Group {
            if !links.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(links, id: \.label) { link in
                            Link(destination: link.url) {
                                HStack(spacing: 5) {
                                    Image(systemName: link.icon).font(.caption2.weight(.semibold))
                                    Text(link.label).font(.caption2.weight(.medium)).lineLimit(1)
                                }
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(Theme.surfaceElevated, in: Capsule())
                            }
                        }
                    }
                    .frame(minWidth: availableWidth, alignment: .center)
                }
                .scrollIndicators(.hidden)
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

    /// Участники команды — по прямой просьбе чипы с ролью и ссылкой на
    /// профиль. ПОДТВЕРЖДЕНО отдельным эндпоинтом GET /teams/{slug}/users
    /// (не путать с анонимным полем "users" внутри самого GET /teams/{slug} —
    /// там только роль без id/имени, поэтому оно вообще не декодируется, см.
    /// TeamMemberEntry). Тап открывает ProfileView(userId:) — ЧЕРЕЗ
    /// .sheet(item:), а не NavigationLink-пуш: ProfileView везде в
    /// приложении (см. MangaDetailView.profileUser) открывается как sheet —
    /// у него своя внутренняя NavigationStack и кастомный dismiss()/toolbar-
    /// hidden хедер, рассчитанные именно на модальную презентацию. Пуш его
    /// через NavigationLink здесь был единственным местом-исключением и
    /// ломал стек навигации (см. баг-репорт: после перехода из карточки
    /// команды в профиль участника приложение вышибало на вкладку "Читают" с
    /// неработающими кнопками до переключения вкладки). Количество
    /// участников — отдельным чипом в metaRow выше, поэтому здесь в
    /// заголовке больше не дублируется.
    @ViewBuilder
    private var membersSection: some View {
        if !vm.members.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Участники").font(.headline).foregroundStyle(Theme.textPrimary)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(vm.members) { member in
                            Button { profileUser = ProfileUserId(id: member.userId) } label: {
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

    /// Раскладка — 1-в-1 HomeView.topActiveUserCard ("Читают" → "Топ активных
    /// недели"), по прямой просьбе, только со своими данными: вместо
    /// ранга (N#) и "Уровень N"/полоски прогресса (этого у участника
    /// команды просто нет) — роль второй строкой.
    /// Форма — 1-в-1 TeamChipView (чип команды в списке глав карточки
    /// тайтла): Capsule, Theme.surfaceElevated, паддинг/высота
    /// metaChipHeight, аватар 28×28 круг. Контент — свой (участник, а не
    /// команда): ник + роль вместо названия команды + колокольчика.
    private func memberChip(_ member: TeamMemberEntry) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RemoteImage(url: member.avatarURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.surface)
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
                    .font(.subheadline.weight(.medium))
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
        .frame(height: Self.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
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
