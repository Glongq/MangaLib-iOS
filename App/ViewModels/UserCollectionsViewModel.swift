import Foundation

/// ViewModel вкладки «Коллекции» в профиле: пагинируемый список подборок,
/// созданных пользователем — GET /collections?user_id=&page=.
@MainActor
final class UserCollectionsViewModel: ObservableObject {

    @Published private(set) var collections: [MangaCollection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?

    private let service = MangaNetworkService.shared
    let userId: Int
    init(userId: Int) { self.userId = userId }

    private var page = 1
    private var hasNext = true

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true; errorMessage = nil; page = 1; hasNext = true
        do {
            let r = try await service.fetchUserCollections(userId: userId, page: 1)
            collections = r.collections
            hasNext = r.hasNextPage
            didLoad = true
        } catch NetworkError.cancelled {
        } catch {
            collections = []; didLoad = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: MangaCollection) async {
        guard hasNext, !isLoading, !isLoadingMore else { return }
        guard collections.suffix(4).contains(where: { $0.id == current.id }) else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            let r = try await service.fetchUserCollections(userId: userId, page: next)
            let existing = Set(collections.map(\.id))
            collections.append(contentsOf: r.collections.filter { !existing.contains($0.id) })
            page = next
            hasNext = r.hasNextPage
        } catch {}
        isLoadingMore = false
    }
}
