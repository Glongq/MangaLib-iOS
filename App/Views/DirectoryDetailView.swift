import SwiftUI

/// Карточка одной каталожной сущности (Люди/Издательства) — 1-в-1
/// CharacterView (hero-баннер + плавающая обложка + название по центру),
/// плюс кнопка подписки поверх баннера, как у TeamView (эти два вида, в
/// отличие от персонажа, реально поддерживают POST /favorites — см.
/// DirectoryKind.sourceType). Параметризован DirectoryKind вместо отдельного
/// файла на каждый вид. Кнопки "назад"/подписки — ручной слой над
/// прозрачным системным navigation bar (см. transparentSystemNavigationBar()
/// в body, та же схема, что в MangaDetailView/TeamView/CharacterView).
struct DirectoryDetailView: View {
    let kind: DirectoryKind
    let slugURL: String
    let fallbackName: String?
    let coverURL: URL?

    @StateObject private var vm: DirectoryDetailViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12

    private static let heroTitleSpacing: CGFloat = 10
    private static let heroAvatarTopOffset: CGFloat = 120
    private static let metaChipHeight: CGFloat = 44

    init(kind: DirectoryKind, slugURL: String, fallbackName: String? = nil, coverURL: URL? = nil) {
        self.kind = kind
        self.slugURL = slugURL
        self.fallbackName = fallbackName
        self.coverURL = coverURL
        _vm = StateObject(wrappedValue: DirectoryDetailViewModel(kind: kind, slugURL: slugURL))
    }

    var body: some View {
        ZStack(alignment: .top) {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: 16
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroHeader(avatarSize: cardWidth)

                    VStack(alignment: .leading, spacing: 18) {
                        metaRow(availableWidth: proxy.size.width - 32)

                        if let desc = vm.detail?.description, !desc.isEmpty {
                            ExpandableDescription(text: desc)
                        } else if vm.isLoadingDetail {
                            ProgressView().tint(Theme.accent)
                        }

                        titlesControls
                        grid(cardWidth: cardWidth)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 90)
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "directoryScroll")
            .background(Theme.background)
            .ignoresSafeArea(edges: .top)
        }

