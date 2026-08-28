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
    /// Цвет папки С СЕРВЕРА (hex, напр. "#ff9b40") — только у папок,
    /// подтянутых/смерженных через syncFoldersFromServer() (см. ниже), у 5
    /// стандартных папок цвет по-прежнему берётся из badgeColor напрямую
    /// (там же и у чисто локальных, ещё не запушенных папок). Optional со
    /// значением по умолчанию — старые локальные записи без этого поля
    /// декодируются нормально.
    var colorHex: String? = nil
    /// На каких сайтах сети (LibSite.rawValue) видна эта папка —
    /// ПОДТВЕРЖДЕНО перехватом: `GET /bookmarks/folder/{userId}` отдаёт
    /// ПОЛНЫЙ список аккаунта сразу по всем сайтам, фильтрация "что
    /// показывать на этом сайте" — целиком на фронтенде, по этому полю (см.
    /// allFolders ниже). nil = ещё не знаем область (старые локальные папки
    /// до этого поля — синтезированный Codable сам обрабатывает Optional как
    /// decodeIfPresent, значит они декодируются нормально, просто без этого
    /// поля) — трактуем как "видна везде", а не прячем — см. allFolders. У 5
    /// стандартных папок это поле не используется (они и так всегда видны
    /// через isDefault).
    var siteIds: [Int]? = nil
    /// notify/isPublic — остальные два поля полного объекта `PUT
    /// /bookmarks/folder/{id}` (см. MangaNetworkService.updateBookmarkFolder),
    /// нужны ТОЛЬКО чтобы не затереть их при простом переименовании/смене
    /// цвета — сами по себе в UI сейчас не редактируются (см. EditFolderSheet
    /// в BookmarksView). Optional, как colorHex/siteIds выше — nil, пока не
    /// подтянуты через createFolder()/syncFoldersFromServer() (или у старых
    /// локальных записей без этого поля); у 5 стандартных не используются.
    var notify: Bool? = nil
    var isPublic: Bool? = nil

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
        default:
            // Пользовательская папка (своя из createFolder() или подтянутая
            // с сервера через syncFoldersFromServer()) — используем реальный
            // цвет с сервера, если он известен, иначе нейтральный серый.
            if let hex = colorHex, let color = Color(bookmarkFolderHex: hex) { return color }
            return Theme.textSecondary
        }
    }
}

