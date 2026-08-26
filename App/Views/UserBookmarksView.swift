import SwiftUI

/// Вкладка «Списки тайтлов» в профиле ДРУГОГО пользователя: полоска его папок
/// закладок (с количеством), ниже — сетка тайтлов выбранной папки. Данные:
/// GET /bookmarks/folder/{userId} и GET /bookmarks?status=&user_id=&page=.
struct UserBookmarksView: View {
    let userId: Int

    @StateObject private var vm: UserBookmarksViewModel
    @Environment(\.dismiss) private var dismiss
    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12

    init(userId: Int) {
        self.userId = userId
        _vm = StateObject(wrappedValue: UserBookmarksViewModel(userId: userId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if vm.folders.isEmpty {
                    emptyOrLoadingFolders
                } else {
                    content
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Папки — внизу, тем же приёмом safeAreaInset, что и переключатели в
        // "Друзья"/"Комментарии" (tabBar/controlsBar), а не отдельной строкой
        // сразу под шапкой, как было — единообразно с остальными вкладками
        // профиля (по прямой просьбе).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !vm.folders.isEmpty { folderChips }
        }
        .task { await vm.loadFoldersIfNeeded() }
    }

    /// Позиция кнопки "назад" и заголовка — та же, что и в шапке "Профиль"
    /// (см. AccountInfoView.header: padding.top 14) — раньше здесь было 8,
    /// заметно выше, чем в "Готово"/аватаре на самом профиле, из-за чего при
    /// переходе с профиля сюда шапка визуально "прыгала" вверх.
    private var header: some View {
        ZStack {
            Text("Списки тайтлов").font(.headline).foregroundStyle(Theme.textPrimary)
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
    private var emptyOrLoadingFolders: some View {
        if vm.isLoadingFolders {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let error = vm.errorMessage {
            emptyState(icon: "wifi.exclamationmark", text: error)
        } else {
            emptyState(icon: "square.stack.3d.up", text: "Списки пусты")
        }
    }

    private var folderChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(vm.folders) { folder in folderChip(folder) }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func folderChip(_ folder: UserBookmarkFolder) -> some View {
        let active = vm.selectedFolderId == folder.id
        let color = Color(hex: folder.colorHex) ?? Theme.accent
        return Button {
            vm.selectFolder(folder.id)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(folder.name).font(.subheadline.weight(active ? .semibold : .regular))
                Text("\(folder.count)").font(.caption2.weight(.bold))
            }
            .foregroundStyle(active ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.pillControlHeight)
            .glassEffect(active ? .regular.tint(color).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: 16
            )
            ScrollView {
                grid(cardWidth: cardWidth)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func grid(cardWidth: CGFloat) -> some View {
        if vm.isLoadingItems && vm.items.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if vm.items.isEmpty {
            emptyState(icon: "books.vertical", text: "Пусто")
        } else {
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: gridColumnsCount)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vm.items, id: \.id) { entry in
                    NavigationLink {
                        MangaDetailView(
                            slug: entry.media.apiSlug,
                            fallbackTitle: entry.media.displayTitle,
                            coverURL: entry.media.cover?.bestURL,
                            item: entry.media
                        )
                    } label: {
                        MangaCardView(item: entry.media, width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .onAppear { Task { await vm.loadMoreIfNeeded(current: entry) } }
                }
            }
            if vm.isLoadingMore {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Цвет папки закладок приходит с сервера hex-строкой ("#ff9b40") — своего
/// парсера в приложении раньше не было (все прочие цвета берутся из Theme),
/// нужен впервые именно тут.
private extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    NavigationStack { UserBookmarksView(userId: 1) }.preferredColorScheme(.dark)
}
