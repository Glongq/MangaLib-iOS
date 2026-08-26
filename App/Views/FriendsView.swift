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
    @Environment(\.dismiss) private var dismiss
    @State private var profileUser: ProfileUserId?

    init(userId: Int, showsOwnHeader: Bool = true) {
        self.userId = userId
        self.showsOwnHeader = showsOwnHeader
        _vm = StateObject(wrappedValue: FriendsViewModel(userId: userId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if showsOwnHeader { header }
                content
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .task { await vm.loadIfNeeded() }
        .sheet(item: $profileUser) { pu in
            ProfileView(userId: pu.id).preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
        }
    }

    // MARK: Шапка

    /// Позиция кнопки "назад" и заголовка — та же, что и в шапке "Профиль"
    /// (см. AccountInfoView.header: padding.top 14) — раньше здесь было 8.
    private var header: some View {
        ZStack {
            Text("Друзья").font(.headline).foregroundStyle(Theme.textPrimary)
            HStack {
                backButton
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .fadeInOnAppear()
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.visible.isEmpty {
            skeletonList
        } else if let error = vm.errorMessage, vm.visible.isEmpty {
            emptyState(icon: "wifi.exclamationmark", text: error)
        } else if vm.visible.isEmpty && vm.didLoadCurrent {
            emptyState(icon: "person.2", text: vm.tab == .friends ? "Друзей пока нет" : "Общих друзей нет")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.visible) { entry in
                        friendRow(entry)
                            .onAppear { Task { await vm.loadMoreIfNeeded(current: entry) } }
                    }
                    if vm.isLoadingMore {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Скелетон на первую загрузку — по прямой просьбе, вместо голого
    /// спиннера. Форма строки повторяет friendRow ниже (аватар 52×52 +
    /// пара строк текста).
    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in friendSkeletonRow }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }

    private var friendSkeletonRow: some View {
        HStack(spacing: 12) {
            SkeletonBox()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBar(width: 130)
                SkeletonBar(width: 80, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private func friendRow(_ entry: FriendshipEntry) -> some View {
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
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

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
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
        HStack(spacing: 10) {
            tabButton("Список друзей", tab: .friends)
            tabButton("Общие друзья", tab: .mutual)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func tabButton(_ title: String, tab: FriendsViewModel.Tab) -> some View {
        let active = vm.tab == tab
        return Button {
            vm.selectTab(tab)
        } label: {
            Text(title)
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
