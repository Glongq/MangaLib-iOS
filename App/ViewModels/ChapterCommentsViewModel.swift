import Foundation

/// Комментарии в читалке — по КОНКРЕТНОЙ странице главы (`post_type=chapter`,
/// `post_id`=id главы, `post_page`=номер страницы). Отдельный VM от карточки,
/// но использует ту же сеть/модели. Сортировка/голосование/отправка —
/// подтверждены перехватами (см. MangaNetworkService).
@MainActor
final class ChapterCommentsViewModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasMore = false
    @Published private(set) var isPosting = false
    @Published var sort: CommentSort = .new

    private let service = MangaNetworkService.shared
    private var page = 1
    private(set) var chapterId = 0
    private(set) var postPage = 1
    /// Сайт тайтла главы — см. MangaNetworkService.fetchComments(siteId:).
    private var siteId: Int?

    private var sortType: String { sort == .old ? "asc" : "desc" }
    private var sortBy: String { sort == .popular ? "votes_up" : "id" }

    /// Задать главу/страницу/сайт. Если глава/страница сменились —
    /// сбрасываем, чтобы перезагрузить (siteId обновляется в любом случае,
    /// молча — он не должен сам по себе триггерить перезагрузку).
    func configure(chapterId: Int, postPage: Int, siteId: Int?) {
        self.siteId = siteId
        guard chapterId != self.chapterId || postPage != self.postPage else { return }
        self.chapterId = chapterId
        self.postPage = postPage
        hasLoaded = false
        comments = []
        error = nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    func load() async {
        guard chapterId > 0 else { return }
        isLoading = true; error = nil; page = 1
        do {
            let r = try await service.fetchComments(
                postId: chapterId, postType: "chapter", postPage: postPage,
                sortBy: sortBy, sortType: sortType, page: 1, siteId: siteId
            )
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
        guard hasMore, !isLoading, chapterId > 0 else { return }
        isLoading = true
        let next = page + 1
        do {
            let r = try await service.fetchComments(
                postId: chapterId, postType: "chapter", postPage: postPage,
                sortBy: sortBy, sortType: sortType, page: next, siteId: siteId
            )
            comments.append(contentsOf: r.comments)
            hasMore = r.hasNextPage
            page = next
        } catch {}
        isLoading = false
    }

    @discardableResult
    func post(text: String, replyingTo: Comment?) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, chapterId > 0 else { return false }
        isPosting = true; error = nil
        let level = (replyingTo?.commentLevel).map { $0 + 1 } ?? 0
        do {
            let created = try await service.postComment(
                postId: chapterId, postType: "chapter", postPage: postPage,
                text: t, commentLevel: level, parentComment: replyingTo?.id,
                siteId: siteId
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
            let v = try await service.voteComment(id: comment.id, direction: isUp ? 1 : 0, siteId: siteId)
            comments[idx].votesUp = v.up
            comments[idx].votesDown = v.down
            comments[idx].userVote = v.user
            return true
        } catch { return false }
    }
}
