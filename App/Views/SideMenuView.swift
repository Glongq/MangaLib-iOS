import SwiftUI

/// Пункт-заглушка, на который ведут элементы меню.
struct StubView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let title: String
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            StateView(icon: "hammer", title: title, description: "Раздел в разработке.", fillScreen: true)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Меню — теперь не боковой drawer на 75% ширины, а системный sheet почти на
/// весь экран (стандартная анимация снизу вверх, свайп вниз для закрытия —
/// это ровно то поведение, что просили; см. `.sheet` в RootView.swift, который
/// презентует этот вью). Сам SideMenuView — просто КОНТЕНТ листа, больше не
/// управляет своим показом/скримом/анимацией сам — это делает системный sheet.
struct SideMenuView: View {

    /// Переход на заглушку по выбранному разделу.
    var onSelect: (String) -> Void
    /// Открыть экран входа — теперь общий с быстрой кнопкой профиля в
    /// RootView (та же самая, ОДНА sheet-презентация на двоих, см. RootView.swift).
    var onOpenLogin: () -> Void
    /// Открыть экран информации об аккаунте — общий с быстрой кнопкой профиля.
    var onOpenAccount: () -> Void
    /// Открыть Каталог с выбранным типом тайтла (меню «Тайтлы» → Манга/Манхва/…).
    var onOpenCatalog: (Int) -> Void

    // Реальная сессия — см. AuthSession.swift/LoginView.swift. Карточка
    // профиля переключается между "Войти" и данными аккаунта автоматически.
    @ObservedObject private var auth = AuthSession.shared

    // Активный сайт (каталог/закладки/история) + набор сайтов для мультипоиска
    // — см. LibSite.swift/SiteSession. @ObservedObject, чтобы строка сайта и
    // блок чекбоксов сразу перерисовывались при переключении.
    @ObservedObject private var siteSession = SiteSession.shared
    /// «Другие сайты» (hitomi.la и далее, см. App/ExternalSites/) — не
    /// LibSite, отдельный независимый переключатель, см. siteRow.
    @ObservedObject private var externalSiteSession = ExternalSiteSession.shared

    @ObservedObject private var themeManager = ThemeManager.shared

    // История по-прежнему свой локальный sheet прямо здесь — быстрая кнопка
    // профиля её не касается, поэтому не нужно поднимать выше в RootView.
    // История/Настройки/Загрузки теперь не sheet, а обычные PUSH-переходы внутри
    // вкладки «Меню» (нижний таб-бар остаётся виден) — см. NavigationStack ниже.
    private enum MenuRoute: Hashable {
        case history, settings, downloads, comments, franchises, friends, collections, myCollections
        case teams, characters, people, publishers, users, nowReading, favorites, combinedCatalog
    }
    // NavigationPath (не типизированный [MenuRoute]) — иначе вложенные
    // NavigationLink(value:) ВНУТРИ этих экранов (например, History →
    // тайтл, см. HistoryView.navigationDestination(for: HistoryEntry.self))
    // не могут запушиться в путь, типизированный только под MenuRoute, и тап
    // по ссылке молча ничего не делает.
    @State private var path = NavigationPath()

