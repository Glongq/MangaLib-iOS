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

    /// Ошибка ИМЕННО от голоса/закладки (не от загрузки страницы) — раньше
    /// try? тихо съедал любой сбой (403/404/сеть), кнопка просто "не
    /// работала" без единого намёка почему. Теперь реальный текст ошибки
    /// всплывает в actionsFooter.
    @Published private(set) var actionError: String?

    func vote(up: Bool) {
        guard !isVoting else { return }
        isVoting = true
        actionError = nil
        Task {
            defer { isVoting = false }
            do {
                votes = try await service.voteCollection(id: collectionId, direction: up ? 1 : 0)
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func toggleFavorite() {
        guard !isTogglingFavorite else { return }
        isTogglingFavorite = true
        actionError = nil
        Task {
            defer { isTogglingFavorite = false }
            do {
                let result = try await service.toggleFavorite(sourceId: collectionId, sourceType: "collection")
                isSubscribed = result.isSubscribed
                if let real = result.subscribersStat?.value {
                    favoritesCount = real
                } else {
                    // Запасной вариант, если сервер вдруг не прислал meta.stats
                    // (в перехвате был всегда) — считаем на клиенте по
                    // направлению переключения, как и просили: +1/-1.
                    favoritesCount = max(0, (favoritesCount ?? 0) + (isSubscribed ? 1 : -1))
                }
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
