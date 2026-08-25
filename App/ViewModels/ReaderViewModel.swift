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

    /// Текст тоста закладки в ридере ("Добавлено в закладки" / "Убрано из
    /// закладок"); nil — тост скрыт. Ставится по кнопке (см. setBookmark),
    /// сам сбрасывается через пару секунд. View показывает его в верхней
    /// панели вместо названия тайтла.
    @Published private(set) var bookmarkToast: String?

    let slug: String
    let chapters: [ChapterItem]
    /// Числовой id тайтла — нужен ТОЛЬКО для реальной отметки главы
    /// просмотренной в аккаунте (см. recordProgress ниже); slug для этого
    /// не годится, эндпоинт требует именно numeric id.
    private let mangaId: Int?
    private let mangaTitle: String?
    private let coverURL: String?
    private let service: MangaNetworkService
    /// Выбранная ветка перевода (команда). branch_id стабилен для команды по
    /// всему тайтлу, поэтому применяется ко всем главам. nil — брать первую
    /// ветку главы (primaryBranchId), как раньше. @Published, а не let —
    /// переводчика можно сменить прямо в читалке (см. setPreferredBranch),
    /// и меню списка глав читает текущее значение, чтобы отметить выбор.
    @Published private(set) var preferredBranchId: Int?
    /// Сайт тайтла (site_id) — страницы главы у тайтла с другого сайта надо
    /// запрашивать с его Site-Id, иначе 404 (см. MangaDetailViewModel.siteId).
    /// Не private — MangaReaderView передаёт его дальше в ChapterCommentsSheet
    /// (комментарии к главе — тот же тайтл, тот же сайт, см. fetchComments(siteId:)).
    let siteId: Int?

    init(slug: String,
         chapters: [ChapterItem],
         startIndex: Int,
         mangaId: Int? = nil,
         mangaTitle: String? = nil,
         coverURL: String? = nil,
         preferredBranchId: Int? = nil,
         siteId: Int? = nil,
         service: MangaNetworkService = .shared) {
        self.slug = slug
        self.chapters = chapters
        self.currentIndex = min(max(startIndex, 0), max(chapters.count - 1, 0))
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.coverURL = coverURL
        self.preferredBranchId = preferredBranchId
        self.siteId = siteId
        self.service = service
    }

    /// Ветка для текущей главы: выбранная команда, иначе первая ветка главы.
    private func branchId(for chapter: ChapterItem) -> Int? {
        preferredBranchId ?? chapter.primaryBranchId
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

        // Оффлайн/скачано: если у главы есть локально сохранённые страницы —
        // читаем их с диска, вообще не обращаясь к сети (см. DownloadsManager).
        // PageItem.url = file://… ; RemoteImage/MangaImageURL отдают такой URL
        // как есть, а RemoteImageLoader читает картинку прямо с диска.
        let bid = branchId(for: chapter)
        let localFiles = DownloadsManager.shared.localPageFiles(slug: slug, chapterId: chapter.id, branchId: bid)
        if !localFiles.isEmpty {
            pages = localFiles.enumerated().map { idx, url in
                PageItem(id: idx, slug: nil, image: nil, url: url.absoluteString, width: nil, height: nil)
            }
            isLoading = false
            return
        }

        do {
            let result = try await service.fetchPages(
                slug: slug,
                volume: chapter.volume,
                number: chapter.number,
                branchId: bid,
                siteId: siteId
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

    /// Сменить переводчика (ветку) прямо во время чтения: обновляет branch_id,
    /// применяемый ко ВСЕМ главам, и перезагружает уже открытую главу/сегмент
    /// с новым переводом — иначе выбор в меню списка глав только фильтровал бы
    /// список, но не менял то, что реально загружается.
    func setPreferredBranch(_ branchId: Int?, verticalMode: Bool) async {
        guard branchId != preferredBranchId else { return }
        preferredBranchId = branchId
        if verticalMode {
            await loadSegments(from: currentIndex)
        } else {
            await load()
        }
    }

    // MARK: - Вертикальный (непрерывный) режим

    /// Сегмент ленты = страницы одной главы. В вертикальном режиме лента
    /// склеивается из нескольких сегментов подряд, следующий догружается
    /// по мере долистывания (см. appendNext).
    struct ReaderSegment: Identifiable {
        let index: Int
        let chapter: ChapterItem
        var pages: [PageItem]
        var id: Int { chapter.id }
    }

    @Published private(set) var segments: [ReaderSegment] = []
    @Published private(set) var isAppending = false

    /// Старт вертикального режима: грузим текущую главу первым сегментом.
    func startVertical() async {
        if !segments.isEmpty, segments.first?.index == currentIndex { return }
        await loadSegments(from: currentIndex)
    }

    /// Перейти к конкретной главе в вертикальном режиме (сброс ленты).
    func goToVertical(index: Int) async {
        guard chapters.indices.contains(index) else { return }
        currentIndex = index
        await loadSegments(from: index)
    }

    private func loadSegments(from index: Int) async {
        guard chapters.indices.contains(index) else { return }
        currentChapterAlreadyViewed = false
        recordProgress()
        isLoading = true
        errorMessage = nil
        segments = []
        if let seg = await fetchSegment(for: index) {
            segments = [seg]
            preloadAll(seg.pages)
        }
        isLoading = false
    }

    /// Догрузить следующую главу в конец ленты (вызывается, когда виден
    /// футер конца последнего сегмента).
    func appendNext() async {
        guard !isAppending, let last = segments.last else { return }
        let next = last.index + 1
        guard chapters.indices.contains(next),
              !segments.contains(where: { $0.index == next }) else { return }
        isAppending = true
        if let seg = await fetchSegment(for: next) {
            segments.append(seg)
            preloadAll(seg.pages)
        }
        isAppending = false
    }

    private func fetchSegment(for index: Int) async -> ReaderSegment? {
        let chapter = chapters[index]
        let bid = branchId(for: chapter)
        let localFiles = DownloadsManager.shared.localPageFiles(slug: slug, chapterId: chapter.id, branchId: bid)
        if !localFiles.isEmpty {
            let pages = localFiles.enumerated().map { idx, url in
                PageItem(id: idx, slug: nil, image: nil, url: url.absoluteString, width: nil, height: nil)
            }
            return ReaderSegment(index: index, chapter: chapter, pages: pages)
        }
        do {
            let result = try await service.fetchPages(
                slug: slug, volume: chapter.volume, number: chapter.number, branchId: bid, siteId: siteId
            )
            return ReaderSegment(index: index, chapter: chapter, pages: result.pages)
        } catch NetworkError.cancelled {
            return nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Предзагрузка ВСЕХ страниц сегмента (в вертикальном режиме тянем всё
    /// заранее, чтобы лента листалась без подгрузок).
    private func preloadAll(_ pages: [PageItem]) {
        for p in pages {
            RemoteImageLoader.preload(candidates: imageURLs(for: p))
        }
    }

    /// Пользователь долистал до главы index — обновляем заголовок/прогресс.
    func markCurrentChapter(_ index: Int) {
        guard chapters.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        currentChapterAlreadyViewed = false
        recordProgress()
    }

    /// Отметить текущую главу как последнюю прочитанную.
    func markProgress() { recordProgress() }

    /// Кнопка-закладка в ридере как переключатель: add=true — добавить в «Читаю»
    /// (если ещё нет), add=false — РЕАЛЬНО убрать из закладок (BookmarksStore.
    /// remove — локально + запрос на сервер). Показывает соответствующий тост.
    func setBookmark(_ add: Bool) {
        if add {
            if !BookmarksStore.shared.isBookmarked(slug: slug) {
                BookmarksStore.shared.add(
                    slug: slug,
                    title: mangaTitle ?? slug,
                    coverURL: coverURL,
                    toFolder: BookmarkFolder.reading.id
                )
            }
            showBookmarkToast("Добавлено в закладки")
        } else {
            BookmarksStore.shared.remove(slug: slug)
            showBookmarkToast("Убрано из закладок")
        }
    }

    private func showBookmarkToast(_ text: String) {
        bookmarkToast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if bookmarkToast == text { bookmarkToast = nil }
        }
    }

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
            // ТИХО, без тоста — авто-добавление при заходе делаем в фоне (как
            // попросили). Явный тост — только по кнопке (addBookmarkManually).
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
                    try await MangaNetworkService.shared.markChapterViewed(mangaId: mangaId, chapterId: chapter.id, siteId: siteId)
                } catch {
                    print("[ReaderViewModel] не удалось отметить главу просмотренной на сервере: \(error)")
                }
            }
        }
    }
}
