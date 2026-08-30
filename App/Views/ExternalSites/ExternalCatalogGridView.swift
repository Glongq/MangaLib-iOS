import SwiftUI

/// Запрос выдачи — тег/серия/... (см. ExternalTagBrowserView) ИЛИ свободный
/// текстовый поиск (см. ExternalSearchView/ExternalCombinedCatalogView,
/// capabilities.hasSearch) — один и тот же экран сетки обслуживает оба
/// случая, отличается только то, какой метод протокола дёргается за
/// очередной страницей ID (см. fetchPage).
enum ExternalCatalogQuery {
    case tag(namespace: ExternalTagNamespace, value: String)
    case search(query: String)
}

/// Один элемент СОВМЕСТНОЙ выдачи (см. ExternalCombinedCatalogView) — ID
/// тайтла сам по себе не уникален между сайтами (у hitomi и e-hentai свои,
/// не связанные пространства целых чисел), поэтому идентичность элемента
/// сетки — ВСЕГДА пара (сайт, id), не голый Int.
struct ExternalCatalogItem: Identifiable, Hashable {
    let site: ExternalSite
    let galleryId: Int
    var id: String { "\(site.rawValue)#\(galleryId)" }
}

/// Сетка тайтлов внешнего сайта (или НЕСКОЛЬКИХ сразу — см. `sites` и
/// ExternalCombinedCatalogView) по одному тегу/серии/персонажу/группе/
/// автору либо свободному запросу (см. план, Часть 6 + совместный каталог).
/// Список ID — постранично (см. fetchPage), карточки — лениво по мере
/// скролла через fetchGalleryDetail, тот же принцип "подгрузка по onAppear
/// последних элементов", что и в старом MangaCatalogView, но написан
/// заново, самостоятельно (см. план — минимально пересекаться со старым
/// кодом).
struct ExternalCatalogGridView: View {
    let sites: [ExternalSite]
    let query: ExternalCatalogQuery
    let title: String

    /// Обычный (не совместный) вызов — один сайт, самый частый случай
    /// (ExternalTagBrowserView/ExternalSearchView).
    init(site: ExternalSite, query: ExternalCatalogQuery, title: String) {
        self.sites = [site]
        self.query = query
        self.title = title
    }

    /// Совместная выдача — сразу НЕСКОЛЬКО сайтов (см.
    /// ExternalCombinedCatalogView) — каждая страница мержится по всем
    /// переданным сайтам разом (см. loadNextBatch).
    init(sites: [ExternalSite], query: ExternalCatalogQuery, title: String) {
        self.sites = sites
        self.query = query
        self.title = title
    }

    private static let pageSize = 25

