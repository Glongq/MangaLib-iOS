import SwiftUI

/// Вкладка «Коллекции» в профиле пользователя — список подборок, которые он
/// создал. Карточка — та же форма, что и на главной («Читают», см.
/// HomeView.collectionCard): название, статистика (просмотры/тайтлов/в
/// избранном), голоса, веер из превью обложек. Данные: GET /collections?
/// user_id=&page=.
struct UserCollectionsView: View {
    let userId: Int
    /// false — встроен в ProfileView без своей шапки (см.
    /// UserBookmarksView.showsOwnHeader).
    var showsOwnHeader: Bool = true

    @StateObject private var vm: UserCollectionsViewModel
    @Environment(\.dismiss) private var dismiss

    init(userId: Int, showsOwnHeader: Bool = true) {
        self.userId = userId
        self.showsOwnHeader = showsOwnHeader
        _vm = StateObject(wrappedValue: UserCollectionsViewModel(userId: userId))
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
        .task { await vm.loadIfNeeded() }
    }

    /// Позиция кнопки "назад" и заголовка — та же, что и в шапке "Профиль"
    /// (см. AccountInfoView.header: padding.top 14) — раньше здесь было 8,
    /// тот же не замеченный явно, но тот же самый перекос, что и у
    /// Комментариев/Друзей/Списков тайтлов рядом в том же меню профиля.
    private var header: some View {
        ZStack {
            Text("Коллекции").font(.headline).foregroundStyle(Theme.textPrimary)
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

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.collections.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let error = vm.errorMessage, vm.collections.isEmpty {
            emptyState(icon: "wifi.exclamationmark", text: error)
        } else if vm.collections.isEmpty && vm.didLoad {
            emptyState(icon: "square.stack", text: "Коллекций пока нет")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.collections) { c in
                        collectionCard(c)
                            .onAppear { Task { await vm.loadMoreIfNeeded(current: c) } }
                    }
                    if vm.isLoadingMore {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func collectionCard(_ collection: MangaCollection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(collection.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if collection.adult == true {
                    Text("18+")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            HStack(spacing: 14) {
                if let views = collection.views { statLabel(icon: "eye", value: views) }
                if let itemsCount = collection.itemsCount { statLabel(icon: "square.stack", value: itemsCount) }
                if let favoritesCount = collection.favoritesCount { statLabel(icon: "bookmark", value: favoritesCount) }
                if let commentsCount = collection.commentsCount { statLabel(icon: "text.bubble", value: commentsCount) }
            }
            if let votes = collection.votes {
                statLabel(icon: "star.fill", value: votes.up, secondary: votes.down)
            }

            previewStack(collection.previews ?? [])
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statLabel(icon: String, value: Int, secondary: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(secondary.map { "\(value)/\($0)" } ?? "\(value)")
                .font(.caption2)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func previewStack(_ previews: [MangaCover]) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(previews.prefix(3).enumerated()), id: \.offset) { index, cover in
                RemoteImage(url: cover.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    Theme.surfaceElevated
                }
                .frame(width: 60, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .rotationEffect(.degrees(Double(index) * 4 - 4))
                .offset(x: CGFloat(index) * 26)
                .clipped()
            }
        }
        .frame(height: 84, alignment: .leading)
        .padding(.leading, 4)
        .padding(.trailing, previews.count > 1 ? CGFloat(previews.prefix(3).count - 1) * 26 + 20 : 0)
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
}

#Preview {
    UserCollectionsView(userId: 1).preferredColorScheme(.dark)
}
