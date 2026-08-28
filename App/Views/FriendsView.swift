import SwiftUI

/// Вкладка «Друзья» в профиле пользователя: список друзей и общие друзья,
/// переключаются двумя кнопками снизу («Список друзей» / «Общие друзья»).
/// Строка — аватар (квадрат со скруглениями), ник, дата дружбы под ником.
/// Данные: GET /friendship?user_id=&status=1 и GET /friendship/{id}/mutual.
struct FriendsView: View {
    let userId: Int
    /// false — встроен в ProfileView без своей шапки (см.
    /// UserBookmarksView.showsOwnHeader).
    var showsOwnHeader: Bool = true

    @StateObject private var vm: FriendsViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var profileUser: ProfileUserId?
    @FocusState private var searchFocused: Bool

    init(userId: Int, showsOwnHeader: Bool = true) {
        self.userId = userId
        self.showsOwnHeader = showsOwnHeader
        _vm = StateObject(wrappedValue: FriendsViewModel(userId: userId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                // Больше отступ снизу поля поиска (был только сверху,
                // список начинался сразу под ним) — по прямой просьбе.
                if vm.tab != .mutual { searchField.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12) }
                content
            }
        }
        // showsOwnHeader — обычный push (не встроен в профиль): родной
        // системный заголовок + системный back chevron, никакого своего
        // кода (эталон — Настройки/Загрузки). Без него — навбар скрыт,
        // шапку рисует ProfileView.topBar (см. AccountInfoView).
        .navigationTitle("Друзья")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsOwnHeader ? .visible : .hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        // Входящие грузим сразу же (не только по тапу на таб) — иначе
        // бейдж-счётчик на "Входящие" (см. tabBar) до первого открытия
        // таба всегда показывал бы 0, даже если заявки реально есть.
        .task {
            async let current: Void = vm.loadIfNeeded()
            async let incoming: Void = vm.isOwnAccount ? vm.prefetchIncomingCount() : ()
            _ = await (current, incoming)
        }
        .sheet(item: $profileUser) { pu in
            ProfileView(userId: pu.id).preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
        }
    }

    /// "Поиск по имени" — ПОДТВЕРЖДЕНО перехватом `&q=` на реальном сайте
    /// (см. FriendsViewModel.query/MangaNetworkService.fetchFriends). НЕ
    /// показывается на табе "Общие" — там q не подтверждён.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("", text: $vm.query,
                      prompt: Text("Поиск по имени").foregroundColor(Theme.textSecondary))
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

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.visible.isEmpty {
            skeletonList
        } else if let error = vm.errorMessage, vm.visible.isEmpty {
            // ScrollView (не голый VStack) — иначе .refreshable ниже не от
            // чего было бы тянуть, свайп-обновление работало бы только
            // когда список уже не пуст.
            // containerRelativeFrame — иначе Spacer() внутри emptyState не
            // от чего было бы центрироваться (ScrollView сам не задаёт
            // высоту контенту, только скроллит его).
            ScrollView { emptyState(icon: "wifi.exclamationmark", text: error).containerRelativeFrame(.vertical) }
                .scrollIndicators(.hidden)
                .refreshable { await vm.refreshCurrentTab() }
        } else if vm.visible.isEmpty && vm.didLoadCurrent {
            ScrollView { emptyState(icon: emptyIcon, text: emptyText).containerRelativeFrame(.vertical) }
                .scrollIndicators(.hidden)
                .refreshable { await vm.refreshCurrentTab() }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if vm.tab == .incoming { acceptAllButton }
                    ForEach(vm.visible) { entry in
                        friendRow(entry)
                            .onAppear { Task { await vm.loadMoreIfNeeded(current: entry) } }
                    }
                    if vm.isLoadingMore {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                // Тот же эталон отступов, что и в "Уведомления" (см.
                // NotificationsView.list) — по прямой просьбе.
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .refreshable { await vm.refreshCurrentTab() }
        }
    }

    private var emptyIcon: String {
        switch vm.tab {
        case .friends, .mutual: return "person.2"
        case .incoming, .outgoing: return "person.crop.circle.badge.questionmark"
        }
    }

    private var emptyText: String {
        if !vm.query.isEmpty { return "Никого не нашлось" }
        switch vm.tab {
        case .friends:  return "Друзей пока нет"
        case .mutual:   return "Общих друзей нет"
        case .incoming: return "Заявок в друзья нет"
        case .outgoing: return "Отправленных запросов нет"
        }
    }

    /// "Принять все" — см. FriendsViewModel.acceptAll (PUT /friendship/bulk).
    @ViewBuilder
    private var acceptAllButton: some View {
        if !vm.incoming.isEmpty {
            Button {
                Task { await vm.acceptAll() }
            } label: {
                HStack(spacing: 6) {
                    if vm.isAcceptingAll {
                        ProgressView().tint(Theme.background).controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text("Принять все")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(vm.isAcceptingAll)
        }
    }

    /// Скругление подложки-строки — 16, как в разделе "Уведомления" (см.
    /// NotificationsView.row) — по прямой просьбе привести к тому же
    /// эталону (было 24). Аватар заподлицо с подложкой (без внутреннего
    /// паддинга, высота строки = высоте аватара) — тот же приём и тот же
    /// радиус "угол в угол", что и у NotificationsView.row/BookmarksView.row.
    static let cardCornerRadius: CGFloat = 16
    static let avatarSize: CGFloat = 60

    /// Скелетон на первую загрузку — по прямой просьбе, вместо голого
    /// спиннера. Форма строки повторяет friendRow ниже.
    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in friendSkeletonRow }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }

    private var friendSkeletonRow: some View {
        HStack(spacing: 12) {
            SkeletonBox()
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBar(width: 130)
                SkeletonBar(width: 80, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 12)
        .frame(height: Self.avatarSize)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
    }

    private func friendRow(_ entry: FriendshipEntry) -> some View {
        let isResponding = vm.respondingIds.contains(entry.id)
        return HStack(spacing: 12) {
            Button {
                profileUser = ProfileUserId(id: entry.user.id)
            } label: {
                HStack(spacing: 12) {
                    RemoteImage(url: entry.user.avatarURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
                    } failure: {
                        ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
                    }
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                    .clipped()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.user.username)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let date = entry.createdAt {
                            Text(date.relativeRussianString)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            friendRowTrailing(entry, isResponding: isResponding)
        }
        .padding(.trailing, 12)
        .frame(height: Self.avatarSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
    }

    /// Хвост строки — обычный chevron у "Друзья"/"Общие", а у "Заявки в
    /// друзья"/"Отправленные запросы" реальные действия (см.
    /// FriendsViewModel.respond/cancelOutgoing) вместо просто перехода в профиль.
    @ViewBuilder
    private func friendRowTrailing(_ entry: FriendshipEntry, isResponding: Bool) -> some View {
        switch vm.tab {
        case .friends, .mutual:
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        case .incoming:
            if isResponding {
                ProgressView().tint(Theme.textSecondary).controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button { Task { await vm.respond(to: entry, accept: false) } } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Button { Task { await vm.respond(to: entry, accept: true) } } label: {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .outgoing:
            if isResponding {
                ProgressView().tint(Theme.textSecondary).controlSize(.small)
            } else {
                Button { Task { await vm.cancelOutgoing(entry) } } label: {
                    Text("Отменить")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: Нижние кнопки-табы

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                tabButton("Список друзей", tab: .friends)
                // На СВОЁМ профиле (см. FriendsViewModel.isOwnAccount) —
                // заявки вместо "Общие друзья": общих друзей с самим собой
                // не бывает, а входящие/исходящие заявки — как раз наоборот,
                // видны ТОЛЬКО на своём (сервер чужие и не отдаст). По
                // прямой просьбе "Общие друзья" на своём профиле убраны.
                if vm.isOwnAccount {
                    tabButton("Заявки в друзья", tab: .incoming, badge: vm.incoming.count)
                    tabButton("Отправленные запросы", tab: .outgoing)
                } else {
                    tabButton("Общие друзья", tab: .mutual)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func tabButton(_ title: String, tab: FriendsViewModel.Tab, badge: Int = 0) -> some View {
        let active = vm.tab == tab
        return Button {
            vm.selectTab(tab)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(active ? Theme.accent : Theme.background)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(active ? Theme.background : Theme.accent, in: Circle())
                }
            }
            .font(.footnote.weight(active ? .semibold : .medium))
            .foregroundStyle(active ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.pillControlHeight)
            .glassEffect(active ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FriendsView(userId: 1).preferredColorScheme(.dark)
}
