import Foundation

/// ViewModel поиска манги с debounce (~300ms), чтобы не перегружать сервер.
@MainActor
final class SearchViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [MangaItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private let service: MangaNetworkService
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?

    init(service: MangaNetworkService = .shared, debounceMilliseconds: Int = 300) {
        self.service = service
        self.debounce = .milliseconds(debounceMilliseconds)
    }

    /// Планирует поиск с задержкой; предыдущий отложенный/выполняемый запрос отменяется.
    private func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.debounce)   // debounce
            } catch {
                return // задача отменена во время ожидания
            }
            await self.runSearch(query: trimmed)
        }
    }

    /// Немедленный поиск (например, по нажатию Enter).
    func searchNow() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { [weak self] in
            await self?.runSearch(query: trimmed)
        }
    }

    private func runSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let items = try await service.searchManga(query: query)
            guard !Task.isCancelled else { return }
            results = items
        } catch NetworkError.cancelled {
            // намеренная отмена — состояние не трогаем
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
