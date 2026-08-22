import Foundation
import Combine
import SwiftUI

// MARK: - Models

/// Категория/папка закладок.
struct BookmarkFolder: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var isDefault: Bool
    /// Числовой id папки на РЕАЛЬНОМ сервере — только у пользовательских
    /// папок, созданных через createFolder() (см. ниже), после успешного
    /// `POST /bookmarks/folder` (см. MangaNetworkService.createBookmarkFolder).
    /// У 5 стандартных папок вместо этого используется apiId (см. ниже) —
    /// они не создаются через этот эндпоинт, у них фиксированные id 1-5.
    /// Optional — до ответа сервера (или если запрос не удался) остаётся nil.
    var serverId: Int?

    static let reading   = BookmarkFolder(id: "reading",   name: "Читаю",     isDefault: true)
    static let planned   = BookmarkFolder(id: "planned",   name: "В планах",  isDefault: true)
    static let dropped   = BookmarkFolder(id: "dropped",   name: "Брошено",   isDefault: true)
    static let finished  = BookmarkFolder(id: "finished",  name: "Прочитано", isDefault: true)
    static let favorite  = BookmarkFolder(id: "favorite",  name: "Любимые",   isDefault: true)

    static let defaults: [BookmarkFolder] = [reading, planned, dropped, finished, favorite]

    /// Численный id для серверного API (`bookmarks[]=<id>` — см.
    /// MangaNetworkService.fetchBookmarks). Есть только у 5 стандартных папок —
    /// у папок, созданных прямо в приложении, серверного аналога нет.
    var apiId: Int? {
        switch id {
        case "reading":  return 1
        case "planned":  return 2
        case "dropped":  return 3
        case "finished": return 4
        case "favorite": return 5
        default:         return nil
        }
    }

    /// Цвет бэйджа статуса поверх обложки в сетке/карточках (см.
    /// MangaCardView.statusBadge) — свой цвет на каждую стандартную папку,
    /// у пользовательских папок (без apiId) — нейтральный серый.
    var badgeColor: Color {
        switch id {
        case "reading":  return .blue
        case "planned":  return .purple
        case "dropped":  return .red
        case "finished": return .green
        case "favorite": return Theme.accent
        default:         return Theme.textSecondary
        }
    }
}

/// Сохранённый тайтл в закладках (лёгкий снимок для отображения списка).
struct BookmarkedTitle: Codable, Identifiable, Hashable {
    let slug: String
    var title: String
    var coverURL: String?
    var folderId: String
    /// Числовой id САМОЙ ЗАПИСИ закладки на сервере (не тайтла и не slug) —
    /// подтверждено реальным перехваченным запросом: POST /bookmarks
    /// возвращает `{"data":{"id":N,...}}`, и именно этот N нужен для
    /// настоящего удаления `DELETE /bookmarks/{id}` (см.
    /// MangaNetworkService.setBookmarkStatus/removeBookmark(id:)). Optional —
    /// старые локальные записи (сохранённые до этого поля) и закладки,
    /// подтянутые через syncFromServer (см. ниже, тот эндпоинт id записи не
    /// возвращает), могут его не знать.
    var serverId: Int?
    /// Оценка тайтла — для единого цветного бэйджа оценки (см. RatingChip),
    /// показывается везде, в т.ч. в закладках, как явно попросили. Optional
    /// со значением по умолчанию — старые локальные записи без этого поля
    /// декодируются нормально (nil → серый бэйдж).
    var rating: Double? = nil

    var id: String { slug }
}

/// Прогресс чтения тайтла.
struct ReadingProgress: Codable, Hashable {
    var lastChapterNumber: String     // номер последней открытой главы (для отображения)
    var lastChapterVolume: String
    var readCount: Int                // сколько глав пройдено (позиция)
    var totalChapters: Int
    // Optional — старые записи без этого поля декодируются нормально (nil),
    // синтезированный Codable сам обрабатывает Optional как decodeIfPresent.
    // Нужно для экрана «История»: реальный порядок «недавно читал», а не заглушка.
    var lastReadAt: Date?
}

// MARK: - Store

/// Локальное хранилище закладок и прогресса (UserDefaults, без аккаунта).
@MainActor
final class BookmarksStore: ObservableObject {

    static let shared = BookmarksStore()