/// Свой парсер hex-цвета папки (тот же приём, что и в UserBookmarksView/
/// NotificationSettingsView — там он `private` и не виден отсюда).
private extension Color {
    init?(bookmarkFolderHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
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
    /// ТВОЯ личная оценка тайтла (1-10) — см. BookmarksStore.setMyRating.
    /// Список закладок с сервера её не возвращает (это ОЦЕНКА САЙТА, см.
    /// `rating` выше, другое поле), поэтому это локальный кэш реального
    /// значения `MangaRating.user` (ПОДТВЕРЖДЕНО перехватом `POST
    /// /manga/rate`, см. MangaModels.swift) — заполняется, когда мы его
    /// узнаём: открыли карточку уже оценённого тайтла или сами поставили
    /// оценку (см. MangaDetailView). nil — ещё не узнали, чип в сетке
    /// закладок просто не рисуется (тот же принцип, что и у RatingChip).
    var myRating: Int? = nil
    /// Когда тайтл реально добавлен в закладки — для сортировки "По дате
    /// добавления" (см. BookmarksView.BookmarksSortOption). Optional со
    /// значением по умолчанию nil — старые локальные записи (сохранённые до
    /// этого поля) декодируются нормально, просто без даты (сортировка
    /// такие записи считает "самыми старыми", см. BookmarksView.sortByDate).
    var addedAt: Date? = nil
    /// "Прочитано N раз" — ПОДТВЕРЖДЕНО перехватом: meta.rewatches_history в
    /// теле `POST /bookmarks` (тот же запрос, что и смена папки — см.
    /// BookmarksStore.startRewatch/finishRewatch/deleteRewatchPeriod,
    /// MangaNetworkService.updateBookmarkMeta). nil — ещё не знаем (старые
    /// локальные записи без этого поля, или пока не пришёл первый
    /// syncFromServer) — трактуется как "пусто", не как ошибка.
    var rewatchHistory: [RewatchPeriod]? = nil
    /// Личный комментарий к закладке — ПОДТВЕРЖДЕНО перехватом (meta.comment,
    /// тот же объект, что и rewatchHistory). В UI НЕ редактируется — хранится
    /// только чтобы не затереть его при сохранении rewatchHistory (сервер
    /// требует meta целиком, не частичный патч).
    var comment: String? = nil
    /// Числовой id САМОГО ТАЙТЛА (`MangaItem.id`/`media.id`) — НЕ id записи
    /// закладки (см. serverId выше) и не slug. ПОДТВЕРЖДЕНО перехватом:
    /// нужен именно он для группового перемещения/удаления — `PUT/DELETE
    /// /bookmarks/bulk` принимают `media_ids`, не id закладок (см.
    /// BookmarksStore.bulkMove/bulkDelete, MangaNetworkService.
    /// bulkMoveBookmarks/bulkDeleteBookmarks). Optional — заполняется из
    /// entry.media.id при syncFromServer, до первого синка неизвестен.
    var mediaId: Int? = nil

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

    /// Тайтлы, скрытые из «Продолжить читать» на вкладке «Читают» (мусорка на
    /// карточке / «Очистить» в шапке секции, см. HomeView) — ЛОКАЛЬНО ТОЛЬКО:
    /// подтверждённого эндпоинта "удалить запись истории" нет, так что это не
    /// трогает историю на сервере, а просто прячет её из этого виджета на
    /// этом устройстве. Пока заглушка до реального API (пользователь пришлёт
    /// перехват) — см. кнопки "Очистить"/trashButton в HomeView.
    @Published private(set) var dismissedContinueReading: Set<String> = []

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
        static func dismissedContinueReading(_ site: LibSite) -> String { "bm_continue_dismissed_\(site.rawValue)" }
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
        if let raws = defaults.array(forKey: Keys.dismissedContinueReading(site)) as? [String] {
            dismissedContinueReading = Set(raws)
        } else {
            dismissedContinueReading = []
        }
    }

    // MARK: Папки

    /// Категории, видимые на ТЕКУЩЕМ активном сайте — прямая просьба "хочу
    /// чтобы от активного сайта зависели папки в закладках", как на
    /// реальном сайте (там это foldersBySiteId() во фронтенде, сам GET
    /// отдаёт папки СРАЗУ по всем сайтам без фильтра, см. siteIds).
    /// 5 стандартных всегда видны (site_ids:[0,1,2,3,4] подтверждено
    /// перехватом — то есть везде, кроме "сайта 5"/аниме, которого в
    /// LibSite вообще нет). siteIds == nil (см. комментарий у поля) —
    /// тоже показываем, а не прячем: не хотим, чтобы папка "пропадала"
    /// только из-за того, что мы ещё не знаем её реальную область.
    var allFolders: [BookmarkFolder] {
        let activeSiteId = SiteSession.shared.activeSite.rawValue
        return folders.filter { $0.isDefault || ($0.siteIds?.contains(activeSiteId) ?? true) }
    }

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
        // siteIds — сразу текущий активный сайт (POST /bookmarks/folder
        // ниже реально уходит с его Site-Id — см. MangaNetworkService.
        // createBookmarkFolder/baseURL(siteId:)), чтобы новая папка сразу
        // была видна только там, где её создали, не дожидаясь следующего
        // syncFoldersFromServer().
        let folder = BookmarkFolder(id: UUID().uuidString, name: trimmed, isDefault: false,
                                     siteIds: [SiteSession.shared.activeSite.rawValue])
        folders.append(folder)
        persistFolders()

