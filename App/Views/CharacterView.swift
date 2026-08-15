import SwiftUI

/// Экран персонажа: сверху фото, под ним имя (англ) и оригинал, счётчики
/// (тайтлов/подписчиков) и описание; ниже — грид тайтлов, где есть этот
/// персонаж, с поиском, переключателем типа контента, фильтрами и сортировкой.
struct CharacterView: View {
    let slugURL: String
    let fallbackName: String?
    let coverURL: URL?

    @StateObject private var vm: CharacterViewModel
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    init(slugURL: String, fallbackName: String? = nil, coverURL: URL? = nil) {
        self.slugURL = slugURL
        self.fallbackName = fallbackName
        self.coverURL = coverURL
        _vm = StateObject(wrappedValue: CharacterViewModel(slugURL: slugURL))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                titlesControls
                grid
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.detail?.displayName ?? fallbackName ?? "Персонаж")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { await vm.loadIfNeeded() }
        .sheet(isPresented: $showFilters) {
            FilterView(initial: vm.filter) { vm.apply(filter: $0) }
        }
    }

    // MARK: Шапка (фото, имена, счётчики, описание)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteImage(url: vm.detail?.cover?.bestURL ?? coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 150, height: 200)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(vm.detail?.name ?? fallbackName ?? "")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                if let orig = vm.detail?.altName, !orig.isEmpty {
                    Text(orig)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else if let rus = vm.detail?.rusName, !rus.isEmpty {
                    Text(rus)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 24) {
                statColumn(value: vm.detail?.titlesCount, label: "Тайтлов")
                statColumn(value: vm.detail?.subscribersCount, label: "Подписчиков")
            }

            if let desc = vm.detail?.description, !desc.isEmpty {
                ExpandableDescription(text: desc)
            } else if vm.isLoadingDetail {
                ProgressView().tint(Theme.accent)
            }
        }
    }

    private func statColumn(value: Int?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map(Self.grouped) ?? "—")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Поиск + управление (тип контента / фильтры / сортировка)

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
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var siteMenu: some View {
        Menu {
            Picker("Тип", selection: $vm.siteFilter) {
                ForEach(vm.availableFilters) { f in
                    Text(Self.filterLabel(f)).tag(f)
                }
            }
        } label: {
            pill(icon: "square.grid.2x2", text: Self.filterLabel(vm.siteFilter))
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
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private static func siteLabel(_ s: LibSite) -> String {
        switch s {
        case .mangalib:  return "Манга"
        case .ranobelib: return "Новеллы"
        case .hentailib: return "Хентай"
        case .slashlib:  return "Слэш"
        }
    }

    private static func filterLabel(_ f: CharacterViewModel.SiteFilter) -> String {
        switch f {
        case .all: return "Все"
        case .site(let s): return siteLabel(s)
        }
    }

    // MARK: Грид тайтлов

    @ViewBuilder
    private var grid: some View {
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
                        MangaCardView(item: item)
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