    @Published private(set) var folders: [BookmarkFolder]
    @Published private(set) var items: [BookmarkedTitle]
    @Published private(set) var progress: [String: ReadingProgress]
    @Published private(set) var isSyncing = false

    /// Настоящая история просмотров аккаунта — `GET /user/chapters/history`
    /// (см. syncHistoryFromServer). В отличие от items (только то, что реально
    /// добавлено в папку закладок), сюда попадает ВСЁ, что читалось на сайте,
    /// вне зависимости от того, есть ли тайтл в закладках.
    @Published private(set) var historyEntries: [HistoryEntry] = []
    @Published private(set) var isSyncingHistory = false

    private let defaults = UserDefaults.standard
    /// Папки — общие для всех сайтов (это просто пользовательские категории,
    /// а не серверные данные), но закладки/прогресс/история строго привязаны
    /// к конкретному сайту (site_id) — см. запрос пользователя: "Закладки
    /// тогда будут работать по привязке к серверу конкретному". Поэтому их
    /// ключи в UserDefaults параметризованы активным сайтом на момент записи.
    private enum Keys {
        static let folders = "bm_folders"
        static func items(_ site: LibSite) -> String { "bm_items_\(site.rawValue)" }
        static func progress(_ site: LibSite) -> String { "bm_progress_\(site.rawValue)" }
    }

    private var siteCancellable: AnyCancellable?

