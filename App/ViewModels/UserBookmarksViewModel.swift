import Foundation

/// ViewModel вкладки «Списки тайтлов» в профиле ДРУГОГО пользователя: сначала
/// его папки закладок (с количеством в каждой), потом — пагинируемый список
/// тайтлов выбранной папки. GET /bookmarks/folder/{userId} и GET /bookmarks?
/// status=&user_id=&page=.
@MainActor
final class UserBookmarksViewModel: ObservableObject {

    @Published private(set) var folders: [UserBookmarkFolder] = []
    @Published var selectedFolderId: Int?
    @Published private(set) var items: [BookmarkListEntry] = []
    @Published private(set) var isLoadingFolders = false
    @Published private(set) var isLoadingItems = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoadFolders = false
    @Published private(set) var errorMessage: String?

    private let service = MangaNetworkService.shared
    let userId: Int
    init(userId: Int) { self.userId = userId }

    private var page = 1
    private var hasNext = true

    func loadFoldersIfNeeded() async {
        guard !didLoadFolders, !isLoadingFolders else { return }
        isLoadingFolders = true; errorMessage = nil
        do {
            let list = try await service.fetchUserBookmarkFolders(userId: userId)
            folders = list.filter { $0.count > 0 }
            didLoadFolders = true
            if selectedFolderId == nil { selectedFolderId = folders.first?.id }
            if let id = selectedFolderId { await reloadItems(folderId: id) }
        } catch NetworkError.cancelled {
        } catch {
            didLoadFolders = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingFolders = false
    }

    func selectFolder(_ id: Int) {
        guard selectedFolderId != id else { return }
        selectedFolderId = id
        Task { await reloadItems(folderId: id) }
    }

    func reloadItems(folderId: Int) async {
        isLoadingItems = true; errorMessage = nil; page = 1; hasNext = true
        do {
            let r = try await service.fetchUserBookmarks(userId: userId, folderId: folderId, page: 1)
            items = r.items
            hasNext = r.hasNextPage
        } catch NetworkError.cancelled {
        } catch {
            items = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingItems = false
    }

    func loadMoreIfNeeded(current: BookmarkListEntry) async {
        guard hasNext, !isLoadingItems, !isLoadingMore, let folderId = selectedFolderId else { return }
        guard items.suffix(6).contains(where: { $0.id == current.id }) else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            let r = try await service.fetchUserBookmarks(userId: userId, folderId: folderId, page: next)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: r.items.filter { !existing.contains($0.id) })
            page = next
            hasNext = r.hasNextPage
        } catch {}
        isLoadingMore = false
    }
}
