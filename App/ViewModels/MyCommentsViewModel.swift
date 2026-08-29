import Foundation

/// ViewModel экрана «Мои комментарии»: список комментариев аккаунта с серверной
/// сортировкой (по времени, sort_type=asc/desc), клиентским фильтром по типу
/// (все/тайтлы/главы/форум — точные серверные параметры фильтров не
/// подтверждены перехватом, поэтому фильтруем на клиенте) и пагинацией.
@MainActor
final class MyCommentsViewModel: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case all, titles, chapters, forum
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Все"
            case .titles: return "Тайтлы"
            case .chapters: return "Главы"
            case .forum: return "Форум"
            }
        }
        func matches(_ c: UserComment) -> Bool {
            switch self {
            case .all: return true
            case .titles: return c.relationType == "manga"
            case .chapters: return c.relationType == "chapter"
            case .forum: return c.relationType == "discussion"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest
        var id: String { rawValue }
        var title: String { self == .newest ? "Сначала новые" : "Сначала старые" }
        var sortType: String { self == .newest ? "desc" : "asc" }
    }

    @Published var filter: Filter = .all
    @Published var sort: Sort = .newest {
        didSet { if oldValue != sort { Task { await reload() } } }
    }

    @Published private(set) var comments: [UserComment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?
    /// Раньше "нужно войти" шло тем же errorMessage, что и сетевая
    /// ошибка — экран показывал их ОДНОЙ веткой с иконкой wifi, хотя это
    /// разные по смыслу состояния. Отдельный флаг — свой экран/иконка.
    @Published private(set) var needsLogin = false

    private let service = MangaNetworkService.shared
    private var page = 1
    private var hasNext = true

    /// id пользователя, чьи комментарии показываем (nil — свой аккаунт).
    private let explicitUserId: Int?
    init(userId: Int? = nil) { self.explicitUserId = userId }

    /// Отфильтрованный на клиенте список (по типу связи).
    var visible: [UserComment] { comments.filter { filter.matches($0) } }

    private var userId: Int? { explicitUserId ?? AuthSession.shared.userId }

    // MARK: Кэш с таймаутом (см. FriendsViewModel — тот же приём и тот же
    // повод: экран пересоздаёт ViewModel с нуля при каждом повторном
    // заходе, didLoad сам по себе не спасает от лишнего запроса). static —
    // переживает пересоздание ViewModel, TTL — не подвисает навсегда.
    // .refreshable (см. MyCommentsView) идёт в сеть напрямую и сам
    // обновляет кэш через reload().
    private struct CachedComments {
        let items: [UserComment]
        let hasNext: Bool
        let loadedAt: Date
    }
    private static var cache: [String: CachedComments] = [:]
    private static let cacheTTL: TimeInterval = 90

    private func cacheKey() -> String? { userId.map { "\($0):\(sort.rawValue)" } }

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        if let key = cacheKey(), let cached = Self.cache[key],
           Date().timeIntervalSince(cached.loadedAt) < Self.cacheTTL {
            comments = cached.items
            hasNext = cached.hasNext
            didLoad = true
            return
        }
        await reload()
    }

    func reload() async {
        guard let uid = userId else { needsLogin = true; didLoad = true; return }
        needsLogin = false
        isLoading = true; errorMessage = nil; page = 1; hasNext = true
        do {
            let r = try await service.fetchUserComments(userId: uid, page: 1, sortType: sort.sortType)
            comments = r.comments
            hasNext = r.hasNextPage
            didLoad = true
            if let key = cacheKey() {
                Self.cache[key] = CachedComments(items: comments, hasNext: hasNext, loadedAt: Date())
            }
        } catch NetworkError.cancelled {
        } catch {
            comments = []
            didLoad = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: UserComment) async {
        guard hasNext, !isLoading, !isLoadingMore, let uid = userId else { return }
        // Догружаем, когда показан один из последних ЗАГРУЖЕННЫХ (не отфильтрованных).
        guard comments.suffix(4).contains(where: { $0.id == current.id }) else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            let r = try await service.fetchUserComments(userId: uid, page: next, sortType: sort.sortType)
            let existing = Set(comments.map(\.id))
            comments.append(contentsOf: r.comments.filter { !existing.contains($0.id) })
            page = next
            hasNext = r.hasNextPage
        } catch {}
        isLoadingMore = false
    }

    /// Удалить свой комментарий (DELETE /comments/{id}) и убрать из списка.
    @discardableResult
    func delete(_ comment: UserComment) async -> Bool {
        do {
            try await service.deleteComment(id: comment.id)
            comments.removeAll { $0.id == comment.id }
            if let key = cacheKey() { Self.cache.removeValue(forKey: key) }
            return true
        } catch {
            return false
        }
    }
}