    @State private var items: [ExternalCatalogItem] = []
    /// Курсор следующей страницы НА КАЖДЫЙ сайт — отсутствие ключа значит
    /// "ещё не спрашивали", nil-курсор при первом запросе (см. fetchPage).
    @State private var cursors: [ExternalSite: String] = [:]
    /// Сайты, у которых ещё МОЖЕТ быть следующая страница — как только сайт
    /// вернул nextCursor == nil (или упал ошибкой) он отсюда убирается,
    /// чтобы не долбить его бесконечно повторными подгрузками.
    @State private var pending: Set<ExternalSite> = []
    @State private var details: [String: ExternalGalleryDetail] = [:]
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private let gridSpacing: CGFloat = 12
    private let gridColumns = 3
    /// Бейдж с источником имеет смысл показывать ТОЛЬКО когда сайтов
    /// несколько — в обычном одно-сайтовом режиме и так понятно, откуда
    /// тайтл (см. ExternalTagBrowserView/ExternalSearchView, где sites — [x]).
    private var showsSourceBadge: Bool { sites.count > 1 }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background.ignoresSafeArea())
            .task { await loadFirstPage() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, items.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await loadFirstPage() } }, fillScreen: true)
        } else if items.isEmpty {
            StateView(icon: "square.grid.2x2", title: "Тайтлов не найдено", fillScreen: true)
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let spacing = gridSpacing
            let totalSpacing = spacing * CGFloat(gridColumns - 1) + 24
            let cardWidth = ((proxy.size.width - totalSpacing) / CGFloat(gridColumns)).rounded(.down)
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: gridColumns)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink {
                            ExternalGalleryDetailView(site: item.site, id: item.galleryId, preloaded: details[item.id])
                        } label: {
                            card(item: item, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .onAppear { onCardAppear(item) }
                    }
                }
                .padding(12)

                if isLoadingMore {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func card(item: ExternalCatalogItem, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let detail = details[item.id], let cover = detail.coverURL {
                        ExternalImage(url: cover) { SkeletonBox() }
                            .scaledToFill()
                    } else {
                        SkeletonBox()
                    }
                }
                .frame(width: width, height: (width * 3 / 2).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipped()

                if showsSourceBadge {
                    Text(item.site.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }

            Text(details[item.id]?.title ?? "…")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)
        }
        .frame(width: width, alignment: .top)
    }

    private func onCardAppear(_ item: ExternalCatalogItem) {
        if details[item.id] == nil {
            Task { await loadDetail(item) }
        }
        guard let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
        Task { await loadMoreIfNeeded() }
    }

    private func loadDetail(_ item: ExternalCatalogItem) async {
        let provider = ExternalSiteRegistry.provider(for: item.site)
        guard let detail = try? await provider.fetchGalleryDetail(id: item.galleryId) else { return }
        details[item.id] = detail
    }

    /// Один и тот же метод для любого сайта — у него нет своего "не умеет
    /// такое" исключения: сайт без hasSearch (например hitomi) для запроса
    /// `.search` просто трактует введённый текст КАК ТЕГ (fetchIdsByTag —
    /// именно так на hitomi ищется что-то по имени: неизвестное имя-тег
    /// просто вернёт пустой список/404, это нормальный ответ, не ошибка,
    /// см. HitomiProvider.fetchIdsByTag). `static`, без захвата `self` —
    /// вызывается из параллельных задач в loadNextBatch (см. ниже), лишний
    /// захват целого View-структа в @Sendable-замыкании ни к чему.
    private static func fetchPage(site: ExternalSite, cursor: String?, query: ExternalCatalogQuery) async throws -> (ids: [Int], nextCursor: String?) {
        let provider = ExternalSiteRegistry.provider(for: site)
        switch query {
        case let .tag(namespace, value):
            return try await provider.fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: pageSize)
        case let .search(text):
            if provider.capabilities.hasSearch {
                return try await provider.fetchIdsBySearch(query: text, cursor: cursor, limit: pageSize)
            } else {
                return try await provider.fetchIdsByTag(namespace: .tag, value: text, cursor: cursor, limit: pageSize)
            }
        }
    }

    private func loadFirstPage() async {
        guard items.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        pending = Set(sites)
        cursors = [:]
        await loadNextBatch()
        if items.isEmpty && pending.isEmpty {
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
        isLoading = false
    }

    private func loadMoreIfNeeded() async {
        guard !isLoadingMore, !pending.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadNextBatch()
    }

    /// Опрашивает ПАРАЛЛЕЛЬНО все сайты из `pending` (первая страница — это
    /// просто "все сайты из `sites`" на старте), мержит результат ЧЕРЕДУЯ по
    /// сайтам (не "сначала все с одного, потом все с другого" — иначе
    /// совместная сетка выглядела бы как склейка двух отдельных, а не
    /// единая выдача).
    private func loadNextBatch() async {
        let sitesToQuery = Array(pending)
        guard !sitesToQuery.isEmpty else { return }
        let currentQuery = query
        let cursorsSnapshot = cursors

        let results = await withTaskGroup(of: (ExternalSite, [Int], String?, Bool).self) { group in
            for site in sitesToQuery {
                let cursor = cursorsSnapshot[site]
                group.addTask {
                    do {
                        let page = try await Self.fetchPage(site: site, cursor: cursor, query: currentQuery)
                        return (site, page.ids, page.nextCursor, true)
                    } catch {
                        return (site, [], nil, false)
                    }
                }
            }
            var collected: [(ExternalSite, [Int], String?, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var idsBySite: [ExternalSite: [Int]] = [:]
        for (site, ids, nextCursor, succeeded) in results {
            if succeeded, let nextCursor {
                cursors[site] = nextCursor
            } else {
                // Либо сайт честно сказал "дальше ничего нет", либо запрос
                // упал — в обоих случаях не спрашиваем этот сайт снова, но
                // то, что он УЖЕ вернул в этом батче (если succeeded),
                // всё равно попадает в выдачу.
                pending.remove(site)
            }
            idsBySite[site] = ids
        }

        let maxCount = idsBySite.values.map(\.count).max() ?? 0
        var merged: [ExternalCatalogItem] = []
        for index in 0..<maxCount {
            for site in sites {
                guard let ids = idsBySite[site], index < ids.count else { continue }
                merged.append(ExternalCatalogItem(site: site, galleryId: ids[index]))
            }
        }

        let existing = Set(items.map(\.id))
        items.append(contentsOf: merged.filter { !existing.contains($0.id) })
    }
}

#Preview {
    NavigationStack {
        ExternalCatalogGridView(site: .hitomi, query: .tag(namespace: .tag, value: "full color"), title: "full color")
    }
    .preferredColorScheme(.dark)
}
