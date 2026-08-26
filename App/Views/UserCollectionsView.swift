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

    init(userId: Int, showsOwnHeader: Bool = true) {
        self.userId = userId
        self.showsOwnHeader = showsOwnHeader
        _vm = StateObject(wrappedValue: UserCollectionsViewModel(userId: userId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        // showsOwnHeader — обычный push (не встроен в профиль): родной
        // системный заголовок + системный back chevron, никакого своего
        // кода (эталон — Настройки/Загрузки). Без него — навбар скрыт,
        // шапку рисует ProfileView.topBar (см. AccountInfoView).
        .navigationTitle("Коллекции")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsOwnHeader ? .visible : .hidden, for: .navigationBar)
        .task { await vm.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.collections.isEmpty {
            skeletonList
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

    /// Скелетон на первую загрузку — по прямой просьбе, вместо голого
    /// спиннера. Упрощённая форма collectionCard ниже (название + строка
    /// статистики + место под веер превью), на плейсхолдерах SkeletonBar/Box.
    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in collectionSkeletonCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }

    private var collectionSkeletonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBar(width: 160, height: 16)
            SkeletonBar(width: 200, height: 10)
            SkeletonBox()
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
