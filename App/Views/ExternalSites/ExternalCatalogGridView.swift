import SwiftUI

/// Запрос выдачи — тег/серия/... (см. ExternalTagBrowserView) ИЛИ свободный
/// текстовый поиск (см. ExternalSearchView, capabilities.hasSearch) — один
/// и тот же экран сетки обслуживает оба случая, отличается только то, какой
/// метод протокола дёргается за очередной страницей ID (см. fetchPage).
enum ExternalCatalogQuery {
    case tag(namespace: ExternalTagNamespace, value: String)
    case search(query: String)
}

/// Сетка тайтлов внешнего сайта по одному тегу/серии/персонажу/группе/
/// автору (см. план, Часть 6) — открывается тапом по строке в
/// ExternalTagBrowserView. Список ID — постранично через .nozomi (см.
/// HitomiProvider.fetchIdsByTag), карточки — лениво по мере скролла через
/// galleries/{id}.js (см. fetchGalleryDetail), тот же принцип "подгрузка
/// по onAppear последних элементов", что и в старом MangaCatalogView, но
/// написан заново, самостоятельно (см. план — минимально пересекаться со
/// старым кодом).
struct ExternalCatalogGridView: View {
    let site: ExternalSite
    let query: ExternalCatalogQuery
    let title: String

    private static let pageSize = 25

    @State private var ids: [Int] = []
    @State private var nextCursor: String?
    @State private var details: [Int: ExternalGalleryDetail] = [:]
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    private let gridSpacing: CGFloat = 12
    private let gridColumns = 3

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background.ignoresSafeArea())
            .task { await loadFirstPage() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && ids.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, ids.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await loadFirstPage() } }, fillScreen: true)
        } else if ids.isEmpty {
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
                    ForEach(ids, id: \.self) { id in
                        NavigationLink {
                            ExternalGalleryDetailView(site: site, id: id, preloaded: details[id])
                        } label: {
                            card(id: id, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .onAppear { onCardAppear(id) }
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

    private func card(id: Int, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let detail = details[id], let cover = detail.coverURL {
                    ExternalImage(url: cover) { SkeletonBox() }
                        .scaledToFill()
                } else {
                    SkeletonBox()
                }
            }
            .frame(width: width, height: (width * 3 / 2).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()

            Text(details[id]?.title ?? "…")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)
        }
        .frame(width: width, alignment: .top)
    }

    private func onCardAppear(_ id: Int) {
        if details[id] == nil {
            Task { await loadDetail(id) }
        }
        guard let index = ids.firstIndex(of: id), index >= ids.count - 6 else { return }
        Task { await loadMoreIfNeeded() }
    }

    private func loadDetail(_ id: Int) async {
        guard let detail = try? await provider.fetchGalleryDetail(id: id) else { return }
        details[id] = detail
    }

    /// Один и тот же метод для первой и последующих страниц — отличаются
    /// только cursor (nil = первая страница).
    private func fetchPage(cursor: String?) async throws -> (ids: [Int], nextCursor: String?) {
        switch query {
        case let .tag(namespace, value):
            return try await provider.fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: Self.pageSize)
        case let .search(text):
            return try await provider.fetchIdsBySearch(query: text, cursor: cursor, limit: Self.pageSize)
        }
    }

    private func loadFirstPage() async {
        guard ids.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await fetchPage(cursor: nil)
            ids = result.ids
            nextCursor = result.nextCursor
        } catch {
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
        isLoading = false
    }

    private func loadMoreIfNeeded() async {
        guard !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let result = try? await fetchPage(cursor: cursor) else { return }
        // Защита от дублей — на случай гонки/повторного onAppear.
        let existing = Set(ids)
        ids.append(contentsOf: result.ids.filter { !existing.contains($0) })
        nextCursor = result.nextCursor
    }
}

#Preview {
    NavigationStack {
        ExternalCatalogGridView(site: .hitomi, query: .tag(namespace: .tag, value: "full color"), title: "full color")
    }
    .preferredColorScheme(.dark)
}
