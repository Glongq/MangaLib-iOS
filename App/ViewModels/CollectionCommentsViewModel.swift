import Foundation

/// Комментарии к коллекции — `post_type=collection` (ПОДТВЕРЖДЕНО перехватом
/// `GET /comments?post_id=&post_type=collection`), та же generic-сеть, что и
/// у комментариев тайтла/главы — просто другой postType. Не reader-tема,
/// без вложенной сложности ChapterCommentsViewModel (postPage/siteId ей не
/// нужны — у коллекции их просто нет).
@MainActor
final class CollectionCommentsViewModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasMore = false
    @Published private(set) var isPosting = false
    @Published var sort: CommentSort = .new

    private let service = MangaNetworkService.shared
    private var page = 1
    let collectionId: Int
    init(collectionId: Int) { self.collectionId = collectionId }

    private var sortType: String { sort == .old ? "asc" : "desc" }
    private var sortBy: String { sort == .popular ? "votes_up" : "id" }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    func load() async {
        isLoading = true; error = nil; page = 1
        do {
            let r = try await service.fetchComments(postId: collectionId, postType: "collection", sortBy: sortBy, sortType: sortType, page: 1)
            comments = r.comments
            hasMore = r.hasNextPage
            hasLoaded = true
        } catch NetworkError.cancelled {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func changeSort(_ s: CommentSort) async {
        guard s != sort else { return }
        sort = s
        await load()
    }

    func loadMoreIfNeeded(current: Comment) async {
        guard hasMore, !isLoading else { return }
        guard comments.suffix(4).contains(where: { $0.id == current.id }) else { return }
        isLoading = true
        let next = page + 1
        do {
            let r = try await service.fetchComments(postId: collectionId, postType: "collection", sortBy: sortBy, sortType: sortType, page: next)
            comments.append(contentsOf: r.comments)
            hasMore = r.hasNextPage
            page = next
        } catch {}
        isLoading = false
    }

    @discardableResult
    func post(text: String, replyingTo: Comment?) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        isPosting = true; error = nil
        let level = (replyingTo?.commentLevel).map { $0 + 1 } ?? 0
        do {
            let created = try await service.postComment(
                postId: collectionId, postType: "collection",
                text: t, commentLevel: level, parentComment: replyingTo?.id
            )
            comments.insert(created, at: 0)
            isPosting = false
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isPosting = false
            return false
        }
    }

    @discardableResult
    func vote(_ comment: Comment, isUp: Bool) async -> Bool {
        guard AuthSession.shared.isLoggedIn,
              let idx = comments.firstIndex(where: { $0.id == comment.id }) else { return false }
        do {
            let v = try await service.voteComment(id: comment.id, direction: isUp ? 1 : 0)
            comments[idx].votesUp = v.up
            comments[idx].votesDown = v.down
            comments[idx].userVote = v.user
            return true
        } catch { return false }
    }
}