        pinnedTopBar.alignedWithTransparentNavigationBar()
        }
        // Прозрачный, но РЕАЛЬНО существующий пустой системный бар — см.
        // подробную причину в transparentSystemNavigationBar()
        // (App/InteractivePopGesture.swift) и в том же фиксе в MangaDetailView.body.
        .transparentSystemNavigationBar()
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showFilters) {
            FilterView(initial: vm.filter) { vm.apply(filter: $0) }
        }
    }

    /// Кнопки "назад"/подписка — отдельный слой поверх скролла, единая
    /// HStack-строка (см. тот же приём в TeamView.pinnedTopBar), не toolbar.
    private var pinnedTopBar: some View {
        HStack {
            backButton
            Spacer(minLength: 0)
            if kind.sourceType != nil { subscribeButton }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Шапка (1-в-1 CharacterView.heroHeader + кнопка подписки, как у TeamView)

    private func heroHeader(avatarSize: CGFloat) -> some View {
        let avatarHeight = (avatarSize * 3 / 2).rounded()
        return VStack(alignment: .center, spacing: 0) {
            Color.clear.frame(height: Self.heroAvatarTopOffset)

            VStack(alignment: .center, spacing: Self.heroTitleSpacing) {
                RemoteImage(url: vm.detail?.coverURL ?? coverURL, priority: URLSessionTask.highPriority) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: kind.placeholderIcon).foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: avatarSize, height: avatarHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

                titleBlockOverlay
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .background(alignment: .top) {
            GeometryReader { proxy in
                let stretch = max(0, proxy.frame(in: .named("directoryScroll")).minY)
                let effectiveURL = vm.detail?.coverURL ?? coverURL

                Group {
                    if let effectiveURL {
                        RemoteImage(url: effectiveURL, priority: URLSessionTask.highPriority) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            SkeletonBox()
                        } failure: {
                            Theme.surfaceElevated
                        }
                    } else {
                        Theme.background
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height + stretch)
                .overlay(Color.black.opacity(0.1))
                .blur(radius: 5)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.28),
                            .init(color: Theme.background.opacity(0.35), location: 0.5),
                            .init(color: Theme.background.opacity(0.75), location: 0.72),
                            .init(color: Theme.background, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(y: -stretch)
            }
        }
    }

    private var titleBlockOverlay: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(vm.detail?.displayName ?? fallbackName ?? "")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let alt = vm.detail?.altName, !alt.isEmpty {
                Text(alt).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: Circle())
    }

    /// Реальный POST /favorites {source_type: kind.sourceType} — та же
    /// подписка, что и у команды/франшизы, просто с другим source_type.
    private var subscribeButton: some View {
        Button { vm.toggleSubscription() } label: {
            HStack(spacing: 6) {
                if vm.isTogglingSubscription {
                    ProgressView().scaleEffect(0.7)
                } else if vm.isSubscribed {
                    ZStack {
                        Image(systemName: "bell.fill")
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .offset(x: 7, y: -7)
                    }
                } else {
                    Image(systemName: "bell")
                }
                Text(vm.isSubscribed ? "Увед. включены" : "Подписаться")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isTogglingSubscription)
    }

    // MARK: Метаданные

    private func metaRow(availableWidth: CGFloat) -> some View {
        let items: [(heading: String, value: String)] = [
            vm.detail?.titlesCount.map { ("Тайтлов", "\($0)") },
            vm.detail?.subscribersCount.map { ("Подписчиков", "\($0)") }
        ].compactMap { $0 }

        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    infoBlock(item.heading, value: item.value)
                }
            }
            .frame(minWidth: availableWidth, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private func infoBlock(_ heading: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    // MARK: Поиск + управление

    private var titlesControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            HStack(spacing: 8) {
                siteMenu
                Spacer(minLength: 0)
                filtersButton
                sortMenu
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("", text: $vm.query,
                      prompt: Text("Поиск по названию").foregroundColor(Theme.textSecondary))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
            if !vm.query.isEmpty {
                Button { vm.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private var siteMenu: some View {
        Menu {
            Picker("Тип", selection: $vm.siteFilter) {
                ForEach(vm.availableFilters) { f in
                    Text(filterLabel(f)).tag(f)
                }
            }
        } label: {
            pill(icon: "square.grid.2x2", text: filterLabel(vm.siteFilter))
        }
    }

    private var filtersButton: some View {
        Button { showFilters = true } label: {
            pill(icon: "slider.horizontal.3", text: "Фильтры", badge: vm.filter.activeCount)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Сортировка", selection: $vm.sort) {
                ForEach(CharacterTitleSort.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            pill(icon: "arrow.up.arrow.down", text: nil)
        }
    }

    private func pill(icon: String, text: String?, badge: Int = 0) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            if let text {
                Text(text).font(.footnote.weight(.medium)).lineLimit(1)
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Theme.accent, in: Circle())
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private func siteLabel(_ s: LibSite) -> String {
        switch s {
        case .mangalib:  return "Манга"
        case .ranobelib: return "Новеллы"
        case .hentailib: return "Хентай"
        case .slashlib:  return "Слэш"
        }
    }

    private func filterLabel(_ f: DirectoryDetailViewModel.SiteFilter) -> String {
        switch f {
        case .all: return "Все"
        case .site(let s):
            guard let count = vm.titlesCount(for: s) else { return siteLabel(s) }
            return "\(siteLabel(s)) \(count)"
        }
    }

    // MARK: Грид тайтлов

    @ViewBuilder
    private func grid(cardWidth: CGFloat) -> some View {
        if let error = vm.errorMessage, vm.titles.isEmpty {
            VStack(spacing: 10) {
                Text(error).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        } else if vm.titles.isEmpty && vm.didLoadOnce && !vm.isLoading {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                Text("Нет тайтлов").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing), count: gridColumnsCount)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vm.titles) { item in
                    NavigationLink {
                        MangaDetailView(
                            slug: item.apiSlug,
                            fallbackTitle: item.displayTitle,
                            coverURL: item.cover?.bestURL,
                            item: item
                        )
                    } label: {
                        MangaCardView(item: item, width: cardWidth)
                    }
                    .buttonStyle(.plain)
                    .onAppear { vm.loadMoreIfNeeded(item) }
                }
            }

            if vm.isLoading && vm.titles.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if vm.isLoadingMore {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }
}

#Preview {
    NavigationStack {
        DirectoryDetailView(kind: .people, slugURL: "113727--junji-itou", fallbackName: "Junji Itou")
    }
    .preferredColorScheme(.dark)
}