    // Какие сворачиваемые разделы сейчас развёрнуты (Профиль/Каталог/Другое) —
    // у каждого своя стрелка вверх/вниз в заголовке подложки. По умолчанию все
    // развёрнуты.
    @State private var expandedSections: Set<String> = ["Профиль", "Каталог", "Другое"]
    // Внутри раздела «Каталог»: показывается ли под-экран выбора типа тайтла
    // (Манга/ОЭЛ манга/…), заменяющий обычный список раздела (см. catalogSection).
    @State private var catalogShowingTypes = false
    // Раскрыт ли список выбора активного сайта в блоке профиля (см. siteRow).
    @State private var siteExpanded = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    // Блоки-карточки с отступами между ними — как на референсе
                    // (лист аккаунта Apple): каждая логическая группа пунктов —
                    // отдельная закруглённая карточка, между карточками зазор.
                    // Был удвоен (34→68) по прямой просьбе, затем возвращён
                    // обратно (68→34, "уменьши в 2 раза") — на устройстве
                    // удвоенный оказался слишком большим.
                    VStack(spacing: 34) {
                        block1
                        quickBlock
                        profileSection
                        catalogSection
                        otherSection
                        searchSitesBlock
                        externalSitesBlock
                        combinedCatalogBlock
                    }
                    .padding(.horizontal, 16)
                    // Компенсация за отсутствующую строку поиска (была здесь
                    // как +56 к top, см. тот же откат в NotificationsView) —
                    // убрана: на устройстве роняла контент заметно ниже, чем
                    // в Закладках/Каталоге, а не выравнивала с ними.
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            // Родной системный заголовок — Меню теперь наравне с остальными
            // главными вкладками (Закладки/Каталог/Читают/Уведомления):
            // .large, крупный заголовок без фона в покое, системный блюр
            // проявляется при скролле, схлопывается в маленький
            // центрированный — то же самое поведение, без своего
            // "схлопывания"/блюр-фейда вручную. Опасение, что при схлопывании
            // верх опустеет (у Меню, в отличие от Каталога/Закладок, нет
            // строки поиска) — не актуально: нативный .large ВСЕГДА
            // показывает хотя бы маленький заголовок, просто сжимается, а не
            // пропадает целиком.
            .navigationTitle("Меню")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MenuRoute.self) { route in
                switch route {
                case .history:    HistoryView(embedded: true)
                case .settings:   AppSettingsView(embedded: true)
                case .downloads:  DownloadsView(embedded: true)
                case .comments:   MyCommentsView(embedded: true)
                case .franchises: FranchiseListView()
                case .friends:    if let uid = auth.userId { FriendsView(userId: uid) }
                case .collections: CollectionsListView()
                case .myCollections: if let uid = auth.userId { UserCollectionsView(userId: uid) }
                case .teams:      DirectoryListView(kind: .team)
                case .characters: DirectoryListView(kind: .character)
                case .people:     DirectoryListView(kind: .people)
                case .publishers: DirectoryListView(kind: .publisher)
                case .users:      UserListView()
                case .nowReading: TopViewsListView()
                case .favorites:  if let uid = auth.userId { FavoritesListView(userId: uid) }
                // Совместный поиск/каталог СРАЗУ по всем включённым внешним
                // сайтам (см. ExternalCombinedCatalogView — уже умеет это
                // делать, использовалась раньше только через "Все сайты" в
                // развёрнутом siteRow, см. combinedCatalogBlock ниже) — по
                // прямой просьбе (31.08) отдельным, всегда видимым пунктом
                // в самом низу меню, не переключая при этом активный
                // сайт/режим приложения (это просто отдельный экран поиска,
                // не смена глобального состояния, как у siteRow).
                case .combinedCatalog: ExternalCombinedCatalogView()
                }
            }
        }
    }

    // MARK: Блоки (по группировке, которую попросили)

    // Блок 1: профиль (карточка входа/аккаунта) + "Сайт (MangaLib)" сразу под ним,
    // в той же карточке — это ровно то место, где на референсе было пустое
    // (отмеченное красным) пространство под первой строкой аккаунта.
    private var block1: some View {
        card {
            profileRow
            // iconWidth: 52 — тот же, что у круглой аватарки в profileRow (16
            // паддинг + 52 + 14 spacing = 82), поэтому текст "Сайт" выравнивается
            // ровно по тому месту, где начинается текст ника/"Аккаунт MangaLib"
            // в строке профиля.
            siteRow
        }
    }

    // Переключатель активного сайта (MangaLib/RanobeLib/HentaiLib/SlashLib) —
    // определяет Site-Id для каталога/закладок/истории/карточки тайтла (см.
    // MangaNetworkService.defaultHeaders, SiteSession.activeSite). Меню
    // (Menu) вместо перехода на отдельный экран — переключение это просто
    // выбор одного значения, отдельная страница избыточна. Один и тот же
    // аккаунт работает на всех сайтах экосистемы, так что перелогин при
    // переключении не требуется (общий Bearer-токен, см. LibSite.swift).
    private var siteRow: some View {
        VStack(spacing: 0) {
            // Шапка строки — тап разворачивает/сворачивает список сайтов вниз
            // (вместо всплывающего Menu), как в остальных списках меню.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { siteExpanded.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "globe")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 52)
                    Text("Сайт")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(externalSiteSession.combinedModeActive ? "Все сайты" : (externalSiteSession.activeExternalSite?.displayName ?? siteSession.activeSite.displayName))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: siteExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if siteExpanded {
                ForEach(LibSite.allCases) { site in
                    let isActive = externalSiteSession.activeExternalSite == nil && !externalSiteSession.combinedModeActive && site == siteSession.activeSite
                    Divider().overlay(Theme.separator)
                        .padding(.leading, 16 + 52 + 14).padding(.trailing, 16)
                    Button {
                        siteSession.activeSite = site
                        externalSiteSession.activeExternalSite = nil
                        externalSiteSession.combinedModeActive = false
                        withAnimation(.easeInOut(duration: 0.2)) { siteExpanded = false }
                    } label: {
                        siteOptionRow(title: site.displayName, isActive: isActive)
                    }
                    .buttonStyle(.plain)
                }

                // «Другие сайты» — включённые в Настройках (см.
                // ExternalSitesSettingsView) внешние сайты (сейчас hitomi.la,
                // дальше по мере разбора HAR), той же строкой в конце того
                // же списка — SiteSession/LibSite при этом не трогаются,
                // просто рядом появляется независимый переключатель (см.
                // ExternalSiteSession).
                ForEach(ExternalSite.allCases.filter { externalSiteSession.enabledSites.contains($0) }) { site in
                    let isActive = externalSiteSession.activeExternalSite == site
                    Divider().overlay(Theme.separator)
                        .padding(.leading, 16 + 52 + 14).padding(.trailing, 16)
                    Button {
                        externalSiteSession.activeExternalSite = site
                        externalSiteSession.combinedModeActive = false
                        withAnimation(.easeInOut(duration: 0.2)) { siteExpanded = false }
                    } label: {
                        siteOptionRow(title: site.displayName, isActive: isActive)
                    }
                    .buttonStyle(.plain)
                }

                // «Все сайты» — совместный каталог/выдача сразу по всем
                // включённым внешним сайтам (см. ExternalSiteSession.
                // combinedModeActive, ExternalCombinedCatalogView). Имеет
                // смысл только когда включено 2+ — с одним это просто то же
                // самое, что и выбор этого одного сайта выше.
                if externalSiteSession.enabledSites.count >= 2 {
                    let isActive = externalSiteSession.combinedModeActive
                    Divider().overlay(Theme.separator)
                        .padding(.leading, 16 + 52 + 14).padding(.trailing, 16)
                    Button {
                        externalSiteSession.activeExternalSite = nil
                        externalSiteSession.combinedModeActive = true
                        withAnimation(.easeInOut(duration: 0.2)) { siteExpanded = false }
                    } label: {
                        siteOptionRow(title: "Все сайты", isActive: isActive)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Одна строка в развёрнутом списке выбора сайта — общая для LibSite и
    /// ExternalSite (см. siteRow выше).
    private func siteOptionRow(title: String, isActive: Bool) -> some View {
        HStack(spacing: 14) {
            // Пустая колонка шириной иконки — чтобы название выровнялось
            // под «Сайт» выше.
            Color.clear.frame(width: 52)
            Text(title)
                .foregroundStyle(isActive ? Theme.accent : Theme.textPrimary)
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    // Быстрый блок БЕЗ заголовка подложки: Настройки, История, Загрузки — все
    // с реальными действиями (открываются ПОВЕРХ меню).
    private var quickBlock: some View {
        card {
            row("Настройки", icon: "gearshape", action: { path.append(MenuRoute.settings) })
            row("История", icon: "clock.arrow.circlepath", action: { path.append(MenuRoute.history) })
            row("Загрузки", icon: "arrow.down.circle", showDivider: false, action: { path.append(MenuRoute.downloads) })
        }
    }

    // Сворачиваемый раздел «Профиль» — все пункты пока заглушки (StubView).
    private var profileSection: some View {
        collapsibleCard("Профиль") {
            row("Комментарии", icon: "text.bubble", action: { path.append(MenuRoute.comments) })
            // Раньше вела на StubView (заглушку) — реальный экран друзей
            // (FriendsView) давно есть в профиле, просто не был подключён
            // здесь. Без аккаунта своих друзей нет — как и остальные
            // персональные пункты, ведёт на вход вместо пустого экрана.
            row("Список друзей", icon: "person.2", action: {
                if auth.userId != nil { path.append(MenuRoute.friends) } else { onOpenLogin() }
            })
            row("Избранное", icon: "heart", action: {
                if auth.userId != nil { path.append(MenuRoute.favorites) } else { onOpenLogin() }
            })
            // Раньше вела на StubView — реальный экран (UserCollectionsView,
            // "мои коллекции") давно есть в профиле, просто не был
            // подключён здесь (в отличие от Каталог → Коллекции — та уже
            // вела на общую ленту CollectionsListView).
            row("Коллекции", icon: "square.stack", action: {
                if auth.userId != nil { path.append(MenuRoute.myCollections) } else { onOpenLogin() }
            })
            row("Игнор-лист", icon: "hand.raised")
            row("История банов", icon: "nosign", showDivider: false)
        }
    }

    // Сворачиваемый раздел «Каталог». Особый: у «Тайтлы» стрелка вправо, тап по
    // ней ЗАМЕНЯЕТ содержимое подложки на под-экран выбора типа (см.
    // catalogTypesView). Остальные пункты — заглушки.
    private var catalogSection: some View {
        let expanded = expandedSections.contains("Каталог")
        return card {
            sectionHeader("Каталог", expanded: expanded)
            if expanded {
                sectionDivider
                if catalogShowingTypes {
                    catalogTypesView
                } else {
                    catalogRootRows
                }
            }
        }
    }

    @ViewBuilder
    private var catalogRootRows: some View {
        // Внешний сайт активен (см. ExternalSiteSession) — обычные пункты
        // каталога MangaLib здесь не при чём (Команды/Персонажи/Франшизы и
        // т.д. — это сущности ИМЕННО экосистемы Lib). Список тегов/поиск
        // теперь живут СВОЕЙ менюшкой прямо во вкладке «Каталог» (см.
        // ExternalCatalogMenuView/ExternalCombinedCatalogView) — здесь
        // просто указатель, без дублирующего пункта.
        if externalSiteSession.isExternalModeActive {
            row("Каталог — во вкладке «Каталог»", icon: "square.grid.2x2", showDivider: false, showChevron: false)
        } else {
            VStack(spacing: 0) {
                row("Тайтлы", icon: "book", action: {
                    withAnimation(.easeInOut(duration: 0.2)) { catalogShowingTypes = true }
                })
                row("Сейчас читают", icon: "flame", action: { path.append(MenuRoute.nowReading) })
                row("Коллекции", icon: "square.stack", action: { path.append(MenuRoute.collections) })
                row("Команды", icon: "person.3", action: { path.append(MenuRoute.teams) })
                row("Люди", icon: "person.crop.rectangle", action: { path.append(MenuRoute.people) })
                row("Персонажи", icon: "face.smiling", action: { path.append(MenuRoute.characters) })
                row("Франшизы", icon: "sparkles", action: { path.append(MenuRoute.franchises) })
                row("Издательства", icon: "building.2", action: { path.append(MenuRoute.publishers) })
                row("Пользователи", icon: "person.crop.circle", showDivider: false, action: { path.append(MenuRoute.users) })
            }
        }
    }

    // Под-экран выбора типа тайтла — заменяет обычный список раздела «Каталог».
    // Сверху «Назад» (над «Манга»), затем типы по центру, внизу оранжевая
    // кнопка «Случайный тайтл». Тап по типу открывает Каталог с этим фильтром.
    private var catalogTypesView: some View {
        VStack(spacing: 0) {
            // «Назад» той же строкой-шаблоном (row), что и остальные пункты
            // меню — та же высота (52) и тот же размер текста/иконки, поэтому
            // при открытии «Тайтлы» ничего не смещается вниз.
            row("Назад", icon: "chevron.left", showChevron: false, action: {
                withAnimation(.easeInOut(duration: 0.2)) { catalogShowingTypes = false }
            })

            catalogTypeRow("Манга", typeId: 1)
            catalogTypeRow("ОЭЛ манга", typeId: 4)
            catalogTypeRow("Манхва", typeId: 5)
            catalogTypeRow("Руманга", typeId: 8)
            catalogTypeRow("Комикс", typeId: 9, showDivider: false)

            Button {
                // ЗАГЛУШКА: случайный тайтл.
                select("Случайный тайтл")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dice.fill")
                    Text("Случайный тайтл").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    // Строка типа тайтла — название СЛЕВА (как попросили). Тап закрывает
    // под-экран и открывает Каталог с фильтром по этому типу (id из
    // FilterCatalog.types).
    private func catalogTypeRow(_ title: String, typeId: Int, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            Button {
                catalogShowingTypes = false
                onOpenCatalog(typeId)
            } label: {
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.horizontal, 16)
            }
        }
    }

    // Сворачиваемый раздел «Другое».
    private var otherSection: some View {
        collapsibleCard("Другое") {
            row("Вопросы и ответы", icon: "questionmark.circle", showDivider: false)
        }
    }

    // MARK: Сворачиваемая подложка (заголовок со стрелкой вверх/вниз + контент)

    private func collapsibleCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        let expanded = expandedSections.contains(title)
        return card {
            sectionHeader(title, expanded: expanded)
            if expanded {
                sectionDivider
                content()
            }
        }
    }

    private func sectionHeader(_ title: String, expanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expanded {
                    expandedSections.remove(title)
                    // Сворачивая «Каталог», сбрасываем под-экран типов, чтобы при
                    // следующем раскрытии снова показывался обычный список.
                    if title == "Каталог" { catalogShowingTypes = false }
                } else {
                    expandedSections.insert(title)
                }
            }
        } label: {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sectionDivider: some View {
        Divider().overlay(Theme.separator).padding(.horizontal, 16)
    }

    // Блок 4 (в самом низу): чекбоксы всех сайтов экосистемы, КРОМЕ AnimeLib
    // (он сознательно не входит в LibSite — отдельная история с видео, не
    // текст/картинки), для поиска СРАЗУ по нескольким сайтам одновременно, вне
    // зависимости от того, какой сайт сейчас активен (см. SiteSession.searchSites/
    // effectiveSearchSites, использовано в MangaNetworkService.searchManga/fetchCatalog).
    // Активный сайт всегда участвует в поиске (effectiveSearchSites сама его
    // добавляет), поэтому его чекбокс показан всегда отмеченным и недоступным
    // для снятия — снять его можно только сменив активный сайт выше.
    private var searchSitesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Искать также на")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)

            card {
                ForEach(LibSite.allCases) { site in
                    searchSiteRow(site, showDivider: site != LibSite.allCases.last)
                }
            }
        }
    }

    private func searchSiteRow(_ site: LibSite, showDivider: Bool) -> some View {
        let isActive = site == siteSession.activeSite
        let isChecked = isActive || siteSession.searchSites.contains(site)

        return VStack(spacing: 0) {
            Button {
                guard !isActive else { return } // активный сайт всегда включён, тап игнорируем
                if siteSession.searchSites.contains(site) {
                    siteSession.searchSites.remove(site)
                } else {
                    siteSession.searchSites.insert(site)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isChecked ? Theme.accent : Theme.textSecondary)
                        .frame(width: 24)
                    Text(site.displayName)
                        .foregroundStyle(isActive ? Theme.textSecondary : Theme.textPrimary)
                    if isActive {
                        Text("активный")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isActive)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14).padding(.trailing, 16)
            }
        }
    }

    // Блок «Отдельные сайты» — самый низ меню, по прямой просьбе. Чекбоксы —
    // ТО ЖЕ САМОЕ состояние, что и в Настройки → «Другие сайты» (см.
    // ExternalSitesSettingsView, ExternalSiteSession.enabledSites) — просто
    // ещё один способ его редактировать, без похода в Настройки. Тот же
    // визуальный приём (чекбокс-квадратик), что и у searchSitesBlock выше,
    // но это ДВА разных, не связанных друг с другом понятия: там — LibSite
    // (mangalib/slashlib/...), здесь — ExternalSite (hitomi/e-hentai/...).
    private var externalSitesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Отдельные сайты")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)

            card {
                ForEach(Array(ExternalSite.allCases.enumerated()), id: \.element) { index, site in
                    externalSiteCheckboxRow(site, showDivider: index != ExternalSite.allCases.count - 1)
                }
            }
        }
    }

    private func externalSiteCheckboxRow(_ site: ExternalSite, showDivider: Bool) -> some View {
        let isChecked = externalSiteSession.enabledSites.contains(site)

        return VStack(spacing: 0) {
            Button {
                if isChecked {
                    externalSiteSession.enabledSites.remove(site)
                    // Выключили сайт, который был активным/участвовал в
                    // совместном режиме — тот же принцип отката, что и в
                    // ExternalSitesSettingsView.siteRow.
                    if externalSiteSession.activeExternalSite == site { externalSiteSession.activeExternalSite = nil }
                    if externalSiteSession.enabledSites.isEmpty { externalSiteSession.combinedModeActive = false }
                } else {
                    externalSiteSession.enabledSites.insert(site)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isChecked ? Theme.accent : Theme.textSecondary)
                        .frame(width: 24)
                    Text(site.displayName)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14).padding(.trailing, 16)
            }
        }
    }

    // Совместный каталог/поиск СРАЗУ по всем включённым внешним сайтам
    // (см. ExternalCombinedCatalogView) — по прямой просьбе (31.08),
    // отдельный ВСЕГДА видимый пункт в самом низу меню (не только внутри
    // развёрнутого siteRow под "Все сайты", и не гейтится числом включённых
    // сайтов — тот вариант это переключатель ГЛОБАЛЬНОГО активного режима
    // приложения, этот — просто отдельный экран поиска, открывается
    // ПОВЕРХ текущего режима, ничего не переключая). С 0 включёнными
    // сайтами экран честно покажет "Тайтлов не найдено" — тот же принцип,
    // что и у searchSitesBlock/externalSitesBlock выше (без искусственного
    // скрытия строки).
    private var combinedCatalogBlock: some View {
        card {
            row("Совместный каталог", icon: "square.grid.3x3", showDivider: false, action: { path.append(MenuRoute.combinedCatalog) })
        }
    }

    // MARK: Карточка-контейнер

    // Радиус вынесен в константу — тот же самый радиус используется и для
    // самого листа меню (.presentationCornerRadius в RootView.swift), чтобы
    // скругления совпадали, как просили. 20→24 — чуть крупнее.
    static let cardCornerRadius: CGFloat = 24

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
    }

    // MARK: Карточка профиля (верх блока 1)

    // Тап по всей строке: если не залогинен — ведёт на "Войти" (LoginView,
    // реальный WebView-логин на mangalib.me); если залогинен — на экран
    // информации об аккаунте (AccountInfoView). Маршрутизация — в RootView.swift.
    // Кнопки "Активировать код"/"Отправить подарочную карту" с референса
    // сознательно не переносим — просили без них.
    private var profileRow: some View {
        VStack(spacing: 0) {
            Button {
                // Теперь общие closures с быстрой кнопкой профиля в RootView —
                // одна и та же sheet-презентация, откуда бы её ни открыли.
                if auth.isLoggedIn { onOpenAccount() } else { onOpenLogin() }
            } label: {
                HStack(spacing: 14) {
                    avatarView

                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.isLoggedIn ? (auth.username ?? "Аккаунт MangaLib") : "Вы не вошли")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        // В 2 строки (lineLimit 2) — не входила бы: одна длинная строка.
                        Text(auth.isLoggedIn ? "Посмотреть информацию об аккаунте" : "Войдите, чтобы посмотреть информацию об аккаунте")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    // Текст "Залогиниться" убрали — избыточен, вся строка и так
                    // тап-таргет на вход. Шеврон остаётся в обоих состояниях.
                    chevron
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Разделитель начинается там же, где текст (16 паддинг + 52
            // аватар + 14 spacing = 82), и не доходит до конца карточки
            // (trailing 16) — раньше шёл во всю ширину до самого края.
            Divider().overlay(Theme.separator).padding(.leading, 82).padding(.trailing, 16)
        }
    }

    // Круглая аватарка аккаунта: реальная картинка с сервера (auth.avatarURL,
    // подтягивается в AuthSession.refreshProfile через /auth/me), пока грузится
    // или если не залогинен — иконка-заглушка. RemoteImage — тот же кастомный
    // загрузчик с заголовками, что и для обложек манги (обычный AsyncImage
    // без Referer/User-Agent тут тоже может словить 403).
    private var avatarView: some View {
        Group {
            if let avatarURL = auth.avatarURL {
                RemoteImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderAvatar
                }
            } else {
                placeholderAvatar
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(Theme.surface)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
            )
    }

    // Шеврон чуть крупнее (caption→subheadline) и один и тот же везде —
    // в profileRow и в обычных row() используется этот же вычисляемый вью,
    // так что положение и размер гарантированно совпадают во всех блоках.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
    }

    // MARK: Обычная строка внутри карточки

    // iconWidth позволяет выровнять текст строки по чужому ориентиру (см.
    // "Сайт (MangaLib)" в block1, где он выравнивается по тексту profileRow).
    // action — переопределяет поведение по тапу (по умолчанию — select(title),
    // закрывает меню и уходит на StubView); используется, когда строка должна
    // открыть что-то ПОВЕРХ меню, не закрывая его (см. "История").
    private func row(_ title: String, icon: String, showDivider: Bool = true, showChevron: Bool = true, iconWidth: CGFloat = 24, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            Button { (action ?? { select(title) })() } label: {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: iconWidth)
                    Text(title)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if showChevron { chevron }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDivider {
                // Начало текста = 16 паддинг + iconWidth + 14 spacing;
                // trailing 16 — чтобы не доходил до конца карточки.
                Divider().overlay(Theme.separator).padding(.leading, 16 + iconWidth + 14).padding(.trailing, 16)
            }
        }
    }

    // MARK: Действия

    private func select(_ title: String) {
        onSelect(title)
    }
}

#Preview {
    SideMenuView(onSelect: { _ in }, onOpenLogin: {}, onOpenAccount: {}, onOpenCatalog: { _ in })
        .preferredColorScheme(.dark)
}
