import Foundation

/// Режим сортировки комментариев — "Старые"/"Новые" реально уходят на сервер
/// (sort_type=asc/desc, тот же подтверждённый параметр, что и в fetchComments
/// по умолчанию), "Популярные" считается на клиенте по score (см.
/// MangaDetailView.commentsList) — серверная сортировка по популярности НЕ
/// подтверждена перехватом.
enum CommentSort: String, CaseIterable, Identifiable {
    case popular, old, new
    var id: String { rawValue }
    var title: String {
        switch self {
        case .popular: return "Популярные"
        case .old: return "Старые"
        case .new: return "Новые"
        }
    }
}

/// ViewModel детальной карточки: загружает информацию о манге и список её глав по `slug`.
@MainActor
final class MangaDetailViewModel: ObservableObject {

    @Published private(set) var detail: MangaDetail?
    @Published private(set) var chapters: [ChapterItem] = [] {
        didSet {
            // Индекс id→позиция — чтобы position(of:) не делал линейный
            // firstIndex(of:) (со сравнением ВСЕГО ChapterItem, включая
            // branches) на каждую строку списка глав. При 300+ главах это
            // давало O(n²) при построении/скролле экрана карточки — чем
            // больше глав, тем сильнее фризы (см. chaptersTab/isRead в
            // MangaDetailView).
            chapterPositionById = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { ($1.id, $0 + 1) })
        }
    }
    private var chapterPositionById: [Int: Int] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    /// Ошибка ИМЕННО загрузки карточки (detail), в отличие от errorMessage
    /// выше — тот заполняется только если ОБА запроса (detail и chapters)
    /// провалились. Из-за этого, если главы загрузились, а карточка
    /// (тип/статус/жанры/описание) — нет, errorMessage оставался пустым и
    /// реальная причина падения carточки была не видна нигде на экране.
    @Published private(set) var detailErrorMessage: String?

    // MARK: Комментарии (GET/POST /comments — ПОДТВЕРЖДЕНО перехватом, см.
    // MangaNetworkService.fetchComments/postComment).
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var isLoadingComments = false
    @Published private(set) var commentsError: String?
    @Published private(set) var hasLoadedComments = false
    @Published private(set) var hasMoreComments = false
    @Published private(set) var isPostingComment = false
    @Published private(set) var commentSort: CommentSort = .new
    private var commentsPage = 1

    // MARK: Похожее (GET /manga/{slug}/similar, POST /similar/{id}/vote —
    // ПОДТВЕРЖДЕНО перехватом, см. MangaNetworkService.fetchSimilar/voteSimilar).
    /// Опциональный, вспомогательный блок — ошибку загрузки НЕ показываем
    /// отдельно (нет своего errorMessage), просто оставляем пустым; при
    /// пустом списке весь блок скрывается в UI (см. MangaDetailView.similarSection).
    @Published private(set) var similar: [SimilarItem] = []

    // MARK: Связанное (GET /manga/{slug}/relations — ПОДТВЕРЖДЕНО перехватом,
    // см. MangaNetworkService.fetchRelated). Тоже опциональный блок, как и
    // "Похожее" выше — своего errorMessage нет, пустой список просто прячет UI.
    @Published private(set) var related: [RelatedItem] = []

    // MARK: Персонажи (GET /character?media_id= — ПОДТВЕРЖДЕНО перехватом).
    /// Опциональный блок-карусель, как «Похожее»/«Связанное»: ошибка не
    /// показывается, пустой список просто прячет строку.
    @Published private(set) var characters: [Character] = []

    // MARK: Доп. обложки (GET /manga/{slug}/covers — ПОДТВЕРЖДЕНО перехватом,
    // см. MangaNetworkService.fetchCoverGallery). Опциональный блок, как и
    // остальные выше — ошибка не показывается, пустой список просто прячет
    // чип со счётчиком на обложке (см. MangaDetailView.coverGalleryBadge).
    @Published private(set) var coverGallery: [MangaCoverGalleryItem] = []

    // MARK: Статистика (GET /manga/{slug}/stats — ПОДТВЕРЖДЕНО перехватом).
    /// Оценки пользователей + распределение по спискам. Опциональный блок:
    /// ошибка не показывается, при nil блок скрыт.
    @Published private(set) var stats: MangaStats?

    let slug: String
    /// Сайт тайтла (site_id). Нужен, чтобы карточку/главы/похожее с ДРУГОГО
    /// сайта (напр. открытую из «Похожего»/«Связанного») запрашивать с их
    /// собственным Site-Id, иначе сервер отдаёт 404 и карточка пустеет.
    let siteId: Int?
    private let service: MangaNetworkService

    init(slug: String, siteId: Int? = nil, service: MangaNetworkService = .shared) {
        self.slug = slug
        self.siteId = siteId
        self.service = service
    }

    /// Сайт, на котором карточка реально нашлась (см. loadDetailResolvingSite) —
    /// используется для всех дочерних запросов (главы/похожее/статы/страницы).
    private var effectiveSite: Int?

    /// «Истинный» сайт тайтла для дочерних запросов: пришедший в карточке →
    /// найденный перебором → переданный при навигации.
    var resolvedSiteId: Int? { detail?.site ?? effectiveSite ?? siteId }

    var totalChapters: Int { chapters.count }

    /// Глава для кнопки «Продолжить» по сохранённому прогрессу (или nil).
    func continueChapter(progress: ReadingProgress?) -> ChapterItem? {
        guard let progress else { return nil }
        return chapters.first {
            $0.number == progress.lastChapterNumber && $0.volume == progress.lastChapterVolume
        } ?? chapters.first
    }

    /// Позиция главы в списке (1-based) — для сохранения прогресса. O(1) по
    /// заранее построенному индексу (см. chapters.didSet), а не линейный
    /// поиск по всему списку на каждый вызов.
    func position(of chapter: ChapterItem) -> Int {
        chapterPositionById[chapter.id] ?? 1
    }

    /// Загружает карточку и главы параллельно и независимо:
    /// ошибка одного запроса не отменяет другой.
    func load() async {
        isLoading = true
        errorMessage = nil
        detailErrorMessage = nil

        // СНАЧАЛА карточка: она же определяет рабочий site_id (тайтл из
        // «Похожего»/«Связанного» может жить на другом сайте, и у его media
        // поля site может не быть — поэтому при 404 перебираем сайты). Как
        // только сайт найден, остальные блоки грузятся уже с ним.
        let detailError = await loadDetailResolvingSite()
        detailErrorMessage = detailError

        // Остальное — параллельно, с уже известным сайтом.
        async let chaptersResult = loadChapters()
        async let similarResult: Void = loadSimilar()
        async let relatedResult: Void = loadRelated()
        async let statsResult: Void = loadStats()
        async let coverGalleryResult: Void = loadCoverGallery()
        let (chaptersError, _, _, _, _) = await (chaptersResult, similarResult, relatedResult, statsResult, coverGalleryResult)

        // Показываем общую ошибку только если ничего не удалось загрузить.
        if detail == nil, chapters.isEmpty {
            errorMessage = detailError ?? chaptersError
        }
        isLoading = false
    }

    /// Грузит карточку, подбирая рабочий site_id: сначала переданный при
    /// навигации, затем активный, затем остальные сайты — до первого, где
    /// тайтл найдётся (сервер отвечает 404, если Site-Id не тот). Найденный
    /// сайт запоминается в effectiveSite для дочерних запросов.
    private func loadDetailResolvingSite() async -> String? {
        var candidates: [Int?] = []
        var seen = Set<Int>()
        if let siteId { candidates.append(siteId); seen.insert(siteId) }
        candidates.append(nil)                     // активный сайт (заголовок по умолчанию)
        for s in LibSite.allCases.map(\.rawValue) where !seen.contains(s) { candidates.append(s) }

        var lastError: String? = nil
        for candidate in candidates {
            do {
                let d = try await service.fetchMangaDetail(slug: slug, siteId: candidate)
                detail = d
                effectiveSite = d.site ?? candidate ?? siteId
                await loadCharacters(mangaId: d.id)
                return nil
            } catch NetworkError.cancelled {
                return nil
            } catch NetworkError.notFound {
                // Не тот сайт — пробуем следующий.
                lastError = "Тайтл не найден на доступных сайтах."
                continue
            } catch {
                // Сеть/декодирование — это не про сайт, перебор других сайтов
                // не поможет (нет соединения останется нет соединения).
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                break
            }
        }

        // Сеть недоступна (или тайтл не нашёлся) — если он скачан, у него есть
        // офлайн-кэш карточки (см. DownloadsManager.cacheDetailAndStats),
        // показываем его вместо "нет сети"/пустого экрана.
        if let cached = DownloadsManager.shared.cachedDetail(slug: slug) {
            detail = cached
            effectiveSite = cached.site ?? siteId
            return nil
        }
        return lastError
    }

    private func loadCharacters(mangaId: Int) async {
        do { characters = try await service.fetchCharacters(mangaId: mangaId, siteId: resolvedSiteId) }
        catch { characters = [] }
    }

    private func loadStats() async {
        do { stats = try await service.fetchMangaStats(slug: slug, siteId: resolvedSiteId) }
        catch { stats = DownloadsManager.shared.cachedStats(slug: slug) }
    }

    private func loadChapters() async -> String? {
        do {
            chapters = sortChapters(try await service.fetchChapters(slug: slug, siteId: resolvedSiteId))
            return nil
        } catch NetworkError.cancelled {
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadSimilar() async {
        do {
            similar = try await service.fetchSimilar(slug: slug, siteId: resolvedSiteId)
        } catch {
            // Тихо игнорируем — "Похожее" опциональный блок карточки, не
            // должен ломать/затенять основной экран при ошибке загрузки
            // (нет отдельного errorMessage/retry-состояния — см. комментарий
            // у объявления similar выше).
        }
    }

    private func loadRelated() async {
        do {
            related = try await service.fetchRelated(slug: slug, siteId: resolvedSiteId)
        } catch {
            // Тихо игнорируем — по той же причине, что и loadSimilar выше:
            // "Связанное" опциональный блок, у большинства тайтлов его вообще
            // нет, ошибка загрузки не должна затенять основной экран.
        }
    }

    private func loadCoverGallery() async {
        do {
            coverGallery = try await service.fetchCoverGallery(slug: slug, siteId: resolvedSiteId)
        } catch {
            // Тихо игнорируем — по той же причине, что и loadSimilar/loadRelated:
            // опциональный блок, ошибка загрузки не должна затенять основной экран.
        }
    }

    /// Голос "+"/"-" за элемент "Похожего" (см. MangaNetworkService.voteSimilar).
    /// Сервер возвращает АКТУАЛЬНЫЕ up/down/user целиком — подставляем их
    /// сразу в нужный элемент similar, без перезагрузки всего списка.
    @discardableResult
    func voteSimilar(_ item: SimilarItem, isUp: Bool) async -> Bool {
        guard let index = similar.firstIndex(where: { $0.id == item.id }) else { return false }
        do {
            similar[index].votes = try await service.voteSimilar(id: item.id, isUp: isUp)
            return true
        } catch NetworkError.cancelled {
            return false
        } catch {
            return false
        }
    }

    /// Сортировка глав по возрастанию тома, затем номера главы.
    private func sortChapters(_ items: [ChapterItem]) -> [ChapterItem] {
        items.sorted { lhs, rhs in
            let lv = Double(lhs.volume) ?? 0, rv = Double(rhs.volume) ?? 0
            if lv != rv { return lv < rv }
            let ln = Double(lhs.number) ?? 0, rn = Double(rhs.number) ?? 0
            return ln < rn
        }
    }

    // MARK: Комментарии

    /// Вызывается при первом открытии вкладки "Комментарии" — грузит один
    /// раз, повторные появления вкладки не дёргают сеть заново (см.
    /// hasLoadedComments). Явное обновление — через loadComments() напрямую
    /// (потянуть-обновить/кнопка "Повторить").
    func loadCommentsIfNeeded() async {
        guard !hasLoadedComments, !isLoadingComments else { return }
        await loadComments()
    }

    /// Серверная сортировка (подтверждена перехватом): Новые — id/desc,
    /// Старые — id/asc, Популярные — votes_up/desc. Теперь «Популярные» тоже
    /// серверные (клиентская пересортировка по score больше не нужна).
    private var sortTypeParam: String { commentSort == .old ? "asc" : "desc" }
    private var sortByParam: String { commentSort == .popular ? "votes_up" : "id" }

    func loadComments() async {
        guard let mangaId = detail?.id else {
            // detail ещё не загружен (или не удалось) — без числового id
            // тайтла запрос отправить нечем; попробовать снова можно после
            // успешной загрузки detail.
            commentsError = "Не удалось определить тайтл"
            return
        }
        isLoadingComments = true
        commentsError = nil
        commentsPage = 1
        do {
            let result = try await service.fetchComments(postId: mangaId, sortBy: sortByParam, sortType: sortTypeParam, page: 1)
            comments = result.comments
            hasMoreComments = result.hasNextPage
            hasLoadedComments = true
        } catch NetworkError.cancelled {
            // Экран закрыли/задача отменена — не показываем ошибку.
        } catch {
            commentsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingComments = false
    }

    /// Смена сортировки — всегда перезагружает список с первой страницы
    /// (клиентская пересортировка по score для "Популярные" применяется в
    /// самом View, здесь только меняем параметр сервера для Старые/Новые).
    func changeCommentSort(_ sort: CommentSort) async {
        guard sort != commentSort else { return }
        commentSort = sort
        await loadComments()
    }

    /// Подгрузка следующей страницы — вызывать из `.onAppear` последнего
    /// показанного КОРНЕВОГО комментария (не любого — дерево строится на
    /// клиенте, см. MangaDetailView.commentsList, и сама проверка "это
    /// правда последний" там же на уровне корней, а не плоского списка).
    func loadMoreCommentsIfNeeded(currentComment: Comment) async {
        guard hasMoreComments, !isLoadingComments, let mangaId = detail?.id else { return }
        isLoadingComments = true
        let nextPage = commentsPage + 1
        do {
            let result = try await service.fetchComments(postId: mangaId, sortBy: sortByParam, sortType: sortTypeParam, page: nextPage)
            comments.append(contentsOf: result.comments)
            hasMoreComments = result.hasNextPage
            commentsPage = nextPage
        } catch {
            // Тихо игнорируем ошибку подгрузки продолжения — уже показанные
            // комментарии не должны пропадать или показывать баннер ошибки
            // поверх всего списка.
        }
        isLoadingComments = false
    }

    /// Отправка нового комментария (или ответа, если replyingTo != nil).
    /// Возвращает true при успехе. Сервер реально возвращает созданный
    /// комментарий (см. MangaNetworkService.postComment) — вставляем его
    /// локально сразу, без полной перезагрузки списка.
    ///
    /// Принимает целиком Comment, на который отвечаем (а не голый id) — это
    /// нужно, чтобы вычислить comment_level ответа: сервер требует его явно
    /// (подтверждено реальным 422 "Поле comment level обязательно для
    /// заполнения", см. MangaNetworkService.postComment) и сам НЕ вычисляет
    /// из parent_comment. Схема — та же, что видна в подтверждённых
    /// GET-ответах: корневой комментарий = 0, любой ответ = commentLevel
    /// родителя + 1.
    @discardableResult
    func postComment(text: String, replyingTo: Comment? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let mangaId = detail?.id else { return false }
        isPostingComment = true
        commentsError = nil
        let level = (replyingTo?.commentLevel).map { $0 + 1 } ?? 0
        do {
            let created = try await service.postComment(
                postId: mangaId, text: trimmed,
                commentLevel: level, parentComment: replyingTo?.id
            )
            comments.insert(created, at: 0)
            isPostingComment = false
            return true
        } catch NetworkError.cancelled {
            isPostingComment = false
            return false
        } catch {
            commentsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isPostingComment = false
            return false
        }
    }

    /// Голос за/против комментария — РЕАЛЬНЫЙ (эндпоинт подтверждён перехватом,
    /// см. MangaNetworkService.voteComment). Обновляет счётчики и голос юзера
    /// прямо в модели, без перезагрузки списка. Требует авторизации.
    @discardableResult
    func voteComment(_ comment: Comment, isUp: Bool) async -> Bool {
        guard AuthSession.shared.isLoggedIn,
              let idx = comments.firstIndex(where: { $0.id == comment.id }) else { return false }
        do {
            let votes = try await service.voteComment(id: comment.id, direction: isUp ? 1 : 0)
            comments[idx].votesUp = votes.up
            comments[idx].votesDown = votes.down
            comments[idx].userVote = votes.user
            return true
        } catch {
            return false
        }
    }
}
