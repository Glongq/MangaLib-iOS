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
        VStack(spacing: 12) {
            SkeletonBar(width: 160, height: 20)
            SkeletonBar(width: 200, height: 32)
            SkeletonBox()
                .frame(height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 1-в-1 референс с реального сайта (по прямой просьбе, скриншот): всё
    /// по центру — название, три чипа-пилюли статов (просмотры/тайтлы/
    /// избранное) в один ряд, голос отдельной пилюлей под ними, веер
    /// обложек по центру. Своя копия у каждого места, где показываются
    /// коллекции (см. тот же комментарий в HomeView/UserCollectionsView).
    private func collectionCard(_ collection: MangaCollection) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(collection.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if collection.adult == true {
                    Text("18+")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            HStack(spacing: 10) {
                if let views = collection.views { statPill(icon: "eye", text: "\(views)") }
                if let itemsCount = collection.itemsCount { statPill(icon: "square.stack", text: "\(itemsCount)") }
                if let favoritesCount = collection.favoritesCount { statPill(icon: "bookmark", text: "\(favoritesCount)") }
            }
            if let votes = collection.votes {
                statPill(icon: "star.fill", text: "\(votes.up) / \(votes.down)")
            }

            previewStack(collection.previews ?? [])
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func statPill(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    /// Веер обложек как на сайте — СРЕДНЯЯ обложка по центру, БЕЗ поворота,
    /// поверх остальных; крайние симметрично разъезжаются влево/вправо от
    /// неё и поворачиваются в свою сторону (было — линейная лесенка слева
    /// направо, из-за которой ПРАВАЯ обложка (не средняя) оказывалась
    /// сверху и весь веер был сдвинут к левому краю, а не по центру).
    private func previewStack(_ previews: [MangaCover]) -> some View {
        let items = Array(previews.prefix(3))
        let mid = (items.count - 1) / 2
        return ZStack(alignment: .bottom) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, cover in
                let delta = index - mid
                RemoteImage(url: cover.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    Theme.surfaceElevated
                }
                .frame(width: 72, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .rotationEffect(.degrees(Double(delta) * 8))
                .offset(x: CGFloat(delta) * 26)
                .zIndex(delta == 0 ? 1 : 0)
                .clipped()
            }
        }
        .frame(height: 104)
        .frame(maxWidth: .infinity, alignment: .center)
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
