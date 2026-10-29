import SwiftUI

/// Placeholder destination for unfinished menu entries.
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

/// The menu content is presented by RootView; presentation and dismissal belong to its navigation container.
struct SideMenuView: View {

    /// Open the selected placeholder section.
    var onSelect: (String) -> Void
    /// Open the shared login presentation owned by RootView.
    var onOpenLogin: () -> Void
    /// Open the shared account information screen.
    var onOpenAccount: () -> Void
    /// Open the catalog with the selected title type.
    var onOpenCatalog: (Int) -> Void

    // Observe the authentication session to update the account row after sign-in.
    @ObservedObject private var auth = AuthSession.shared

    // Observe the active Lib site and its multi-site search selection.
    @ObservedObject private var siteSession = SiteSession.shared
    /// External sources have their own session and settings, independent of Lib sites.
    @ObservedObject private var externalSiteSession = ExternalSiteSession.shared

    @ObservedObject private var themeManager = ThemeManager.shared

    // History, settings and downloads use push navigation inside the menu tab, preserving its tab bar.
    private enum MenuRoute: Hashable {
        case history, settings, downloads, comments, franchises, friends, collections, myCollections
        case teams, characters, people, publishers, users, nowReading, favorites, combinedCatalog
    }
    // Use an untyped NavigationPath so nested destinations can push their own value types.
    @State private var path = NavigationPath()

