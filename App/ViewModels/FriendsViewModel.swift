import Foundation

/// ViewModel вкладки «Друзья» в профиле: список друзей (GET /friendship?
/// user_id=&status=1) и общие друзья (GET /friendship/{userId}/mutual) —
/// это доступно на ЛЮБОМ профиле. На СВОЁМ (isOwnAccount) добавляются ещё
/// два таба — входящие/исходящие заявки (GET /friendship?status=0&sender=),
/// эти списки чужие смотреть не могут (сервер их и не отдаст для чужого
/// user_id — заявки видит только сам получатель/отправитель). Переключение —
/// табом внизу экрана (см. FriendsView.tabBar).
@MainActor
final class FriendsViewModel: ObservableObject {

    enum Tab: Equatable { case friends, mutual, incoming, outgoing }

    @Published var tab: Tab = .friends

    @Published private(set) var friends: [FriendshipEntry] = []
    @Published private(set) var mutual: [FriendshipEntry] = []
    @Published private(set) var incoming: [FriendshipEntry] = []
    @Published private(set) var outgoing: [FriendshipEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadFriends = false
    @Published private(set) var didLoadMutual = false
    @Published private(set) var didLoadIncoming = false
    @Published private(set) var didLoadOutgoing = false
    @Published private(set) var errorMessage: String?

    /// id записи дружбы, для которой сейчас идёт accept/decline/отмена —
    /// блокирует повторный тап именно по ЭТОЙ строке, не по всему экрану.
    @Published private(set) var respondingIds: Set<Int> = []
    @Published private(set) var isAcceptingAll = false

    private let service = MangaNetworkService.shared
    let userId: Int
    init(userId: Int) { self.userId = userId }

    /// Входящие/исходящие заявки — не чужая приватность, а собственные
    /// заявки текущего аккаунта, поэтому имеют смысл только когда смотрим
    /// СВОЙ профиль.
    var isOwnAccount: Bool { userId == AuthSession.shared.userId }

    private var friendsPage = 1
    private var friendsHasNext = true
    private var mutualPage = 1
    private var mutualHasNext = true
    private var incomingPage = 1
    private var incomingHasNext = true
    private var outgoingPage = 1
    private var outgoingHasNext = true

    var visible: [FriendshipEntry] {
        switch tab {
        case .friends:  return friends
        case .mutual:   return mutual
        case .incoming: return incoming
        case .outgoing: return outgoing
        }
    }

    var didLoadCurrent: Bool {
        switch tab {
        case .friends:  return didLoadFriends
        case .mutual:   return didLoadMutual
        case .incoming: return didLoadIncoming
        case .outgoing: return didLoadOutgoing
        }
    }

    func loadIfNeeded() async {
        switch tab {
        case .friends:
            guard !didLoadFriends, !isLoading else { return }
            await reloadFriends()
        case .mutual:
            guard !didLoadMutual, !isLoading else { return }
            await reloadMutual()
        case .incoming:
            guard !didLoadIncoming, !isLoading else { return }
            await reloadIncoming()
        case .outgoing:
            guard !didLoadOutgoing, !isLoading else { return }
            await reloadOutgoing()
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

    func reloadIncoming() async {
        isLoading = true; errorMessage = nil; incomingPage = 1; incomingHasNext = true
        do {
            let r = try await service.fetchFriendRequests(userId: userId, incoming: true, page: 1)
            incoming = r.requests
            incomingHasNext = r.hasNextPage
            didLoadIncoming = true
        } catch NetworkError.cancelled {
        } catch {
            incoming = []; didLoadIncoming = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Тихая фоновая подгрузка входящих — только для бейджа на табе
    /// "Входящие" (см. FriendsView.tabBar), НЕ трогает isLoading/errorMessage
    /// (та же гонка, что и у обычных reload*, здесь не нужна: идёт молча,
    /// параллельно с loadIfNeeded() активного таба, скелетон/ошибку рисует
    /// только последний). Если таб "Входящие" потом открыть — loadIfNeeded()
    /// увидит didLoadIncoming уже true и просто переиспользует эти данные.
    func prefetchIncomingCount() async {
        guard !didLoadIncoming else { return }
        if let r = try? await service.fetchFriendRequests(userId: userId, incoming: true, page: 1) {
            incoming = r.requests
            incomingHasNext = r.hasNextPage
        }
        didLoadIncoming = true
    }

    func reloadOutgoing() async {
        isLoading = true; errorMessage = nil; outgoingPage = 1; outgoingHasNext = true
        do {
            let r = try await service.fetchFriendRequests(userId: userId, incoming: false, page: 1)
            outgoing = r.requests
            outgoingHasNext = r.hasNextPage
            didLoadOutgoing = true
        } catch NetworkError.cancelled {
        } catch {
            outgoing = []; didLoadOutgoing = true
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
        case .incoming:
            guard incomingHasNext else { return }
            isLoadingMore = true
            let next = incomingPage + 1
            do {
                let r = try await service.fetchFriendRequests(userId: userId, incoming: true, page: next)
                let existing = Set(incoming.map(\.id))
                incoming.append(contentsOf: r.requests.filter { !existing.contains($0.id) })
                incomingPage = next; incomingHasNext = r.hasNextPage
            } catch {}
        case .outgoing:
            guard outgoingHasNext else { return }
            isLoadingMore = true
            let next = outgoingPage + 1
            do {
                let r = try await service.fetchFriendRequests(userId: userId, incoming: false, page: next)
                let existing = Set(outgoing.map(\.id))
                outgoing.append(contentsOf: r.requests.filter { !existing.contains($0.id) })
                outgoingPage = next; outgoingHasNext = r.hasNextPage
            } catch {}
        }
        isLoadingMore = false
    }

    // MARK: Действия над заявками (см. MangaNetworkService.respondToFriendRequest/cancelFriendRequest)

    /// Принять/отклонить входящую заявку — убирает строку из списка сразу
    /// по успеху (не ждём полной перезагрузки, реакция должна быть мгновенной).
    func respond(to entry: FriendshipEntry, accept: Bool) async {
        guard !respondingIds.contains(entry.id) else { return }
        respondingIds.insert(entry.id)
        do {
            _ = try await service.respondToFriendRequest(id: entry.id, accept: accept)
            incoming.removeAll { $0.id == entry.id }
            if accept {
                // Приняли — запись переезжает в "Друзья", но только если тот
                // список уже когда-то грузился (иначе он подтянется сам при
                // первом открытии таба).
                if didLoadFriends { friends.insert(entry, at: 0) }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        respondingIds.remove(entry.id)
    }

    /// Отменить СВОЮ исходящую заявку — тот же DELETE /friendship/{id}, что
    /// и разрыв дружбы (см. cancelFriendRequest).
    func cancelOutgoing(_ entry: FriendshipEntry) async {
        guard !respondingIds.contains(entry.id) else { return }
        respondingIds.insert(entry.id)
        do {
            try await service.cancelFriendRequest(friendshipId: entry.id)
            outgoing.removeAll { $0.id == entry.id }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        respondingIds.remove(entry.id)
    }

    /// "Принять все" — см. MangaNetworkService.acceptAllFriendRequests
    /// (bulk, без списка записей в ответе) — после успеха просто
    /// перезагружаем оба зависимых списка.
    func acceptAll() async {
        guard !isAcceptingAll, !incoming.isEmpty else { return }
        isAcceptingAll = true
        do {
            try await service.acceptAllFriendRequests()
            incoming = []
            didLoadFriends = false
            if tab == .friends { await reloadFriends() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isAcceptingAll = false
    }
}
