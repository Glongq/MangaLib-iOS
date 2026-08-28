import Foundation

/// ViewModel страницы одной коллекции — GET /collections/{id}, голос
/// (POST /collection/{id}/vote) и подписка/избранное (тот же generic
/// /favorites, что и у команд/франшиз, source_type="collection").
@MainActor
final class CollectionDetailViewModel: ObservableObject {

    let collectionId: Int
    private let fallback: MangaCollection?

    @Published private(set) var detail: CollectionDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isVoting = false
    @Published private(set) var isTogglingFavorite = false
    /// Локальный голос/статус подписки — не в detail (см. reloadOptimistic),
    /// чтобы UI обновлялся мгновенно, не дожидаясь полной перезагрузки.
    @Published private(set) var votes: SimilarVotes?
    @Published private(set) var isSubscribed = false
    /// Сколько ВСЕГО людей добавили коллекцию в закладки — сразу после
    /// toggleFavorite() обновляется РЕАЛЬНЫМ числом с сервера (см.
    /// FavoriteToggleResponse.subscribersStat — тот же `meta.stats.value`,
    /// что и у команд/франшиз), а не просто +1/-1 на клиенте.
    @Published private(set) var favoritesCount: Int?

    private let service = MangaNetworkService.shared

    init(collectionId: Int, fallback: MangaCollection? = nil) {
        self.collectionId = collectionId
        self.fallback = fallback
        favoritesCount = fallback?.favoritesCount
    }

    var displayName: String { detail?.name ?? fallback?.name ?? "" }

    func loadIfNeeded() async {
        guard detail == nil, !isLoading else { return }
        await load()
    }

    func load() async {
        isLoading = true; errorMessage = nil
        do {
            let d = try await service.fetchCollectionDetail(id: collectionId)
            detail = d
            votes = d.votes
            isSubscribed = d.isSubscribed
            favoritesCount = d.favoritesCount
        } catch NetworkError.cancelled {
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func vote(up: Bool) {
        guard !isVoting else { return }
        isVoting = true
        Task {
            defer { isVoting = false }
            guard let v = try? await service.voteCollection(id: collectionId, direction: up ? 1 : 0) else { return }
            votes = v
        }
    }

    func toggleFavorite() {
        guard !isTogglingFavorite else { return }
        isTogglingFavorite = true
        Task {
            defer { isTogglingFavorite = false }
            guard let result = try? await service.toggleFavorite(sourceId: collectionId, sourceType: "collection") else { return }
            isSubscribed = result.isSubscribed
            if let real = result.subscribersStat?.value {
                favoritesCount = real
            } else {
                // Запасной вариант, если сервер вдруг не прислал meta.stats
                // (в перехвате был всегда) — считаем на клиенте по
                // направлению переключения, как и просили: +1/-1.
                favoritesCount = max(0, (favoritesCount ?? 0) + (isSubscribed ? 1 : -1))
            }
        }
    }
}