    // Expandable menu groups start expanded.
    @State private var expandedSections: Set<String> = ["Профиль", "Каталог", "Другое"]
    // The catalog group can replace its entries with the title-type picker.
    @State private var catalogShowingTypes = false
    // Whether the Lib-site picker is expanded.
    @State private var siteExpanded = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    // Separate rounded cards with the requested 34-point spacing.
                    VStack(spacing: 34) {
                        block1
                        quickBlock
                        profileSection
                        catalogSection
                        otherSection
                        searchSitesBlock
                        combinedCatalogBlock
                    }
                    .padding(.horizontal, 16)
                    // Align the top inset with the other main tabs.
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            // Use the native large navigation title and its system scroll transition.
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
                // Open the combined external catalog without changing the selected Lib site.
                case .combinedCatalog: ExternalCombinedCatalogView()
                }
            }
        }
    }

    // MARK: Menu groups

    // Keep the account and active-site rows in the same card.
    private var block1: some View {
        card {
            profileRow
            // Align the site text with the account text using the avatar column width.
            siteRow
        }
    }

    // Select the active Lib site without signing out; Lib sites share one account token.
    private var siteRow: some View {
        VStack(spacing: 0) {
            // Expand the site list inline instead of presenting another menu.
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
                    // Display the active external content kind, while offering only Lib sites in this picker. External sources are managed in Settings.
                    Text(externalSiteSession.isExternalModeActive ? externalSiteSession.contentKind.title : siteSession.activeSite.displayName)
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
                // External source participation is controlled only in Settings.
            }
        }
    }

    /// A site option aligned with the icon column of its parent row.
    private func siteOptionRow(title: String, isActive: Bool, iconWidth: CGFloat = 52) -> some View {
        HStack(spacing: 14) {
            // Reserve the icon column so the label aligns with the heading above.
            Color.clear.frame(width: iconWidth)
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

    // Quick navigation to settings, history and downloads.
    private var quickBlock: some View {
        card {
            row("Настройки", icon: "gearshape", action: { path.append(MenuRoute.settings) })
            row("История", icon: "clock.arrow.circlepath", action: { path.append(MenuRoute.history) })
            row("Загрузки", icon: "arrow.down.circle", showDivider: false, action: { path.append(MenuRoute.downloads) })
        }
    }

    // Expandable profile shortcuts.
    private var profileSection: some View {
        collapsibleCard("Профиль") {
            row("Комментарии", icon: "text.bubble", action: { path.append(MenuRoute.comments) })
            // Open the existing friends screen, requesting sign-in when needed.
            row("Список друзей", icon: "person.2", action: {
                if auth.userId != nil { path.append(MenuRoute.friends) } else { onOpenLogin() }
            })
            row("Избранное", icon: "heart", action: {
                if auth.userId != nil { path.append(MenuRoute.favorites) } else { onOpenLogin() }
            })
            // Open the existing personal collections screen.
            row("Коллекции", icon: "square.stack", action: {
                if auth.userId != nil { path.append(MenuRoute.myCollections) } else { onOpenLogin() }
            })
            row("Игнор-лист", icon: "hand.raised")
            row("История банов", icon: "nosign", showDivider: false)
        }
    }

    // The Lib catalog group is hidden in external mode because its directories belong to the Lib ecosystem.
    @ViewBuilder
    private var catalogSection: some View {
        if !externalSiteSession.isExternalModeActive {
            let expanded = expandedSections.contains("Каталог")
            card {
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
    }

    private var catalogRootRows: some View {
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

    // The title-type picker replaces the catalog group and offers a back row and random-title shortcut.
    private var catalogTypesView: some View {
        VStack(spacing: 0) {
            // Use the standard row height to avoid shifting the group when opening the picker.
            row("Назад", icon: "chevron.left", showChevron: false, action: {
                withAnimation(.easeInOut(duration: 0.2)) { catalogShowingTypes = false }
            })

            catalogTypeRow("Манга", typeId: 1)
            catalogTypeRow("ОЭЛ манга", typeId: 4)
            catalogTypeRow("Манхва", typeId: 5)
            catalogTypeRow("Руманга", typeId: 8)
            catalogTypeRow("Комикс", typeId: 9, showDivider: false)

            Button {
                // Placeholder random-title action.
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

    // Select a title type and open the catalog using its ConstantsStore identifier.
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

    // Expandable miscellaneous shortcuts.
    private var otherSection: some View {
        collapsibleCard("Другое") {
            row("Вопросы и ответы", icon: "questionmark.circle", showDivider: false)
        }
    }

    // MARK: Expandable section container

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
                    // Reset the title-type subview when collapsing the catalog group.
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

    // Lib multi-site search always includes the active site; change that site before disabling its search participation.
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
                guard !isActive else { return } // The active Lib site is always included.
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


    // Open combined external search using the enabled sources and selected content kind, including an empty state when none are enabled.
    private var combinedCatalogBlock: some View {
        card {
            row("Совместный каталог", icon: "square.grid.3x3", showDivider: false, action: { path.append(MenuRoute.combinedCatalog) })
        }
    }

    // MARK: Card container

    // Share the menu card corner radius with its presentation container.
    static let cardCornerRadius: CGFloat = 24

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
    }

    // MARK: Account card

    // Open shared login or account information by tapping the account row.
    private var profileRow: some View {
        VStack(spacing: 0) {
            Button {
                // Reuse the RootView presentation callbacks.
                if auth.isLoggedIn { onOpenAccount() } else { onOpenLogin() }
            } label: {
                HStack(spacing: 14) {
                    avatarView

                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.isLoggedIn ? (auth.username ?? "Аккаунт MangaLib") : "Вы не вошли")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        // Allow two lines for long account labels.
                        Text(auth.isLoggedIn ? "Посмотреть информацию об аккаунте" : "Войдите, чтобы посмотреть информацию об аккаунте")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    // The whole account row is the sign-in target, so no redundant login subtitle is needed.
                    chevron
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Inset the divider to align with the text column.
            Divider().overlay(Theme.separator).padding(.leading, 82).padding(.trailing, 16)
        }
    }

    // Use the authenticated image loader for the avatar and a placeholder until available.
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

    // Reuse the same chevron style for account and ordinary rows.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
    }

    // MARK: Standard card row

    // Allow custom icon-column widths and actions while preserving the shared row layout.
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
                // Align the divider with the text and keep a trailing inset.
                Divider().overlay(Theme.separator).padding(.leading, 16 + iconWidth + 14).padding(.trailing, 16)
            }
        }
    }

    // MARK: Actions

    private func select(_ title: String) {
        onSelect(title)
    }
}

#Preview {
    SideMenuView(onSelect: { _ in }, onOpenLogin: {}, onOpenAccount: {}, onOpenCatalog: { _ in })
        .preferredColorScheme(.dark)
}
