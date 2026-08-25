import Foundation

/// ViewModel вкладки «Друзья» в профиле: два независимых пагинируемых списка —
/// сам список друзей (GET /friendship?user_id=&status=1) и общие друзья
/// (GET /friendship/{userId}/mutual) — переключаются табом внизу экрана.
@MainActor
final class FriendsViewModel: ObservableObject {

    enum Tab: Equatable { case friends, mutual }

    @Published var tab: Tab = .friends

    @Published private(set) var friends: [FriendshipEntry] = []
    @Published private(set) var mutual: [FriendshipEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadFriends = false
    @Published private(set) var didLoadMutual = false
    @Published private(set) var errorMessage: String?

    private let service = MangaNetworkService.shared
    let userId: Int
    init(userId: Int) { self.userId = userId }

    private var friendsPage = 1
    private var friendsHasNext = true
    private var mutualPage = 1
    private var mutualHasNext = true

    var visible: [FriendshipEntry] { tab == .friends ? friends : mutual }
    var didLoadCurrent: Bool { tab == .friends ? didLoadFriends : didLoadMutual }

    func loadIfNeeded() async {
        switch tab {
        case .friends:
            guard !didLoadFriends, !isLoading else { return }
            await reloadFriends()
        case .mutual:
            guard !didLoadMutual, !isLoading else { return }
            await reloadMutual()
        }
    }

    func selectTab(_ t: Tab) {
        guard tab != t else { return }
        tab = t
        Task { await loadIfNeeded() }
    }

    func reloadFriends() async {
        isLoading = true; errorMessage = nil; friendsPage = 1; friendsHasNext = true
        do {
            let r = try await service.fetchFriends(userId: userId, page: 1)
            friends = r.friends
            friendsHasNext = r.hasNextPage
            didLoadFriends = true
        } catch NetworkError.cancelled {
        } catch {
            friends = []; didLoadFriends = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func reloadMutual() async {
        isLoading = true; errorMessage = nil; mutualPage = 1; mutualHasNext = true
        do {
            let r = try await service.fetchMutualFriends(userId: userId, page: 1)
            mutual = r.friends
            mutualHasNext = r.hasNextPage
            didLoadMutual = true
        } catch NetworkError.cancelled {
        } catch {
            mutual = []; didLoadMutual = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current: FriendshipEntry) async {
        guard !isLoading, !isLoadingMore else { return }
        guard visible.suffix(4).contains(where: { $0.id == current.id }) else { return }
        switch tab {
        case .friends:
            guard friendsHasNext else { return }
            isLoadingMore = true
            let next = friendsPage + 1
            do {
                let r = try await service.fetchFriends(userId: userId, page: next)
                let existing = Set(friends.map(\.id))
                friends.append(contentsOf: r.friends.filter { !existing.contains($0.id) })
                friendsPage = next; friendsHasNext = r.hasNextPage
            } catch {}
        case .mutual:
            guard mutualHasNext else { return }
            isLoadingMore = true
            let next = mutualPage + 1
            do {
                let r = try await service.fetchMutualFriends(userId: userId, page: next)
                let existing = Set(mutual.map(\.id))
                mutual.append(contentsOf: r.friends.filter { !existing.contains($0.id) })
                mutualPage = next; mutualHasNext = r.hasNextPage
            } catch {}
        }
        isLoadingMore = false
    }
}
