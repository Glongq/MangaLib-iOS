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

    /// "Поиск по имени" — ПОДТВЕРЖДЕНО перехватом `&q=` на всех трёх формах
    /// `GET /friendship` (друзья/входящие/исходящие). У /mutual поиск не
    /// перехвачен — не применяется на табе "Общие".
    @Published var query: String = "" {
        didSet { if oldValue != query { scheduleSearchReload() } }
    }
    private var searchTask: Task<Void, Never>?
    private let searchDebounce: Duration = .milliseconds(350)

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

    // MARK: Кэш с таймаутом (по прямой просьбе: "не обновляло при каждом
    // заходе список") — FriendsViewModel пересоздаётся с нуля при каждом
    // повторном заходе на экран (обычный push, не "живущий" под-экран
    // профиля), поэтому didLoad*-флаги сами по себе не спасают — кэш
    // намеренно static (переживает пересоздание ViewModel), с TTL, а не
    // навсегда: первая свежая сетевая загрузка обновляет и список, и кэш.
    // .refreshable (см. FriendsView) всегда идёт в сеть напрямую, минуя
    // кэш, и сам его обновляет. Кэшируется только НЕотфильтрованный
    // результат (query пуст) — активный поиск в кэш не попадает.
    private struct CachedList {
        let items: [FriendshipEntry]
        let hasNext: Bool
        let loadedAt: Date
    }
    private static var cache: [String: CachedList] = [:]
    private static let cacheTTL: TimeInterval = 90

    private func cacheKey(_ t: Tab) -> String { "\(userId):\(t)" }

    /// Свежий (моложе cacheTTL) результат таба — применяет мгновенно, без
    /// сети, и возвращает true.
    private func tryUseCache(_ t: Tab) -> Bool {
        guard query.isEmpty, let cached = Self.cache[cacheKey(t)],
              Date().timeIntervalSince(cached.loadedAt) < Self.cacheTTL else { return false }
        switch t {
        case .friends:  friends = cached.items;  friendsHasNext = cached.hasNext;  didLoadFriends = true
        case .mutual:   mutual = cached.items;   mutualHasNext = cached.hasNext;   didLoadMutual = true
        case .incoming: incoming = cached.items; incomingHasNext = cached.hasNext; didLoadIncoming = true
        case .outgoing: outgoing = cached.items; outgoingHasNext = cached.hasNext; didLoadOutgoing = true
        }
        return true
    }

    private func saveCache(_ t: Tab, items: [FriendshipEntry], hasNext: Bool) {
        guard query.isEmpty else { return }
        Self.cache[cacheKey(t)] = CachedList(items: items, hasNext: hasNext, loadedAt: Date())
    }

    private func invalidateCache(_ t: Tab) { Self.cache.removeValue(forKey: cacheKey(t)) }

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

    func selectTab(_ t: Tab) {
        guard tab != t else { return }
        tab = t
        // Активный поиск переживает переключение таба — активная строка
        // должна отфильтровать и новый таб, а не показать его "как есть"
        // (didLoad* иначе решил бы, что грузить нечего, и оставил бы
        // немного другой — незафильтрованный — прошлый результат).
        Task { await loadIfNeeded(force: !query.isEmpty) }
    }

    /// Debounce поиска (см. query.didSet) — перезагружает ТЕКУЩИЙ таб (кроме
    /// "Общие" — там q не подтверждён, см. reloadMutual).
    private func scheduleSearchReload() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.searchDebounce) } catch { return }
            switch self.tab {
            case .friends:  await self.reloadFriends()
            case .mutual:   return
            case .incoming: await self.reloadIncoming()
            case .outgoing: await self.reloadOutgoing()
            }
        }
    }

    func loadIfNeeded(force: Bool = false) async {
        switch tab {
        case .friends:
            guard force || (!didLoadFriends && !isLoading) else { return }
            if !force, tryUseCache(.friends) { return }
            await reloadFriends()
        case .mutual:
            guard !didLoadMutual, !isLoading else { return }
            if tryUseCache(.mutual) { return }
            await reloadMutual()
        case .incoming:
            guard force || (!didLoadIncoming && !isLoading) else { return }
            if !force, tryUseCache(.incoming) { return }
            await reloadIncoming()
        case .outgoing:
            guard force || (!didLoadOutgoing && !isLoading) else { return }
            if !force, tryUseCache(.outgoing) { return }
            await reloadOutgoing()
        }
    }

    /// Свайп-обновление (см. FriendsView.refreshable) — ВСЕГДА идёт в сеть
    /// напрямую (минуя кэш), но обновлённым результатом сам же кэш и
    /// перезаписывает (см. reload* ниже).
    func refreshCurrentTab() async {
        switch tab {
        case .friends:  await reloadFriends()
        case .mutual:   await reloadMutual()
        case .incoming: await reloadIncoming()
        case .outgoing: await reloadOutgoing()
        }
    }

    func reloadFriends() async {
        isLoading = true; errorMessage = nil; friendsPage = 1; friendsHasNext = true
        do {
            let r = try await service.fetchFriends(userId: userId, page: 1, query: query)
            friends = r.friends
            friendsHasNext = r.hasNextPage
            didLoadFriends = true
            saveCache(.friends, items: friends, hasNext: friendsHasNext)
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
            saveCache(.mutual, items: mutual, hasNext: mutualHasNext)
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
            let r = try await service.fetchFriendRequests(userId: userId, incoming: true, page: 1, query: query)
            incoming = r.requests
            incomingHasNext = r.hasNextPage
            didLoadIncoming = true
            saveCache(.incoming, items: incoming, hasNext: incomingHasNext)
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
        if tryUseCache(.incoming) { return }
        if let r = try? await service.fetchFriendRequests(userId: userId, incoming: true, page: 1) {
            incoming = r.requests
            incomingHasNext = r.hasNextPage
            saveCache(.incoming, items: incoming, hasNext: incomingHasNext)
        }
        didLoadIncoming = true
    }

    func reloadOutgoing() async {
        isLoading = true; errorMessage = nil; outgoingPage = 1; outgoingHasNext = true
        do {
            let r = try await service.fetchFriendRequests(userId: userId, incoming: false, page: 1, query: query)
            outgoing = r.requests
            outgoingHasNext = r.hasNextPage
            didLoadOutgoing = true
            saveCache(.outgoing, items: outgoing, hasNext: outgoingHasNext)
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
                let r = try await service.fetchFriends(userId: userId, page: next, query: query)
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
                let r = try await service.fetchFriendRequests(userId: userId, incoming: true, page: next, query: query)
                let existing = Set(incoming.map(\.id))
                incoming.append(contentsOf: r.requests.filter { !existing.contains($0.id) })
                incomingPage = next; incomingHasNext = r.hasNextPage
            } catch {}
        case .outgoing:
            guard outgoingHasNext else { return }
            isLoadingMore = true
            let next = outgoingPage + 1
            do {
                let r = try await service.fetchFriendRequests(userId: userId, incoming: false, page: next, query: query)
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
            invalidateCache(.incoming)
            if accept {
                // Приняли — запись переезжает в "Друзья", но только если тот
                // список уже когда-то грузился (иначе он подтянется сам при
                // первом открытии таба).
                if didLoadFriends { friends.insert(entry, at: 0) }
                invalidateCache(.friends)
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
            invalidateCache(.outgoing)
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
            invalidateCache(.incoming)
            invalidateCache(.friends)
            didLoadFriends = false
            if tab == .friends { await reloadFriends() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isAcceptingAll = false
    }
}
