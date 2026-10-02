import Foundation

/// ViewModel экрана "Коллекции" (Меню → Каталог → Коллекции) — общая лента
/// коллекций сайта, без привязки к пользователю. Данные: GET /collections
/// (см. MangaNetworkService.fetchCollections).
@MainActor
final class CollectionsListViewModel: ObservableObject {

    /// Сортировка — ПОДТВЕРЖДЕНО перехватом только `.newest` (`sort_by=
    /// newest`). Остальные четыре — по прямой просьбе, ТОЧНЫЕ серверные
    /// значения `sort_by`/`period` НЕ пойманы перехватом ни разу — разумная
    /// догадка по аналогии с /media/top-views?time=day|week|month (см.
    /// TopViewsPeriod). Если сервер ответит 422 — fetchPage ниже тихо
    /// повторяет запрос вовсе без sort_by/period (см. её же приём в
    /// TeamViewModel/DirectoryListViewModel).
    enum Sort: String, CaseIterable, Identifiable {
        case newest, popularAllTime, popularYear, popularSeason, popularWeek
        var id: String { rawValue }

        var title: String {
            switch self {
            case .newest:         return "Новые"
            case .popularAllTime: return "Популярные за всё время"
            case .popularYear:    return "Популярные за год"
            case .popularSeason:  return "Популярные за сезон"
            case .popularWeek:    return "Популярные за неделю"
            }
        }

        var sortBy: String {
            switch self {
            case .newest: return "newest"
            default:      return "popular"
            }
        }

        var period: String? {
            switch self {
            case .popularYear:   return "year"
            case .popularSeason: return "season"
            case .popularWeek:   return "week"
            default:             return nil
            }
        }
    }

    @Published var sort: Sort = .newest {
        didSet { if oldValue != sort { Task { await reload() } } }
    }

    @Published private(set) var collections: [MangaCollection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var errorMessage: String?

    private let service = MangaNetworkService.shared
    private var page = 1
    private var hasNext = true

    func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    func reload() async {
        isLoading = true; errorMessage = nil; page = 1; hasNext = true
        do {
            let r = try await fetchPage(1)
            collections = r.collections
            hasNext = r.hasNextPage
            didLoad = true
        } catch NetworkError.cancelled {
        } catch {
            collections = []
            didLoad = true
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
            let r = try await fetchPage(next)
            let existing = Set(collections.map(\.id))
            collections.append(contentsOf: r.collections.filter { !existing.contains($0.id) })
            page = next
            hasNext = r.hasNextPage
        } catch {}
        isLoadingMore = false
    }

    private func fetchPage(_ page: Int) async throws -> (collections: [MangaCollection], hasNextPage: Bool) {
        do {
            return try await service.fetchCollections(page: page, sortBy: sort.sortBy, period: sort.period)
        } catch NetworkError.server(let status) where status == 422 {
            return try await service.fetchCollections(page: page, sortBy: nil, period: nil)
        }
    }
}
