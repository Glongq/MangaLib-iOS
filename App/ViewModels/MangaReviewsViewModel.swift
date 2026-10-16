import Foundation

/// ViewModel экрана «Отзывы» тайтла — пагинируемый список, GET /reviews?
/// reviewable_type=manga&reviewable_id=.
@MainActor
final class MangaReviewsViewModel: ObservableObject {

    @Published private(set) var reviews: [MangaReview] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?

    private let service = MangaNetworkService.shared
    let mangaId: Int
    private let siteId: Int?
    init(mangaId: Int, siteId: Int?) {
        self.mangaId = mangaId
        self.siteId = siteId
    }

    private var page = 1
    private var hasNext = true

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true; errorMessage = nil; page = 1; hasNext = true
        do {
            let r = try await service.fetchReviews(mangaId: mangaId, page: 1, siteId: siteId)
            reviews = r.reviews
            hasNext = r.hasNextPage
            didLoad = true
        } catch NetworkError.cancelled {
        } catch {
            reviews = []; didLoad = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: MangaReview) async {
        guard hasNext, !isLoading, !isLoadingMore else { return }
        guard reviews.suffix(3).contains(where: { $0.id == current.id }) else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            let r = try await service.fetchReviews(mangaId: mangaId, page: next, siteId: siteId)
            let existing = Set(reviews.map(\.id))
            reviews.append(contentsOf: r.reviews.filter { !existing.contains($0.id) })
            page = next
            hasNext = r.hasNextPage
        } catch {}
        isLoadingMore = false
    }
}
