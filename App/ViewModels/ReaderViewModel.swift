import Foundation

/// ViewModel ридера: страницы текущей главы + переключение между главами.
@MainActor
final class ReaderViewModel: ObservableObject {

    @Published private(set) var pages: [PageItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentIndex: Int

    /// Пришёл ли сервер уже с отметкой "просмотрено" для текущей главы (см.
    /// ChapterPagesResult.isViewed) — если да, повторный markChapterViewed
    /// не отправляем, он не нужен.
    private var currentChapterAlreadyViewed = false

    /// Триггер тоста "Добавлено в закладки" (см. recordProgress ниже) —
    /// View наблюдает за этим флагом и показывает короткую анимацию, когда
    /// он становится true; сам себя сбрасывает обратно в false через
    /// небольшую паузу, View ничего таймером считать не должно.
    @Published private(set) var justAddedToReading = false

    let slug: String
    let chapters: [ChapterItem]
    /// Числовой id тайтла — нужен ТОЛЬКО для реальной отметки главы
    /// просмотренной в аккаунте (см. recordProgress ниже); slug для этого
    /// не годится, эндпоинт требует именно numeric id.
    private let mangaId: Int?
    private let mangaTitle: String?
    private let coverURL: String?
    private let service: MangaNetworkService

    init(slug: String,
         chapters: [ChapterItem],
         startIndex: Int,
         mangaId: Int? = nil,
         mangaTitle: String? = nil,
         coverURL: String? = nil,
         service: MangaNetworkService = .shared) {
        self.slug = slug
        self.chapters = chapters
        self.currentIndex = min(max(startIndex, 0), max(chapters.count - 1, 0))
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.coverURL = coverURL
        self.service = service
    }

    var currentChapter: ChapterItem? {
        guard chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    var hasPrevious: Bool { currentIndex > 0 }
    var hasNext: Bool { currentIndex < chapters.count - 1 }

    func imageURLs(for page: PageItem) -> [URL] { MangaImageURL.pageURLs(for: page) }

    /// Загрузить страницы текущей главы и записать прогресс.
    func load() async {
        guard let chapter = currentChapter else { return }
        // Сброс: пока не знаем isViewed для этой (возможно, новой) главы —
        // recordProgress() ниже должен считать её ещё не подтверждённой и
        // всё равно отправить markChapterViewed, а не полагаться на
        // значение с ПРЕДЫДУЩЕЙ главы.
        currentChapterAlreadyViewed = false
        recordProgress()
        isLoading = true
        errorMessage = nil
        pages = []
        do {
            let result = try await service.fetchPages(
                slug: slug,
                volume: chapter.volume,
                number: chapter.number,
                branchId: chapter.primaryBranchId
            )
            pages = result.pages
            currentChapterAlreadyViewed = result.isViewed
        } catch NetworkError.cancelled {
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Перейти к главе по индексу.
    func goTo(index: Int) async {
        guard chapters.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        await load()
    }

    /// Отметить текущую главу как последнюю прочитанную.
    func markProgress() { recordProgress() }

    private func recordProgress() {
        guard let chapter = currentChapter else { return }
        BookmarksStore.shared.setProgress(
            slug: slug,
            chapterNumber: chapter.number,
            chapterVolume: chapter.volume,
            readCount: currentIndex + 1,
            total: chapters.count
        )

        // Как на реальном сайте: открыл главу — тайтл автоматически уходит в
        // «Читаю» (status: 1), подтверждено реальным перехваченным ответом
        // POST .../view (объект "manga_bookmark" со status:1 в data). НО
        // только если тайтл ещё НИГДЕ не лежит в закладках — если пользователь
        // уже сам переложил его в "Прочитано"/"Любимые"/куда угодно, не
        // затираем этот осознанный выбор при каждом повторном чтении главы.
        if !currentChapterAlreadyViewed, !BookmarksStore.shared.isBookmarked(slug: slug) {
            BookmarksStore.shared.add(
                slug: slug,
                title: mangaTitle ?? slug,
                coverURL: coverURL,
                toFolder: BookmarkFolder.reading.id
            )
            justAddedToReading = true
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                justAddedToReading = false
            }
        }

        // Локальный прогресс сохранён выше — а это реальная, подтверждённая
        // отметка главы просмотренной в аккаунте (см.
        // MangaNetworkService.markChapterViewed — настоящий эндпоинт,
        // перехваченный из Network сайта; предыдущая версия через скрытый
        // WebView была лишь приближением и больше не нужна).
        // Пропускаем, если сервер уже прислал is_viewed=true для этой главы
        // (см. load()) — незачем слать POST повторно (например, когда
        // markProgress() срабатывает ещё раз при долистывании той же главы).
        if let mangaId, !currentChapterAlreadyViewed {
            Task {
                do {
                    try await MangaNetworkService.shared.markChapterViewed(mangaId: mangaId, chapterId: chapter.id)
                } catch {
                    print("[ReaderViewModel] не удалось отметить главу просмотренной на сервере: \(error)")
                }
            }
        }
    }
}
