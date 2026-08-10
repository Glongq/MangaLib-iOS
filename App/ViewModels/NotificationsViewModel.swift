import Foundation

/// ViewModel вкладки "Уведомления" — грузит реальный `GET /notifications`
/// (см. MangaNetworkService.fetchNotifications) с фильтром по прочитанности
/// (readFilter → read_type) и сортировкой (sortOrder → sort_type), плюс
/// параллельно счётчики `GET /notifications/count` (пока только для
/// возможного бейджа в будущем — сейчас не отображаются нигде специально).
///
/// Обновление "при каждом заходе в приложение" реализовано на уровне View
/// (NotificationsView): `.task` при первом появлении + `.onChange(of:
/// scenePhase)` при возврате из фона — здесь просто есть публичный refresh(),
/// защищённый от повторного параллельного запуска через isLoading.
@MainActor
final class NotificationsViewModel: ObservableObject {

    @Published private(set) var items: [NotificationItem] = []
    @Published private(set) var counts: NotificationCounts?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var hasMore = false

    @Published var readFilter: NotificationReadFilter = .unread {
        didSet {
            guard oldValue != readFilter else { return }
            Task { await refresh() }
        }
    }
    @Published var sortOrder: NotificationSortOrder = .desc {
        didSet {
            guard oldValue != sortOrder else { return }
            Task { await refresh() }
        }
    }

    private var page = 1
    private let service: MangaNetworkService

    init(service: MangaNetworkService = .shared) {
        self.service = service
    }

    /// Полная перезагрузка с первой страницы — вызывается и при первом
    /// появлении экрана, и при возврате из фона, и потянуть-обновить, и при
    /// смене фильтра/сортировки (см. didSet выше). Игнорирует повторный
    /// вызов, пока предыдущий ещё не завершился, чтобы автообновление по
    /// scenePhase и ручной pull-to-refresh не гонялись друг с другом.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        page = 1
        async let listResult: Void = loadList(page: 1, append: false)
        async let countsResult: Void = loadCounts()
        _ = await (listResult, countsResult)
        hasLoadedOnce = true
        isLoading = false
    }

    /// Подгрузка следующей страницы — вызывать из `.onAppear` последнего
    /// показанного элемента списка.
    func loadMoreIfNeeded(current: NotificationItem) async {
        guard hasMore, !isLoading, current.id == items.last?.id else { return }
        isLoading = true
        await loadList(page: page + 1, append: true)
        isLoading = false
    }

    private func loadList(page requestedPage: Int, append: Bool) async {
        do {
            let result = try await service.fetchNotifications(
                readType: readFilter.rawValue, sortType: sortOrder.rawValue, page: requestedPage
            )
            if append {
                items.append(contentsOf: result.items)
            } else {
                items = result.items
            }
            hasMore = result.hasNextPage
            page = requestedPage
        } catch NetworkError.cancelled {
            // Экран закрыли/задача отменена — не показываем ошибку.
        } catch {
            // При подгрузке следующей страницы не затираем уже показанный
            // список баннером ошибки — только при самой первой загрузке.
            if !append {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadCounts() async {
        counts = try? await service.fetchNotificationCounts()
    }
}
