import SwiftUI

/// Экран «Пользователи» (Меню → Каталог → Пользователи) — постраничный
/// список аккаунтов `GET /user` (см. UserListViewModel), с поиском. Тап по
/// строке открывает ТОТ ЖЕ ProfileView, что и везде в приложении (аватарка в
/// комментарии, "Друзья" и т.д.) — тем же способом, sheet(item:), у него своя
/// внутренняя навигация и dismiss-шапка, рассчитанные именно на модальную
/// презентацию.
struct UserListView: View {

    @StateObject private var vm = UserListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var profileUser: ProfileUserId?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Пользователи")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.query, prompt: "Поиск по нику")
        .tint(Theme.accent)
        .task { vm.loadInitialIfNeeded() }
        .sheet(item: $profileUser) { pu in ProfileView(userId: pu.id) }
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.errorMessage, vm.items.isEmpty {
            errorState(error)
        } else if vm.items.isEmpty && vm.isLoading {
            ProgressView().tint(Theme.accent)
        } else if vm.items.isEmpty && vm.didLoadOnce {
            ContentUnavailableView.search(text: vm.query)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(vm.items) { user in
                    row(user)
                        .onAppear { vm.loadMoreIfNeeded(currentItem: user) }
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

    private func errorState(_ message: String) -> some View {
        StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: message, retry: { vm.retry() }, fillScreen: true)
    }

    private func row(_ user: DirectoryUserEntry) -> some View {
        Button { profileUser = ProfileUserId(id: user.id) } label: {
            HStack(spacing: 12) {
                RemoteImage(url: user.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .clipped()

                Text(user.username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if user.isPremium {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        UserListView()
    }
    .preferredColorScheme(.dark)
}
