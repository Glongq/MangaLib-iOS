import SwiftUI

/// Экран "Коллекции" (Меню → Каталог → Коллекции) — общая лента коллекций
/// сайта. Внизу слева — "Создать свою коллекцию" (эндпоинта создания в
/// перехвате НЕТ — честная заглушка, см. StubView в SideMenuView.swift),
/// справа — "Фильтры" с сортировкой (см. CollectionsListViewModel.Sort).
/// Карточка — та же форма, что и в профиле (см. UserCollectionsView.
/// collectionCard), но здесь реально ведёт на CollectionDetailView.
struct CollectionsListView: View {
    @StateObject private var vm = CollectionsListViewModel()
    @State private var showCreateStub = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Коллекции")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { controlsBar }
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showCreateStub) {
            NavigationStack { StubView(title: "Создать коллекцию") }
        }
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.collections.isEmpty {
            skeletonList
        } else if let error = vm.errorMessage, vm.collections.isEmpty {
            ScrollView { emptyState(icon: "wifi.exclamationmark", text: error).containerRelativeFrame(.vertical) }
                .scrollIndicators(.hidden)
                .refreshable { await vm.reload() }
        } else if vm.collections.isEmpty && vm.didLoad {
            ScrollView { emptyState(icon: "square.stack", text: "Коллекций пока нет").containerRelativeFrame(.vertical) }
                .scrollIndicators(.hidden)
                .refreshable { await vm.reload() }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.collections) { c in
                        NavigationLink { CollectionDetailView(collectionId: c.id, fallback: c) } label: {
                            collectionCard(c)
                        }
                        .buttonStyle(.plain)
                        .onAppear { Task { await vm.loadMoreIfNeeded(current: c) } }
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
            .refreshable { await vm.reload() }
        }
    }

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

    /// 1-в-1 UserCollectionsView.collectionCard (своя копия — та приватна к
    /// своему файлу): название + чипы статистики + голоса + веер превью.
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

    // MARK: Нижняя панель — "Создать" + "Фильтры"

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button { showCreateStub = true } label: {
                pill(icon: "plus", text: "Создать свою коллекцию")
            }
            Spacer(minLength: 0)
            Menu {
                Picker("Сортировка", selection: $vm.sort) {
                    ForEach(CollectionsListViewModel.Sort.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
            } label: {
                pill(icon: "line.3.horizontal.decrease", text: "Фильтры")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

#Preview {
    NavigationStack { CollectionsListView() }.preferredColorScheme(.dark)
}
