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

    private let service = MangaNetworkService.shared

    init(collectionId: Int, fallback: MangaCollection? = nil) {
        self.collectionId = collectionId
        self.fallback = fallback
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
        }
    }
}