    init() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Keys.folders),
           let f = try? decoder.decode([BookmarkFolder].self, from: data), !f.isEmpty {
            folders = f
        } else {
            folders = BookmarkFolder.defaults
        }
        items = []
        progress = [:]
        loadSiteScopedData(for: SiteSession.shared.activeSite)

        // При переключении активного сайта в меню — перечитать локальный кэш
        // этого сайта (не смешивая с данными других сайтов) и заново
        // подтянуть закладки/историю с сервера для НЕГО.
        siteCancellable = SiteSession.shared.$activeSite
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] site in
                guard let self else { return }
                self.historyEntries = []
                self.loadSiteScopedData(for: site)
                Task {
                    await self.syncFromServer()
                    await self.syncHistoryFromServer()
                }
            }
    }

    /// Перечитывает items/progress из UserDefaults под ключами конкретного
    /// сайта — вызывается при старте и при каждом переключении activeSite.
    private func loadSiteScopedData(for site: LibSite) {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Keys.items(site)),
           let i = try? decoder.decode([BookmarkedTitle].self, from: data) {
            items = i
        } else {
            items = []
        }
        if let data = defaults.data(forKey: Keys.progress(site)),
           let p = try? decoder.decode([String: ReadingProgress].self, from: data) {
            progress = p
        } else {
            progress = [:]
        }
    }

    // MARK: Папки

    /// Все категории (по умолчанию + пользовательские).
    var allFolders: [BookmarkFolder] { folders }

    func titlesCount(in folderId: String?) -> Int {
        guard let folderId else { return items.count }   // nil = «Все»
        return items.filter { $0.folderId == folderId }.count
    }

    func titles(in folderId: String?) -> [BookmarkedTitle] {
        guard let folderId else { return items }
        return items.filter { $0.folderId == folderId }
    }

    @discardableResult
    func createFolder(name: String) -> BookmarkFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = BookmarkFolder(id: UUID().uuidString, name: trimmed, isDefault: false)
        folders.append(folder)
        persistFolders()

        // Локально папка уже создана (экран не ждёт сеть) — пушим создание в
        // РЕАЛЬНЫЙ аккаунт через подтверждённый `POST /bookmarks/folder` (см.
        // MangaNetworkService.createBookmarkFolder). Сохраняем вернувшийся
        // числовой id записи — пригодится для настоящего удаления/
        // переименования папки на сервере, если/когда эти эндпоинты найдутся.
        Task {
            do {
                let serverFolder = try await MangaNetworkService.shared.createBookmarkFolder(name: trimmed)
                if let idx = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    self.folders[idx].serverId = serverFolder.id
                    self.persistFolders()
                }
            } catch {
                print("[BookmarksStore] не удалось создать папку (\(trimmed)) на сервере: \(error)")
            }
        }
        return folder
    }

    // MARK: Закладки

    /// В какой папке находится тайтл (nil — не в закладках).
    func folderId(forSlug slug: String) -> String? {
        items.first { $0.slug == slug }?.folderId
    }

    func isBookmarked(slug: String) -> Bool { folderId(forSlug: slug) != nil }

    /// Добавить/переместить тайтл в папку.
    /// `pushToServer` = false используется ТОЛЬКО когда мы сами только что
    /// ПРОЧИТАЛИ это же состояние с сервера (см. syncFromServer ниже) — иначе
    /// получился бы бессмысленный цикл "прочитали с сервера → тут же
    /// попытались записать то же самое обратно на сервер".
    func add(slug: String, title: String, coverURL: String?, rating: Double? = nil, toFolder folderId: String, pushToServer: Bool = true) {
        if let index = items.firstIndex(where: { $0.slug == slug }) {
            items[index].folderId = folderId
            items[index].title = title
            items[index].coverURL = coverURL
            // Не затираем уже известную оценку nil'ом, если вызывающий код её
            // не знает (например, авто-добавление в "Читаю" из ReaderViewModel).
            if let rating { items[index].rating = rating }
        } else {
            items.append(BookmarkedTitle(slug: slug, title: title, coverURL: coverURL, folderId: folderId, rating: rating))
        }
        persistItems()

        // Локальное состояние (items, выше) обновляется СРАЗУ — экран не
        // ждёт сеть. Пуш в реальный аккаунт — настоящий, подтверждённый
        // эндпоинт `POST /bookmarks` (см. MangaNetworkService.setBookmarkStatus).
        // "status" в теле этого запроса — ОДНО И ТО ЖЕ поле что для 5
        // стандартных папок (apiId, 1-5), что для ПОЛЬЗОВАТЕЛЬСКИХ папок —
        // подтверждено перехватом: добавление тайтла в кастомную папку
        // "она" (созданную на сайте, серверный id 2717854) реально ушло как
        // `POST /bookmarks` c `"bookmark":{"status":2717854}`. Значит для
        // папок, которые мы САМИ создали через createFolder() (и получили
        // их serverId), пуш тоже возможен — используем apiId для стандартных
        // папок, иначе serverId для собственных пользовательских.
        let targetFolder = folders.first(where: { $0.id == folderId })
        let pushStatus = targetFolder?.apiId ?? targetFolder?.serverId
        if pushToServer, let pushStatus {
            Task {
                do {
                    let recordId = try await MangaNetworkService.shared.setBookmarkStatus(slug: slug, status: pushStatus)
                    // Сохраняем id ЗАПИСИ закладки, который вернул сервер — он
                    // нужен для настоящего удаления (см. remove() ниже). Ищем
                    // индекс заново — к моменту ответа сети items мог измениться.
                    if let recordId, let idx = self.items.firstIndex(where: { $0.slug == slug }) {
                        self.items[idx].serverId = recordId
                        self.persistItems()
                    }
                } catch {
                    print("[BookmarksStore] не удалось запушить статус закладки (\(slug) → \(pushStatus)) на сервер: \(error)")
                }
            }
        }
    }

    func remove(slug: String) {
        // Запоминаем serverId ДО удаления из items — он нужен для реального
        // запроса на сервер (см. ниже).
        let serverId = items.first(where: { $0.slug == slug })?.serverId
        // ВРЕМЕННЫЙ diagnostic-лог (см. Xcode-консоль при тесте) — показывает,
        // каким путём реально пошло удаление: если тут "guessing" — значит
        // serverId так и не был известен локально к моменту удаления (то есть
        // синк ещё не отработал/не нашёл эту закладку) — именно это нужно
        // подтвердить или опровергнуть по консоли на реальном устройстве.
        print("[BookmarksStore][debug] remove(slug: \(slug)) — serverId=\(serverId.map(String.init) ?? "nil (пойдёт через removeBookmarkGuessing)")")
        items.removeAll { $0.slug == slug }
        persistItems()
        Task {
            do {
                if let serverId {
                    // Настоящий, подтверждённый перехватом+тестом эндпоинт —
                    // см. MangaNetworkService.removeBookmark(id:slug:).
                    try await MangaNetworkService.shared.removeBookmark(id: serverId, slug: slug)
                    print("[BookmarksStore][debug] removeBookmark(id: \(serverId), slug: \(slug)) — запрос отправлен без ошибки")
                } else {
                    // Запасной вариант для закладок без известного serverId
                    // (например, подтянутых через syncFromServer, или
                    // сохранённых ДО того, как мы начали хранить serverId) —
                    // неподтверждённая догадка, см. removeBookmarkGuessing.
                    try await MangaNetworkService.shared.removeBookmarkGuessing(slug: slug)
                    print("[BookmarksStore][debug] removeBookmarkGuessing(slug: \(slug)) — запрос отправлен без ошибки (но сам эндпоинт НЕ подтверждён — на сервере, скорее всего, ничего не удалилось)")
                }
            } catch {
                print("[BookmarksStore] не удалось запушить удаление закладки (\(slug)) на сервер: \(error)")
            }
        }
    }

    // MARK: Синхронизация с аккаунтом

    /// Подтягивает реальные закладки аккаунта с сервера в 5 стандартных папок.
    /// Использует НАСТОЯЩИЙ эндпоинт "мои закладки" — `GET /bookmarks?...&
    /// user_id=` (см. MangaNetworkService.fetchBookmarksAccountList) — вместо
    /// старого предположения "отдельного эндпоинта нет, это /manga с фильтром
    /// bookmarks[]=". Это принципиально важно: только НАСТОЯЩИЙ эндпоинт
    /// отдаёт "id" самой ЗАПИСИ закладки (entry.id), без которого удаление
    /// (`DELETE /bookmarks/{id}`, см. remove() выше) не может сработать —
    /// раньше все закладки, подтянутые синком, оставались без serverId и
    /// удалялись только неподтверждённой догадкой removeBookmarkGuessing,
    /// которая на сервере ничего не удаляла.
    /// Мержит, не затирает: локальные тайтлы в пользовательских папках (без
    /// apiId, серверного аналога вообще нет) не трогает.
    /// Пишет serverId/folderId/title/coverURL НАПРЯМУЮ (не через add()) — сюда
    /// нельзя пускать pushToServer-логику: мы читаем состояние С сервера, а не
    /// собираемся тут же отправлять его обратно.
    func syncFromServer() async {
        guard AuthSession.shared.isLoggedIn, !isSyncing else {
            print("[BookmarksStore][debug] syncFromServer() пропущен — isLoggedIn=\(AuthSession.shared.isLoggedIn), isSyncing=\(isSyncing)")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        // status=0 — "все папки" одним проходом (подтверждено перехваченным
        // запросом сайта, вкладка "Все"). Листаем страницы, пока сервер не
        // скажет, что дальше пусто.
        var allEntries: [BookmarkListEntry] = []
        var page = 1
        while page <= 40 {
            do {
                let result = try await MangaNetworkService.shared.fetchBookmarksAccountList(status: 0, page: page)
                guard !result.items.isEmpty else { break }
                allEntries.append(contentsOf: result.items)
                guard result.hasNextPage else { break }
                page += 1
            } catch {
                // ВРЕМЕННЫЙ diagnostic-лог — раньше ошибка здесь тихо
                // проглатывалась через try?, и synchFromServer просто ничего
                // не делал без единого следа в консоли. Теперь видно ТОЧНУЮ
                // причину (network/decoding/401 и т.д.), если она есть.
                print("[BookmarksStore][debug] fetchBookmarksAccountList(page: \(page)) упал: \(error)")
                break
            }
        }
        print("[BookmarksStore][debug] syncFromServer() получил \(allEntries.count) закладок с сервера (userId=\(AuthSession.shared.userId.map(String.init) ?? "nil"))")
        guard !allEntries.isEmpty else { return }

        for entry in allEntries {
            guard let status = entry.status else { continue }
            // "status" здесь — то же самое поле, что и для стандартных папок
            // (apiId 1-5), но у ЗАКЛАДКИ В ПОЛЬЗОВАТЕЛЬСКОЙ папке в нём лежит
            // числовой id САМОЙ папки (подтверждено перехватом — см. add()
            // выше). Поэтому ищем сперва среди стандартных (apiId), потом
            // среди СВОИХ пользовательских папок (serverId, проставляется в
            // createFolder()). Папки, созданные НЕ в этом приложении (на
            // сайте/другом клиенте), нам пока не видны — у нас нет
            // подтверждённого эндпоинта "список моих пользовательских папок",
            // поэтому такие закладки по-прежнему пропускаются, а не теряются
            // молча под чужим/неверным именем.
            guard let folder = folders.first(where: { $0.apiId == status })
                    ?? folders.first(where: { $0.serverId == status }) else { continue }
            let slug = entry.media.apiSlug
            if let idx = items.firstIndex(where: { $0.slug == slug }) {
                items[idx].folderId = folder.id
                items[idx].title = entry.media.displayTitle
                items[idx].coverURL = entry.media.coverURLString
                items[idx].serverId = entry.id
                items[idx].rating = entry.media.rating?.value
            } else {
                items.append(BookmarkedTitle(slug: slug, title: entry.media.displayTitle,
                                              coverURL: entry.media.coverURLString,
                                              folderId: folder.id, serverId: entry.id,
                                              rating: entry.media.rating?.value))
            }
        }
        persistItems()
        print("[BookmarksStore][debug] syncFromServer() завершён: \(items.count) закладок локально, из них с serverId — \(items.filter { $0.serverId != nil }.count)")
    }

    /// Подтягивает НАСТОЯЩУЮ историю чтения аккаунта — `GET
    /// /user/chapters/history?page=N` (см. MangaNetworkService.fetchHistory).
    /// Листает страницы, пока сервер не вернёт пустой список. Кладёт полный
    /// список в historyEntries (экран «История» рендерит его напрямую) И
    /// заодно обновляет progress[] по каждому тайтлу — благодаря этому
    /// «Продолжить с главы X» в карточке тайтла и в закладках сразу
    /// показывает правду, даже если пользователь читал главу на САЙТЕ, а не
    /// в этом приложении.
    func syncHistoryFromServer() async {
        guard AuthSession.shared.isLoggedIn, !isSyncingHistory else { return }
        isSyncingHistory = true
        defer { isSyncingHistory = false }

        var all: [HistoryEntry] = []
        var page = 1
        // Защитный предел страниц — чтобы неожиданный ответ сервера (например,
        // если он никогда не вернёт по-настоящему пустой список) не увёл нас
        // в бесконечный цикл запросов.
        while page <= 40 {
            guard let batch = try? await MangaNetworkService.shared.fetchHistory(page: page), !batch.isEmpty else { break }
            all.append(contentsOf: batch)
            page += 1
        }
        historyEntries = all

        // Сервер отдаёт от новых к старым — дедуп по тайтлу оставляет самую
        // свежую запись, ровно то, что нужно для "на какой главе я сейчас".
        var seenMangaIds = Set<Int>()
        for entry in all {
            guard !seenMangaIds.contains(entry.media.id) else { continue }
            seenMangaIds.insert(entry.media.id)

            let slug = entry.media.apiSlug
            let existing = progress[slug]
            // Не затираем более свежий локальный прогресс (например, если
            // пользователь только что дочитал в этом приложении, пока шла
            // синхронизация) — сравниваем даты.
            if existing == nil || (existing?.lastReadAt ?? .distantPast) < entry.viewAt {
                progress[slug] = ReadingProgress(
                    lastChapterNumber: entry.item.number,
                    lastChapterVolume: entry.item.volume,
                    readCount: existing?.readCount ?? 0,
                    totalChapters: existing?.totalChapters ?? 0,
                    lastReadAt: entry.viewAt
                )
            }
        }
        persistProgress()
    }

    // MARK: Прогресс

    func readingProgress(forSlug slug: String) -> ReadingProgress? { progress[slug] }

    /// `force: true` — выставляет readCount РОВНО в переданное значение (можно и
    /// уменьшить), для явного выбора пользователем ("отметить прочитанным до
    /// главы N" по тапу на закладку в списке глав — см. MangaDetailView.markReadUpTo).
    /// `force: false` (по умолчанию) — как раньше, только увеличивает
    /// (max с текущим значением): это путь автоматического прогресса при
    /// самом чтении (см. ReaderViewModel.recordProgress) — открыть уже
    /// прочитанную старую главу повторно не должно откатывать прогресс назад.
    func setProgress(slug: String, chapterNumber: String, chapterVolume: String, readCount: Int, total: Int, force: Bool = false) {
        progress[slug] = ReadingProgress(
            lastChapterNumber: chapterNumber,
            lastChapterVolume: chapterVolume,
            readCount: force ? readCount : max(readCount, progress[slug]?.readCount ?? 0),
            totalChapters: total,
            lastReadAt: Date()
        )
        persistProgress()
    }

    // MARK: Persist

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: Keys.folders) }
    }
    private func persistItems() {
        let site = SiteSession.shared.activeSite
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Keys.items(site)) }
    }
    private func persistProgress() {
        let site = SiteSession.shared.activeSite
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Keys.progress(site)) }
    }
}
