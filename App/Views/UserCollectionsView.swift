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
    /// коллекции (см. тот же комментарий в HomeView/CollectionsListView).
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

    /// Веер обложек 1-в-1 разбор реального сайта (по прямой просьбе,
    /// точные углы/смещения/z-индексы): левая (-13°, x:-35, y:-4, самый
    /// НИЖНИЙ слой) → центральная (0°, по центру, средний слой) → правая
    /// (+7°, x:+30, y:+8, самый ВЕРХНИЙ слой, перекрывает центральную).
    /// Вращение — от НИЖНЕГО центра каждой обложки (anchor: .bottom), не от
    /// геометрического центра — так они расходятся веером из одной точки
    /// внизу, а не проворачиваются на месте. Была симметричная версия
    /// "центр всегда сверху" — по факту у сайта верхний слой ПРАВАЯ.
    private static let fanTransforms: [(rotation: Double, x: CGFloat, y: CGFloat, z: Double)] = [
        (-13, -35, -4, 0),
        (0, 0, 0, 1),
        (7, 30, 8, 2)
    ]

    private func previewStack(_ previews: [MangaCover]) -> some View {
        let items = Array(previews.prefix(3))
        return ZStack(alignment: .bottom) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, cover in
                let t = items.count == 3 ? Self.fanTransforms[index] : (rotation: 0, x: 0, y: 0, z: Double(index))
                RemoteImage(url: cover.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    Theme.surfaceElevated
                }
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 4)
                .rotationEffect(.degrees(t.rotation), anchor: .bottom)
                .offset(x: t.x, y: t.y)
                .zIndex(t.z)
            }
        }
        .frame(height: 116)
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
}

#Preview {
    UserCollectionsView(userId: 1).preferredColorScheme(.dark)
}
