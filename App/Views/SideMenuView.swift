import SwiftUI

/// Пункт-заглушка, на который ведут элементы меню.
struct StubView: View {
    let title: String
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ContentUnavailableView(
                title,
                systemImage: "hammer",
                description: Text("Раздел в разработке.")
            )
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

    // История по-прежнему свой локальный sheet прямо здесь — быстрая кнопка
    // профиля её не касается, поэтому не нужно поднимать выше в RootView.
    @State private var showHistory = false
    // Настройки — раньше вели на generic-заглушку StubView, теперь реальный
    // экран (см. AppSettingsView.swift) с версией приложения. Открывается
    // ПОВЕРХ меню, как и История, а не через select(title).
    @State private var showSettings = false
    // Загрузки — реальный экран со списком скачанных тайтлов (см. DownloadsView),
    // открывается ПОВЕРХ меню, как История/Настройки.
    @State private var showDownloads = false

    // Какие сворачиваемые разделы сейчас развёрнуты (Профиль/Каталог/Другое) —
    // у каждого своя стрелка вверх/вниз в заголовке подложки. По умолчанию все
    // развёрнуты.
    @State private var expandedSections: Set<String> = ["Профиль", "Каталог", "Другое"]
    // Внутри раздела «Каталог»: показывается ли под-экран выбора типа тайтла
    // (Манга/ОЭЛ манга/…), заменяющий обычный список раздела (см. catalogSection).
    @State private var catalogShowingTypes = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    // Блоки-карточки с отступами между ними — как на референсе
                    // (лист аккаунта Apple): каждая логическая группа пунктов —
                    // отдельная закруглённая карточка, между карточками зазор.
                    // spacing 28→34 — чуть больше воздуха между блоками.
                    VStack(spacing: 34) {
                        block1
                        quickBlock
                        profileSection
                        catalogSection
                        otherSection
                        searchSitesBlock
                    }
                    .padding(.horizontal, 16)
                    // 8→22 — больше отступ профиля (верх блока 1) от надписи
                    // "Меню" в шапке.
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView().preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView().preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView()
        }
    }

    // MARK: Шапка

    private var header: some View {
        // Кнопку-крестик убрали — меню теперь обычная вкладка (не sheet),
        // закрывать/сворачивать её через "крестик" незачем: переключение на
        // другой раздел происходит через нижнюю панель, как и у любой другой вкладки.
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            Text("Меню")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
        Menu {
            ForEach(LibSite.allCases) { site in
                Button {
                    siteSession.activeSite = site
                } label: {
                    if site == siteSession.activeSite {
                        Label(site.displayName, systemImage: "checkmark")
                    } else {
                        Text(site.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 52)
                Text("Сайт")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(siteSession.activeSite.displayName)
                    .foregroundStyle(Theme.textSecondary)
                chevron
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Быстрый блок БЕЗ заголовка подложки: Настройки, История, Загрузки — все
    // с реальными действиями (открываются ПОВЕРХ меню).
    private var quickBlock: some View {
        card {
            row("Настройки", icon: "gearshape", action: { showSettings = true })
            row("История", icon: "clock.arrow.circlepath", action: { showHistory = true })
            row("Загрузки", icon: "arrow.down.circle", showDivider: false, action: { showDownloads = true })
        }
    }

    // Сворачиваемый раздел «Профиль» — все пункты пока заглушки (StubView).
    private var profileSection: some View {
        collapsibleCard("Профиль") {
            row("Комментарии", icon: "text.bubble")
            row("Список друзей", icon: "person.2")
            row("Избранное", icon: "heart")
            row("Коллекции", icon: "square.stack")
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

    private var catalogRootRows: some View {
        VStack(spacing: 0) {
            row("Тайтлы", icon: "book", action: {
                withAnimation(.easeInOut(duration: 0.2)) { catalogShowingTypes = true }
            })
            row("Сейчас читают", icon: "flame")
            row("Коллекции", icon: "square.stack")
            row("Команды", icon: "person.3")
            row("Люди", icon: "person.crop.rectangle")
            row("Персонажи", icon: "face.smiling")
            row("Франшизы", icon: "sparkles")
            row("Издательства", icon: "building.2")
            row("Пользователи", icon: "person.crop.circle", showDivider: false)
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

    // Строка типа тайтла — название ПО ЦЕНТРУ (как попросили). Тап закрывает
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
                    .frame(maxWidth: .infinity, alignment: .center)
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
