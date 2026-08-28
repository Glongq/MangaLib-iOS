import SwiftUI

/// Страница одной коллекции — GET /collections/{id} (см.
/// CollectionDetailViewModel). Сверху заголовок (название слева, автор
/// справа: ник над подписью "Автор коллекции", аватар у края) и строка
/// дата/просмотры+тайтлы, затем описание, затем сами тайтлы — единым
/// списком или разбитые на именованные разделы (см. CollectionDetail.
/// blocks). "..." в навбаре — Поделиться/Пожаловаться. Внизу — кнопка
/// "Комментарии" и чипы "В закладки"/голос. Сетка тайтлов учитывает
/// "Количество карточек в ряд" из Персонализации — тот же @AppStorage-ключ,
/// что и в Каталоге/Закладках (см. CardsPerRow.swift).
struct CollectionDetailView: View {
    let collectionId: Int
    let fallback: MangaCollection?

    @StateObject private var vm: CollectionDetailViewModel
    @State private var profileUser: ProfileUserId?
    @State private var showReportStub = false
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
                    titleHeader

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
                    } else if vm.detail != nil {
                        actionsFooter
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // "..." справа сверху — тот же паттерн, что и у карточки тайтла
            // (см. MangaDetailView.actionMenuItems): Menu + ellipsis.circle,
            // никакой самодельной кнопки поверх системного бара.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { showReportStub = true } label: {
                        Label("Пожаловаться", systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await vm.loadIfNeeded() }
        .sheet(item: $profileUser) { pu in ProfileView(userId: pu.id) }
        .sheet(isPresented: $showReportStub) {
            // GET /reports/types?namespaces[0]=collection ПОДТВЕРЖДЁН
            // перехватом (реальные причины жалоб), но сам POST отправки
            // жалобы ни разу не пойман — рисковать и выдумывать тело
            // запроса не стал, честная заглушка.
            NavigationStack { StubView(title: "Пожаловаться") }
        }
    }

    /// Та же ссылка на страницу, что и у тайтла (см. MangaDetailView.
    /// shareURL) — реальный домен активного сайта + подтверждённый путь
    /// (пользователь сам прислал `/ru/collections/{id}` реальной ссылкой).
    private var shareURL: URL? {
        URL(string: "https://\(SiteSession.shared.activeSite.host)/ru/collections/\(collectionId)")
    }

    // MARK: Заголовок — название+автор / дата / просмотры+тайтлы

    /// Автор — по прямой просьбе теперь в самом верху справа (был отдельной
    /// строкой ниже): ник сверху, подпись "Автор коллекции" под ним, аватар
    /// у самого края.
    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Text(vm.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let author = vm.detail?.user {
                    authorChip(author)
                }
            }

            HStack(spacing: 10) {
                if let date = vm.detail?.createdAt {
                    Text(date.relativeRussianString)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if let v = vm.detail?.views ?? fallback?.views { statChip(icon: "eye", value: v) }
                if let n = vm.detail?.itemsCount ?? fallback?.itemsCount { statChip(icon: "square.stack", value: n) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statChip(icon: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text("\(value)").font(.caption2)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func authorChip(_ author: FriendUser) -> some View {
        Button { profileUser = ProfileUserId(id: author.id) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(author.username)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("Автор коллекции")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                RemoteImage(url: author.avatarURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.surfaceElevated)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
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

    // MARK: Низ страницы — комментарии + чипы (закладка/жалоба/голос)

    private var actionsFooter: some View {
        VStack(spacing: 10) {
            NavigationLink { CollectionCommentsView(collectionId: collectionId) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.bubble").foregroundStyle(Theme.accent)
                    Text("Комментарии").foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if let n = vm.detail?.commentsCount { Text("\(n)").foregroundStyle(Theme.textSecondary) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .font(.subheadline.weight(.medium))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                favoriteChip
                Spacer(minLength: 0)
                voteChip
            }
        }
        .padding(.top, 6)
    }

    /// Подписка/избранное — тот же generic POST /favorites, что и у команд/
    /// франшиз, source_type="collection" (см. CollectionDetailViewModel.
    /// toggleFavorite).
    private var favoriteChip: some View {
        Button { vm.toggleFavorite() } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.isSubscribed ? "bookmark.fill" : "bookmark")
                Text(vm.isSubscribed ? "В закладках" : "В закладки")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(vm.isSubscribed ? Theme.accent : Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isTogglingFavorite)
    }

    /// Голос "+"/"-" — POST /collection/{id}/vote, 1=плюс/0=минус/null=не
    /// голосовал (та же конвенция, что и у голоса за комментарий); счётчики
    /// прямо в кнопках и есть "виджет скок лайков" — отдельный не нужен.
    private var voteChip: some View {
        HStack(spacing: 6) {
            Button { vm.vote(up: true) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.thumbsup")
                    Text("\(vm.votes?.up ?? 0)")
                }
                .foregroundStyle(vm.votes?.user == 1 ? Theme.accent : Theme.textPrimary)
            }
            Button { vm.vote(up: false) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.thumbsdown")
                    Text("\(vm.votes?.down ?? 0)")
                }
                .foregroundStyle(vm.votes?.user == 0 ? Color.red : Theme.textPrimary)
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.plain)
        .disabled(vm.isVoting)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surfaceElevated, in: Capsule())
    }
}

#Preview {
    NavigationStack { CollectionDetailView(collectionId: 1) }.preferredColorScheme(.dark)
}