        // Локально папка уже создана (экран не ждёт сеть) — пушим создание в
        // РЕАЛЬНЫЙ аккаунт через подтверждённый `POST /bookmarks/folder` (см.
        // MangaNetworkService.createBookmarkFolder). Ответ теперь та же
        // форма, что и у GET /bookmarks/folder/{userId} (UserBookmarkFolder)
        // — забираем РЕАЛЬНЫЕ color/notify/public/site_ids, а не гадаем.
        Task {
            do {
                let serverFolder = try await MangaNetworkService.shared.createBookmarkFolder(name: trimmed)
                if let idx = self.folders.firstIndex(where: { $0.id == folder.id }) {
                    self.folders[idx].serverId = serverFolder.id
                    self.folders[idx].colorHex = serverFolder.colorHex
                    self.folders[idx].notify = serverFolder.notify
                    self.folders[idx].isPublic = serverFolder.isPublic
                    self.folders[idx].siteIds = serverFolder.siteIds
                    self.persistFolders()
                }
            } catch {
                print("[BookmarksStore] не удалось создать папку (\(trimmed)) на сервере: \(error)")
            }
        }
        return folder
    }

    /// Переименовать/сменить цвет/приватность/уведомления кастомной папки —
    /// ПОДТВЕРЖДЕНО перехватом: `PUT /bookmarks/folder/{id}` (см.
    /// MangaNetworkService.updateBookmarkFolder), тело ВСЕГДА полное — эти 4
    /// поля шлём разом, частичного патча на сервере нет. Только для
    /// кастомных, уже подтверждённых сервером папок (serverId != nil) — 5
    /// стандартных на реальном сайте вообще не переименовываются, там нет
    /// такого UI. Применяется локально СРАЗУ (экран не ждёт сеть), пуш — в
    /// фоне.
    func updateFolder(_ folderId: String, name: String, colorHex: String, notify: Bool, isPublic: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = folders.firstIndex(where: { $0.id == folderId }),
              let serverId = folders[idx].serverId else { return }
        folders[idx].name = trimmed
        folders[idx].colorHex = colorHex
        folders[idx].notify = notify
        folders[idx].isPublic = isPublic
        persistFolders()

        Task {
            do {
                try await MangaNetworkService.shared.updateBookmarkFolder(
                    id: serverId, name: trimmed, colorHex: colorHex, notify: notify, isPublic: isPublic)
            } catch {
                print("[BookmarksStore] не удалось переименовать папку (\(trimmed)) на сервере: \(error)")
            }
        }
    }

    /// Удалить кастомную папку — ПОДТВЕРЖДЕНО перехватом: `DELETE
    /// /bookmarks/folder/{id}` (см. MangaNetworkService.deleteBookmarkFolder).
    /// `moveTo` — id ДРУГОЙ локальной папки, куда перенести тайтлы из
    /// удаляемой (реальный сайт делает перенос ЭТИМ ЖЕ запросом, не отдельным
    /// — сервер сам переставляет status у затронутых закладок). `nil` —
    /// тайтлы удаляемой папки пропадают вместе с ней (ровно то же самое
    /// поведение, что и на сайте по умолчанию — там перенос отдельная,
    /// самостоятельно включаемая галочка). Только для кастомных папок с
    /// известным serverId — 5 стандартных не удаляются никогда.
    func deleteFolder(_ folderId: String, moveTo targetFolderId: String?) {
        guard let idx = folders.firstIndex(where: { $0.id == folderId }), let serverId = folders[idx].serverId else { return }
        let targetFolder = targetFolderId.flatMap { id in folders.first(where: { $0.id == id }) }
        let moveToServerId = targetFolder?.apiId ?? targetFolder?.serverId

        if let targetFolder, moveToServerId != nil {
            for i in items.indices where items[i].folderId == folderId {
                items[i].folderId = targetFolder.id
            }
        } else {
            items.removeAll { $0.folderId == folderId }
        }
        folders.remove(at: idx)
        persistItems()
        persistFolders()

        Task {
            do {
                try await MangaNetworkService.shared.deleteBookmarkFolder(id: serverId, moveTo: moveToServerId)
            } catch {
                print("[BookmarksStore] не удалось удалить папку на сервере (serverId: \(serverId)): \(error)")
            }
        }
    }

    /// Меняет порядок папок (см. BookmarksView — щит редактирования списков
    /// по иконке карандаша) — определяет порядок чипов внизу Закладок. Чисто
    /// локальная настройка отображения — реальный `PUT /bookmarks/folder/
    /// order` на сервере ЕСТЬ (перехвачено), но пока не подключён.
    /// `fromOffsets`/`toOffset` — индексы из ОТОБРАЖАЕМОГО списка
    /// (allFolders, отфильтрован по активному сайту — см. выше), не из
    /// полного folders, поэтому переставляем именно видимую сейчас
    /// подпоследовательность, не трогая позиции папок других сайтов.
    func moveFolders(fromOffsets: IndexSet, toOffset: Int) {
        var newVisibleOrder = allFolders
        newVisibleOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let visibleIds = Set(newVisibleOrder.map { $0.id })
        // Числовые id для пуша на сервер — считаем ДО того, как очередь ниже
        // израсходует newVisibleOrder через removeFirst().
        let pushOrder = newVisibleOrder.compactMap { $0.apiId ?? $0.serverId }
        var queue = newVisibleOrder
        folders = folders.map { folder in
            guard visibleIds.contains(folder.id) else { return folder }
            return queue.removeFirst()
        }
        persistFolders()

        // Реальный сервер поддерживает сортировку — ПОДТВЕРЖДЕНО перехватом
        // (см. MangaNetworkService.saveBookmarkFolderOrder). Best-effort,
        // тихо — экран не ждёт сеть и не показывает ошибку при неудаче,
        // локальный порядок уже применён.
        guard AuthSession.shared.isLoggedIn, pushOrder.count == newVisibleOrder.count else { return }
        Task {
            do {
                try await MangaNetworkService.shared.saveBookmarkFolderOrder(pushOrder)
            } catch {
                print("[BookmarksStore] не удалось запушить порядок папок на сервер: \(error)")
            }
        }
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
            items.append(BookmarkedTitle(slug: slug, title: title, coverURL: coverURL, folderId: folderId, rating: rating, addedAt: Date()))
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

    /// Кэширует ТВОЮ личную оценку тайтла (см. BookmarkedTitle.myRating) —
    /// no-op, если этого тайтла нет в закладках. Вызывается из
    /// MangaDetailView при каждой загрузке/обновлении карточки (реальное
    /// значение `MangaRating.user`, см. MangaModels.swift), в т.ч. сразу
    /// после того, как поставили оценку через RatingSheet (submitRating
    /// перезагружает detail).
    func setMyRating(_ rating: Int?, forSlug slug: String) {
        guard let index = items.firstIndex(where: { $0.slug == slug }), items[index].myRating != rating else { return }
        items[index].myRating = rating
        persistItems()
    }

    // MARK: "Прочитано N раз" (перечитывания)

    /// Сколько раз тайтл был (пере)прочитан — см. BookmarkedTitle.
    /// rewatchHistory. Включает текущий незакрытый период, если есть —
    /// ровно как считает сам сервер (rewatches = count(rewatches_history)).
    func rewatchCount(forSlug slug: String) -> Int {
        items.first { $0.slug == slug }?.rewatchHistory?.count ?? 0
    }

    /// Начать новый период перечитывания — добавляет открытый период
    /// (start = сегодня, end = nil) в конец истории. No-op, если уже есть
    /// незакрытый период (сперва нужно его завершить — см. finishRewatch).
    func startRewatch(forSlug slug: String) {
        guard let idx = items.firstIndex(where: { $0.slug == slug }) else { return }
        var history = items[idx].rewatchHistory ?? []
        guard !history.contains(where: { $0.end == nil }) else { return }
        history.append(RewatchPeriod(start: Self.rewatchDateFormatter.string(from: Date()), end: nil))
        items[idx].rewatchHistory = history
        persistItems()
        pushMeta(forSlug: slug)
    }

    /// Закрыть текущий открытый период — end = сегодня. No-op, если
    /// открытого периода нет.
    func finishRewatch(forSlug slug: String) {
        guard let idx = items.firstIndex(where: { $0.slug == slug }),
              var history = items[idx].rewatchHistory,
              let openIdx = history.firstIndex(where: { $0.end == nil }) else { return }
        history[openIdx].end = Self.rewatchDateFormatter.string(from: Date())
        items[idx].rewatchHistory = history
        persistItems()
        pushMeta(forSlug: slug)
    }

    /// Удалить период (например, добавленный по ошибке) — свайп в
    /// RewatchHistorySheet.
    func deleteRewatchPeriod(forSlug slug: String, at offsets: IndexSet) {
        guard let idx = items.firstIndex(where: { $0.slug == slug }), var history = items[idx].rewatchHistory else { return }
        history.remove(atOffsets: offsets)
        items[idx].rewatchHistory = history
        persistItems()
        pushMeta(forSlug: slug)
    }

    private static let rewatchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Пушит meta (comment+rewatchHistory) текущего состояния тайтла на
    /// сервер — общий хвост для start/finish/deleteRewatchPeriod выше.
    /// ПОДТВЕРЖДЕНО перехватом: тот же `POST /bookmarks`, что и смена
    /// папки — нужен ИЗВЕСТНЫЙ числовой status папки (apiId/serverId), без
    /// него молча не пушит: локальное состояние уже применено, а следующий
    /// syncFromServer всё равно перезапишет его реальным.
    private func pushMeta(forSlug slug: String) {
        guard let item = items.first(where: { $0.slug == slug }),
              let folder = folders.first(where: { $0.id == item.folderId }),
              let status = folder.apiId ?? folder.serverId else { return }
        let comment = item.comment
        let history = item.rewatchHistory ?? []
        Task {
            do {
                try await MangaNetworkService.shared.updateBookmarkMeta(
                    slug: slug, status: status, comment: comment, rewatchHistory: history)
            } catch {
                print("[BookmarksStore] не удалось сохранить историю перечитываний (\(slug)) на сервере: \(error)")
            }
        }
    }

    // MARK: Групповые действия (мультивыбор)

    enum BulkActionError: LocalizedError {
        case unresolvedFolder
        case noMediaIds

        var errorDescription: String? {
            switch self {
            case .unresolvedFolder: return "Не удалось определить папку назначения."
            case .noMediaIds: return "Для выбранных тайтлов ещё не известен их id — потяните экран вниз, чтобы обновить, и попробуйте снова."
            }
        }
    }

    /// Массово переместить выбранные тайтлы в другую папку — ПОДТВЕРЖДЕНО
    /// перехватом: `PUT /bookmarks/bulk` (см. MangaNetworkService.
    /// bulkMoveBookmarks). `async throws`, не fire-and-forget как большинство
    /// остальных действий в этом файле — это МАССОВАЯ операция, экран должен
    /// дождаться реального ответа сервера и показать ошибку, если что-то не
    /// удалось, а не молча закрыться. Локально применяется ТОЛЬКО после
    /// успешного ответа.
    func bulkMove(slugs: [String], toFolder folderId: String) async throws {
        guard let target = folders.first(where: { $0.id == folderId }),
              let status = target.apiId ?? target.serverId else {
            throw BulkActionError.unresolvedFolder
        }
        let mediaIds = slugs.compactMap { slug in items.first(where: { $0.slug == slug })?.mediaId }
        guard !mediaIds.isEmpty else { throw BulkActionError.noMediaIds }

        try await MangaNetworkService.shared.bulkMoveBookmarks(mediaIds: mediaIds, status: status)

        for slug in slugs {
            if let idx = items.firstIndex(where: { $0.slug == slug }) {
                items[idx].folderId = folderId
            }
        }
        persistItems()
    }

    /// Массово убрать выбранные тайтлы из закладок — ПОДТВЕРЖДЕНО
    /// перехватом: `DELETE /bookmarks/bulk` (см. MangaNetworkService.
    /// bulkDeleteBookmarks). Та же логика "ждём сеть", что и у bulkMove
    /// выше.
    func bulkDelete(slugs: [String]) async throws {
        let mediaIds = slugs.compactMap { slug in items.first(where: { $0.slug == slug })?.mediaId }
        guard !mediaIds.isEmpty else { throw BulkActionError.noMediaIds }

        try await MangaNetworkService.shared.bulkDeleteBookmarks(mediaIds: mediaIds)

        items.removeAll { slugs.contains($0.slug) }
        persistItems()
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

    /// Подтягивает РЕАЛЬНЫЙ список папок аккаунта — `GET /bookmarks/folder/
    /// {userId}` (см. MangaNetworkService.fetchUserBookmarkFolders) — тот же
    /// эндпоинт, что уже используется для чужих публичных списков
    /// (UserBookmarksView) и для настроек уведомлений
    /// (NotificationSettingsView). Раньше папки, созданные НЕ через это
    /// приложение (на сайте/другом клиенте), были не видны — теперь ЛЮБАЯ
    /// небазовая (id не 1-5) папка аккаунта появляется в folders с реальным
    /// serverId, и закладки в ней (см. syncFromServer ниже) больше не
    /// пропускаются. 5 стандартных (id 1-5) не трогаем — они уже
    /// представлены хардкодом (BookmarkFolder.defaults, apiId 1-5).
    /// Мержит по serverId, не создаёт дублей при повторных вызовах и не
    /// теряет уже созданные ЭТИМ приложением папки (createFolder() выставляет
    /// serverId сразу после POST /bookmarks/folder — тут они просто найдутся
    /// по тому же id и обновятся, а не задублируются). Заодно подтягивает
    /// siteIds — реальную область видимости папки (см. BookmarkFolder.
    /// siteIds/allFolders), ПОДТВЕРЖДЕНО перехватом: GET отдаёт папки СРАЗУ
    /// по всем сайтам аккаунта, без фильтра по Site-Id запроса.
    private func syncFoldersFromServer() async {
        guard let userId = AuthSession.shared.userId,
              let remoteFolders = try? await MangaNetworkService.shared.fetchUserBookmarkFolders(userId: userId) else { return }
        var changed = false
        for remote in remoteFolders where !(1...5).contains(remote.id) {
            if let idx = folders.firstIndex(where: { $0.serverId == remote.id }) {
                if folders[idx].name != remote.name { folders[idx].name = remote.name; changed = true }
                if folders[idx].colorHex != remote.colorHex { folders[idx].colorHex = remote.colorHex; changed = true }
                if folders[idx].siteIds != remote.siteIds { folders[idx].siteIds = remote.siteIds; changed = true }
                if folders[idx].notify != remote.notify { folders[idx].notify = remote.notify; changed = true }
                if folders[idx].isPublic != remote.isPublic { folders[idx].isPublic = remote.isPublic; changed = true }
            } else {
                folders.append(BookmarkFolder(id: "server-\(remote.id)", name: remote.name, isDefault: false,
                                               serverId: remote.id, colorHex: remote.colorHex, siteIds: remote.siteIds,
                                               notify: remote.notify, isPublic: remote.isPublic))
                changed = true
            }
        }
        if changed { persistFolders() }
    }

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

        // Сначала мержим РЕАЛЬНЫЙ список папок аккаунта (см.
        // syncFoldersFromServer) — иначе закладки в кастомных папках,
        // созданных не через это приложение, ниже не смогут найти свою
        // папку по status и будут пропущены.
        await syncFoldersFromServer()

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
            // выше). Ищем сперва среди стандартных (apiId), потом среди
            // ЛЮБЫХ пользовательских папок аккаунта (serverId) — включая
            // созданные не через это приложение (на сайте/другом клиенте):
            // syncFoldersFromServer() выше уже смержил их все в folders по
            // РЕАЛЬНОМУ `GET /bookmarks/folder/{userId}`, так что теперь они
            // тоже находятся, а не пропускаются молча.
            guard let folder = folders.first(where: { $0.apiId == status })
                    ?? folders.first(where: { $0.serverId == status }) else { continue }
            let slug = entry.media.apiSlug
            if let idx = items.firstIndex(where: { $0.slug == slug }) {
                items[idx].folderId = folder.id
                items[idx].title = entry.media.displayTitle
                items[idx].coverURL = entry.media.coverURLString
                items[idx].serverId = entry.id
                items[idx].rating = entry.media.rating?.value
                items[idx].myRating = entry.myScore
                items[idx].rewatchHistory = entry.meta?.rewatchHistory ?? []
                items[idx].comment = entry.meta?.comment
                items[idx].mediaId = entry.media.id
            } else {
                items.append(BookmarkedTitle(slug: slug, title: entry.media.displayTitle,
                                              coverURL: entry.media.coverURLString,
                                              folderId: folder.id, serverId: entry.id,
                                              rating: entry.media.rating?.value,
                                              myRating: entry.myScore,
                                              rewatchHistory: entry.meta?.rewatchHistory ?? [],
                                              comment: entry.meta?.comment,
                                              mediaId: entry.media.id))
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

    /// «Продолжить читать» на вкладке «Читают» (см. HomeView) — по одной, самой
    /// свежей записи на каждый тайтл. historyEntries уже отдаются сервером от
    /// новых к старым (см. syncHistoryFromServer) — дедуп по media.id, сохраняя
    /// порядок первого (=самого свежего) вхождения, даёт готовый список без
    /// отдельного запроса/сортировки.
    var continueReadingEntries: [HistoryEntry] {
        var seenMangaIds = Set<Int>()
        var result: [HistoryEntry] = []
        for entry in historyEntries {
            guard seenMangaIds.insert(entry.media.id).inserted else { continue }
            guard !dismissedContinueReading.contains(entry.media.apiSlug) else { continue }
            result.append(entry)
        }
        return result
    }

    /// Мусорка на карточке — скрывает один тайтл из «Продолжить читать»
    /// (только на этом устройстве, см. dismissedContinueReading выше).
    func dismissContinueReading(slug: String) {
        dismissedContinueReading.insert(slug)
        persistDismissedContinueReading()
    }

    /// «Очистить» в шапке секции — прячет ВСЕ тайтлы, видимые в «Продолжить
    /// читать» ПРЯМО СЕЙЧАС (а не будущие: новая прочитанная глава снова
    /// вернёт тайтл в список — «Очистить» не выключает виджет насовсем).
    func clearContinueReading() {
        dismissedContinueReading.formUnion(continueReadingEntries.map(\.media.apiSlug))
        persistDismissedContinueReading()
    }

    private func persistDismissedContinueReading() {
        let site = SiteSession.shared.activeSite
        defaults.set(Array(dismissedContinueReading), forKey: Keys.dismissedContinueReading(site))
    }

    /// Дозаполняет totalChapters для тайтла в «Продолжить читать», когда он
    /// пришёл из истории аккаунта без известного количества глав (см.
    /// ReadingProgress.totalChapters). В отличие от setProgress НЕ трогает
    /// lastReadAt/readCount — только добавляет знаменатель к уже известному
    /// прогрессу, чтобы не переставить тайтл в начало списка "недавно читал"
    /// просто из-за фонового досчёта количества глав.
    func setTotalChaptersIfUnknown(slug: String, total: Int) {
        guard let existing = progress[slug], existing.totalChapters <= 0, total > 0 else { return }
        progress[slug] = ReadingProgress(
            lastChapterNumber: existing.lastChapterNumber,
            lastChapterVolume: existing.lastChapterVolume,
            readCount: existing.readCount,
            totalChapters: total,
            lastReadAt: existing.lastReadAt
        )
        persistProgress()
    }

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
