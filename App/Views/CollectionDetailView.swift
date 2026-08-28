import SwiftUI

/// Страница одной коллекции — GET /collections/{id} (см.
/// CollectionDetailViewModel). Сверху автор, затем статистика/голос/
/// избранное, затем описание, затем сами тайтлы — единым списком или
/// разбитые на именованные разделы (см. CollectionDetail.blocks), по
/// прямой просьбе "поймёшь сам" за реальной формой ответа. Сетка тайтлов
/// учитывает "Количество карточек в ряд" из Персонализации (по прямой
/// просьбе) — тот же @AppStorage-ключ, что и в Каталоге/Закладках (см.
/// CardsPerRow.swift).
struct CollectionDetailView: View {
    let collectionId: Int
    let fallback: MangaCollection?

    @StateObject private var vm: CollectionDetailViewModel
    @State private var profileUser: ProfileUserId?
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto
    private let gridSpacing: CGFloat = 12

    init(collectionId: Int, fallback: MangaCollection? = nil) {
        self.collectionId = collectionId
        self.fallback = fallback
        _vm = StateObject(wrappedValue: CollectionDetailViewModel(collectionId: collectionId, fallback: fallback))
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: cardsPerRow.columns,
                spacing: gridSpacing,
                containerPadding: 16
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let author = vm.detail?.user {
                        authorRow(author)
                    }

                    statsRow

                    if let desc = vm.detail?.description, !desc.isEmpty {
                        ExpandableDescription(text: desc)
                    }

                    ForEach(vm.detail?.blocks ?? []) { block in
                        blockSection(block, cardWidth: cardWidth)
                    }

                    if vm.isLoading && vm.detail == nil {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 40)
                    } else if let error = vm.errorMessage, vm.detail == nil {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .sheet(item: $profileUser) { pu in ProfileView(userId: pu.id) }
    }

    // MARK: Автор

    private func authorRow(_ author: FriendUser) -> some View {
        Button { profileUser = ProfileUserId(id: author.id) } label: {
            HStack(spacing: 10) {
                RemoteImage(url: author.avatarURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.surfaceElevated)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("Автор коллекции").font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text(author.username).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Статистика / голос / избранное

    private var statsRow: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    if let v = vm.detail?.views ?? fallback?.views { statChip(icon: "eye", value: v) }
                    if let n = vm.detail?.itemsCount ?? fallback?.itemsCount { statChip(icon: "square.stack", value: n) }
                    if let n = vm.detail?.commentsCount ?? fallback?.commentsCount { statChip(icon: "text.bubble", value: n) }
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
            voteButtons
            favoriteButton
        }
    }

    private func statChip(icon: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text("\(value)").font(.caption2)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    /// Голос "+"/"-" — POST /collection/{id}/vote, 1=плюс/0=минус/null=не
    /// голосовал (та же конвенция, что и у голоса за комментарий).
    private var voteButtons: some View {
        HStack(spacing: 6) {
            Button { vm.vote(up: true) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                    Text("\(vm.votes?.up ?? 0)")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(vm.votes?.user == 1 ? Theme.accent : Theme.textSecondary)
            }
            Button { vm.vote(up: false) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                    Text("\(vm.votes?.down ?? 0)")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(vm.votes?.user == 0 ? Color.red : Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isVoting)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    /// Подписка/избранное — тот же generic POST /favorites, что и у команд/
    /// франшиз, source_type="collection" (см. CollectionDetailViewModel.
    /// toggleFavorite).
    private var favoriteButton: some View {
        Button { vm.toggleFavorite() } label: {
            Image(systemName: vm.isSubscribed ? "bookmark.fill" : "bookmark")
                .foregroundStyle(vm.isSubscribed ? Theme.accent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceElevated, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(vm.isTogglingFavorite)
    }

    // MARK: Тайтлы — единым списком или по разделам (см. CollectionDetail.blocks)

    /// Заголовок раздела — только когда разделов реально НЕСКОЛЬКО (по
    /// прямой просьбе: "бывает что на категории поделен" — то есть не
    /// всегда; один-единственный блок просто показываем без лишнего
    /// заголовка, повторяющего название самой коллекции).
    @ViewBuilder
    private func blockSection(_ block: CollectionBlock, cardWidth: CGFloat) -> some View {
        let showsHeader = (vm.detail?.blocks.count ?? 0) > 1
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader, !block.name.isEmpty {
                Text(block.name).font(.headline).foregroundStyle(Theme.textPrimary)
            }
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: cardsPerRow.columns)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(block.items) { item in
                    if let manga = item.related {
                        NavigationLink {
                            MangaDetailView(slug: manga.apiSlug, fallbackTitle: manga.displayTitle, coverURL: manga.cover?.bestURL, item: manga)
                        } label: {
                            MangaCardView(item: manga, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { CollectionDetailView(collectionId: 1) }.preferredColorScheme(.dark)
}
