import Foundation
import Combine
import Network

// MARK: - Модель скачанного

/// Одна скачанная глава: метаданные + число реально сохранённых страниц.
/// Файлы страниц лежат в <Documents>/Downloads/<slug>/<id>/000.jpg…
struct DownloadedChapter: Codable, Identifiable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let name: String?
    var pageCount: Int
    /// Ветка (команда), чьи страницы скачаны — у одной главы могут быть разные
    /// переводы. nil у старых записей (до появления веток).
    var branchId: Int?

    var displayTitle: String {
        var parts = ["Том \(volume)", "Глава \(number)"]
        if let name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}

/// Один скачанный тайтл со списком глав. Сохраняется в manifest.json.
struct DownloadedTitle: Codable, Identifiable, Hashable {
    let slug: String
    var id: String { slug }
    var title: String
    var typeLabel: String?
    var coverURLString: String?
    var chapters: [DownloadedChapter]
    var addedAt: Date

    /// Скачанные главы в виде ChapterItem — для оффлайн-ридера. Дедуп по id
    /// (если одна глава скачана в нескольких ветках — берём первую). Ветку
    /// прокидываем через branches, чтобы оффлайн-ридер нашёл нужную папку.
    var chapterItems: [ChapterItem] {
        var seen = Set<Int>()
        var result: [ChapterItem] = []
        for ch in chapters where !seen.contains(ch.id) {
            seen.insert(ch.id)
            let br = ch.branchId.map { [ChapterBranch(branchId: $0)] }
            result.append(ChapterItem(id: ch.id, volume: ch.volume, number: ch.number, name: ch.name, branches: br))
        }
        return result
    }
}

// MARK: - Менеджер загрузок

/// Реально качает страницы глав и складывает их структурировано на устройство,
/// ведёт список скачанного (manifest.json) и публикует прогресс активных
/// загрузок. Синглтон, @MainActor — весь публикуемый стейт меняется на главном
/// потоке; тяжёлая сеть/запись файлов вынесены в nonisolated static-хелперы.
@MainActor
final class DownloadsManager: ObservableObject {

    static let shared = DownloadsManager()

    /// Прогресс одной активной загрузки тайтла.
    struct Progress: Equatable {
        var total: Int
        var completed: Int
        var currentTitle: String
        var finished: Bool
        var failed: Bool
        /// На паузе (см. pause()/resume()) — в отличие от cancel()/delete(),
        /// уже скачанные главы и очередь остаются на месте, докачать можно
        /// кнопкой «Возобновить».
        var paused: Bool = false

        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// Параметры запущенной загрузки тайтла — нужны, чтобы resume() знал, ЧТО
    /// докачивать (полный список глав, а не только оставшиеся: см. resume()).
    private struct PendingDownload {
        let title: String
        let typeLabel: String?
        let coverURLString: String?
        let heroURLString: String?
        let chapters: [ChapterItem]
        let branchId: Int?
    }

    /// Всплывающее уведомление (тост) — например «Загрузка начата». Своё id у
    /// каждого события, чтобы одинаковый текст подряд всё равно переанимировался.
    struct Banner: Equatable, Identifiable {
        let id = UUID()
        let text: String
    }

    /// Список скачанных тайтлов (самые свежие сверху).
    @Published private(set) var titles: [DownloadedTitle] = []
    /// Прогресс по slug — есть запись, пока идёт загрузка (и ещё пару секунд после).
    @Published private(set) var progress: [String: Progress] = [:]
    /// Текущий тост (nil — ничего не показываем). Наблюдается в RootView.
    @Published private(set) var banner: Banner?
    /// Прогресс скачивания ОТДЕЛЬНОЙ главы (0…1), ключ "slug#chapterId". Есть
    /// запись, пока глава качается; по завершении удаляется.
    @Published private(set) var chapterProgress: [String: Double] = [:]

    /// "Скачивать только через Wi-Fi" (см. StorageSettingsView) — реально
    /// блокирует СТАРТ новой загрузки на сотовой сети (см. canStartDownload
    /// ниже), но НЕ отслеживает переключение сети посреди уже идущей
    /// загрузки — это отдельная, более сложная доработка, пока не сделана.
    @Published var wifiOnlyDownloads: Bool {
        didSet { defaults.set(wifiOnlyDownloads, forKey: Keys.wifiOnly) }
    }
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    /// Сколько глав качаем одновременно при загрузке всего тайтла (см. run()).
    /// 4 — по ощущениям близко к тому, сколько реально параллелится, если
    /// вручную потыкать иконки скачивания подряд; больше не даёт заметного
    /// выигрыша и сильнее грузит CDN/память.
    private static let concurrentChapterDownloads = 4

    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let wifiOnly = "downloads_wifi_only"
    }
    /// Активные задачи загрузки по slug — нужны, чтобы отменять скачивание.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var chapterTasks: [String: Task<Void, Never>] = [:]
    /// Параметры последнего запуска download() по slug — для resume() после
    /// pause(). Очищается при полном завершении/удалении тайтла.
    private var pending: [String: PendingDownload] = [:]

    private init() {
        wifiOnlyDownloads = defaults.bool(forKey: Keys.wifiOnly)
        load()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.currentPath = path }
        }
        pathMonitor.start(queue: DispatchQueue(label: "DownloadsManager.pathMonitor"))
    }

    /// Можно ли СТАРТОВАТЬ новую загрузку прямо сейчас — true, если ограничение
    /// выключено, или включено и мы реально на Wi-Fi. currentPath — nil в
    /// первые доли секунды после старта приложения (монитор ещё не успел
    /// отдать первый путь) — в этом случае не блокируем, чтобы не ловить
    /// ложный отказ сразу при холодном старте.
    private var canStartDownload: Bool {
        guard wifiOnlyDownloads, let currentPath else { return true }
        return currentPath.usesInterfaceType(.wifi)
    }

    // MARK: Пути на диске

    private var baseDir: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads", isDirectory: true)
    }
    private var manifestURL: URL { baseDir.appendingPathComponent("manifest.json") }

    private func titleDir(_ slug: String) -> URL {
        baseDir.appendingPathComponent(Self.sanitize(slug), isDirectory: true)
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
         .replacingOccurrences(of: ":", with: "_")
         .replacingOccurrences(of: "?", with: "_")
    }

    // MARK: Публичное API

    func isDownloaded(slug: String) -> Bool { titles.contains { $0.slug == slug } }
    func isDownloading(slug: String) -> Bool { progress[slug]?.finished == false }

    /// Локальный файл обложки (если уже скачан) — для оффлайн-показа в списке.
    func localCoverURL(slug: String) -> URL? {
        let f = titleDir(slug).appendingPathComponent("cover.jpg")
        return fm.fileExists(atPath: f.path) ? f : nil
    }

    /// Локальный файл «хиро»-фона карточки тайтла (если уже скачан).
    func localHeroURL(slug: String) -> URL? {
        let f = titleDir(slug).appendingPathComponent("hero.jpg")
        return fm.fileExists(atPath: f.path) ? f : nil
    }

    /// Качает обложку (cover.jpg) и «хиро»-фон (hero.jpg) тайтла на диск — и
    /// при по-главном скачивании (одна иконка), и при загрузке всего тайтла,
    /// чтобы после скачивания хотя бы одной главы карточка тайтла открывалась
    /// офлайн с обеими картинками, а не только с превью-обложкой.
    private func saveTitleImages(slug: String, coverURLString: String?, heroURLString: String?) async {
        if let coverURLString, let url = URL(string: coverURLString), let data = await Self.fetchData([url]) {
            try? data.write(to: titleDir(slug).appendingPathComponent("cover.jpg"))
        }
        if let heroURLString, let url = URL(string: heroURLString), let data = await Self.fetchData([url]) {
            try? data.write(to: titleDir(slug).appendingPathComponent("hero.jpg"))
        }
    }

    /// Папка страниц конкретной главы+ветки на диске.
    private func chapterDir(_ slug: String, _ chapterId: Int, _ branchId: Int?) -> URL {
        titleDir(slug).appendingPathComponent("\(chapterId)-b\(branchId ?? 0)", isDirectory: true)
    }

    /// Локальные файлы страниц скачанной главы (отсортированы по имени: 000, 001…).
    /// Пусто — глава/ветка не скачана, тогда ридер грузит из сети.
    func localPageFiles(slug: String, chapterId: Int, branchId: Int?) -> [URL] {
        let dir = chapterDir(slug, chapterId, branchId)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let exts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif"]
        return files
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Поставить переданные главы тайтла в очередь и начать загрузку.
    /// branchId — явно выбранная ветка перевода (см. DownloadTitleSheet):
    /// nil качает каждую главу её собственной первой веткой (как раньше),
    /// значение — качает ВСЕ переданные главы именно этой веткой/переводчиком.
    /// heroURLString — «хиро»-фон карточки тайтла (MangaDetail.backgroundURL),
    /// отдельно от обычной обложки (coverURLString) — качаются оба (см.
    /// saveTitleImages), чтобы карточка тайтла открывалась офлайн один-в-один.
    func download(slug: String, title: String, typeLabel: String?, coverURLString: String?, heroURLString: String? = nil, chapters: [ChapterItem], branchId: Int? = nil) {
        guard !chapters.isEmpty else { return }
        guard progress[slug]?.finished != false else { return } // уже качается
        guard canStartDownload else {
            showBanner("Только Wi-Fi — включите Wi-Fi или отключите ограничение в Данные и память")
            return
        }

        pending[slug] = PendingDownload(title: title, typeLabel: typeLabel, coverURLString: coverURLString,
                                        heroURLString: heroURLString, chapters: chapters, branchId: branchId)
        progress[slug] = Progress(total: chapters.count, completed: 0, currentTitle: "", finished: false, failed: false)
        showBanner("Загрузка начата")
        let task = Task { [weak self] in
            await self?.run(slug: slug, title: title, typeLabel: typeLabel, coverURLString: coverURLString, heroURLString: heroURLString, chapters: chapters, branchId: branchId)
            self?.tasks[slug] = nil
        }
        tasks[slug] = task
    }

    /// Приостановить активную загрузку тайтла — В ОТЛИЧИЕ от cancel()/delete(),
    /// НЕ стирает уже скачанные главы и не убирает запись из «Загрузок»:
    /// докачать оставшиеся главы можно кнопкой «Возобновить» (см. resume()).
    func pause(slug: String) {
        guard progress[slug]?.finished == false else { return }
        tasks[slug]?.cancel()
        tasks[slug] = nil
        progress[slug]?.paused = true
    }

    func isPaused(slug: String) -> Bool { progress[slug]?.paused == true }

    /// Продолжить приостановленную загрузку: докачивает только те главы из
    /// исходного запроса, которых ещё нет на диске — уже скачанные не трогает.
    func resume(slug: String) {
        guard let req = pending[slug], progress[slug]?.paused == true else { return }
        guard canStartDownload else {
            showBanner("Только Wi-Fi — включите Wi-Fi или отключите ограничение в Данные и память")
            return
        }
        let downloadedKeys = Set((titles.first(where: { $0.slug == slug })?.chapters ?? [])
            .map { "\($0.id)-\($0.branchId ?? 0)" })
        let remaining = req.chapters.filter { chapter in
            let bid = req.branchId ?? chapter.primaryBranchId
            return !downloadedKeys.contains("\(chapter.id)-\(bid ?? 0)")
        }
        guard !remaining.isEmpty else {
            // Всё, что было в очереди, уже скачано — просто закрываем прогресс.
            progress[slug]?.paused = false
            progress[slug]?.finished = true
            pending[slug] = nil
            save()
            let s = slug
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.progress[s] = nil }
            return
        }
        progress[slug]?.paused = false
        let task = Task { [weak self] in
            await self?.run(slug: slug, title: req.title, typeLabel: req.typeLabel, coverURLString: req.coverURLString,
                            heroURLString: req.heroURLString, chapters: remaining, branchId: req.branchId)
            self?.tasks[slug] = nil
        }
        tasks[slug] = task
    }

    // MARK: Офлайн-кэш карточки тайтла (описание/оценки)

    /// Карточка тайтла, сохранённая на диск при скачивании (см. cacheDetailAndStats
    /// ниже) — читает MangaDetailViewModel, когда сеть недоступна, чтобы у
    /// скачанного тайтла описание/жанры/рейтинг показывались и офлайн, а не
    /// текстом "нет сети".
    func cachedDetail(slug: String) -> MangaDetail? {
        guard let data = try? Data(contentsOf: titleDir(slug).appendingPathComponent("detail.json")) else { return nil }
        return try? JSONDecoder().decode(APIObjectResponse<MangaDetail>.self, from: data).data
    }

    /// Статистика (виджет оценок), сохранённая на диск при скачивании — как cachedDetail.
    func cachedStats(slug: String) -> MangaStats? {
        guard let data = try? Data(contentsOf: titleDir(slug).appendingPathComponent("stats.json")) else { return nil }
        return try? JSONDecoder().decode(APIObjectResponse<MangaStats>.self, from: data).data
    }

    /// Скачивает и сохраняет сырой JSON карточки+статистики тайтла на диск —
    /// вызывается при первом появлении записи тайтла в загрузках (whole-title
    /// и по-главная загрузка), чтобы офлайн-открытие карточки (см. cachedDetail/
    /// cachedStats выше) не зависело от сети.
    private func cacheDetailAndStats(slug: String) async {
        if let data = try? await MangaNetworkService.shared.fetchMangaDetailRawData(slug: slug) {
            try? data.write(to: titleDir(slug).appendingPathComponent("detail.json"))
        }
        if let data = try? await MangaNetworkService.shared.fetchMangaStatsRawData(slug: slug) {
            try? data.write(to: titleDir(slug).appendingPathComponent("stats.json"))
        }
    }

    // MARK: По-главное скачивание (отдельная глава+ветка)

    /// nonisolated — чистая склейка строки, без обращения к состоянию актора;
    /// нужно звать и из nonisolated-тела withTaskGroup (см. run()).
    nonisolated func chapterKey(_ slug: String, _ id: Int, _ branchId: Int?) -> String { "\(slug)#\(id)#\(branchId ?? 0)" }

    func isChapterDownloaded(slug: String, chapterId: Int, branchId: Int?) -> Bool {
        titles.first(where: { $0.slug == slug })?.chapters.contains { $0.id == chapterId && ($0.branchId ?? 0) == (branchId ?? 0) } ?? false
    }

    /// Прогресс скачивания главы+ветки 0…1, или nil если она сейчас не качается.
    func chapterFraction(slug: String, chapterId: Int, branchId: Int?) -> Double? {
        chapterProgress[chapterKey(slug, chapterId, branchId)]
    }

    /// Скачать ОДНУ главу конкретной ветки (с прогрессом по %).
    func downloadChapter(slug: String, title: String, typeLabel: String?, coverURLString: String?, heroURLString: String? = nil, chapter: ChapterItem, branchId: Int?) {
        let bid = branchId ?? chapter.primaryBranchId
        let key = chapterKey(slug, chapter.id, bid)
        guard chapterProgress[key] == nil, !isChapterDownloaded(slug: slug, chapterId: chapter.id, branchId: bid) else { return }
        guard canStartDownload else {
            showBanner("Только Wi-Fi — включите Wi-Fi или отключите ограничение в Данные и память")
            return
        }
        chapterProgress[key] = 0
        let task = Task { [weak self] in
            await self?.runChapter(slug: slug, title: title, typeLabel: typeLabel, coverURLString: coverURLString, heroURLString: heroURLString, chapter: chapter, branchId: bid)
            self?.chapterTasks[key] = nil
        }
        chapterTasks[key] = task
    }

    /// Удалить одну скачанную главу+ветку (если у тайтла не осталось глав —
    /// убираем и сам тайтл).
    func deleteChapter(slug: String, chapterId: Int, branchId: Int?) {
        let key = chapterKey(slug, chapterId, branchId)
        chapterTasks[key]?.cancel()
        chapterTasks[key] = nil
        chapterProgress[key] = nil
        try? fm.removeItem(at: chapterDir(slug, chapterId, branchId))
        if let idx = titles.firstIndex(where: { $0.slug == slug }) {
            titles[idx].chapters.removeAll { $0.id == chapterId && ($0.branchId ?? 0) == (branchId ?? 0) }
            if titles[idx].chapters.isEmpty {
                titles.remove(at: idx)
                try? fm.removeItem(at: titleDir(slug))
            }
            save()
        }
    }

    /// Человекочитаемый размер скачанной главы+ветки на диске (напр. «12,3 МБ»).
    func chapterSizeString(slug: String, chapterId: Int, branchId: Int?) -> String {
        let dir = chapterDir(slug, chapterId, branchId)
        let bytes = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Данные и память (StorageSettingsView)

    /// Рекурсивный размер папки в байтах — общий хелпер для "Скачанные
    /// тайтлы"/"Кеш загрузки" ниже.
    private static func directorySize(_ url: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Общий объём ВСЕХ скачанных тайтлов на диске (рекурсивно) — реальные
    /// данные, а не оценка.
    var totalDownloadedBytes: Int64 { Self.directorySize(baseDir, fm: fm) }

    /// Папки-сироты в Downloads/, оставшиеся от отменённых/недокачанных/не
    /// доигравших до конца загрузок (тайтл-папка без записи в manifest.json,
    /// или папка главы внутри известного тайтла, которой нет в его chapters).
    /// Реальный мусор — можно чистить без риска задеть что-то из "Загрузок".
    private func orphanedDownloadPaths() -> [URL] {
        guard let items = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let knownBySlug = Dictionary(uniqueKeysWithValues: titles.map { (Self.sanitize($0.slug), $0) })
        var result: [URL] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let title = knownBySlug[item.lastPathComponent] else {
                result.append(item)
                continue
            }
            let knownChapterDirs = Set(title.chapters.map { "\($0.id)-b\($0.branchId ?? 0)" })
            guard let subitems = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for sub in subitems {
                guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !knownChapterDirs.contains(sub.lastPathComponent) else { continue }
                result.append(sub)
            }
        }
        return result
    }

    func orphanedDownloadBytes() -> Int64 {
        orphanedDownloadPaths().reduce(Int64(0)) { $0 + Self.directorySize($1, fm: fm) }
    }

    func clearOrphanedDownloads() {
        for url in orphanedDownloadPaths() { try? fm.removeItem(at: url) }
    }

    private func runChapter(slug: String, title: String, typeLabel: String?, coverURLString: String?, heroURLString: String? = nil, chapter: ChapterItem, branchId: Int?) async {
        let key = chapterKey(slug, chapter.id, branchId)
        try? fm.createDirectory(at: titleDir(slug), withIntermediateDirectories: true)

        // Заводим запись тайтла, если её ещё нет (+ обложку, хиро-фон и
        // карточку для оффлайна) — качаем ИХ уже при первой скачанной главе,
        // а не только при "Скачать весь тайтл".
        if !titles.contains(where: { $0.slug == slug }) {
            upsertTitle(DownloadedTitle(slug: slug, title: title, typeLabel: typeLabel,
                                        coverURLString: coverURLString, chapters: [], addedAt: Date()))
            await saveTitleImages(slug: slug, coverURLString: coverURLString, heroURLString: heroURLString)
            await cacheDetailAndStats(slug: slug)
        }

        let dir = chapterDir(slug, chapter.id, branchId)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let result = try? await MangaNetworkService.shared.fetchPages(
            slug: slug, volume: chapter.volume, number: chapter.number, branchId: branchId
        ), !result.pages.isEmpty else {
            chapterProgress[key] = nil
            return
        }

        let total = result.pages.count
        var saved = 0
        for (idx, page) in result.pages.enumerated() {
            if Task.isCancelled { chapterProgress[key] = nil; return }
            let candidates = MangaImageURL.pageURLs(for: page)
            if !candidates.isEmpty, let data = await Self.fetchData(candidates) {
                let ext = (candidates.first?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "jpg"
                try? data.write(to: dir.appendingPathComponent(String(format: "%03d.%@", idx, ext)))
                saved += 1
            }
            chapterProgress[key] = Double(idx + 1) / Double(total)
        }

        if saved > 0 {
            appendChapter(
                DownloadedChapter(id: chapter.id, volume: chapter.volume,
                                  number: chapter.number, name: chapter.name, pageCount: saved, branchId: branchId),
                toSlug: slug
            )
        }
        chapterProgress[key] = nil
    }

    /// Отменить активную загрузку (то же, что удалить — недокачанное
    /// выбрасывается). Отдельное имя ради читаемости на вызывающей стороне.
    func cancel(slug: String) { delete(slug: slug) }

    /// Удалить скачанный тайтл целиком (файлы + запись) и остановить загрузку,
    /// если она ещё идёт.
    func delete(slug: String) {
        tasks[slug]?.cancel()
        tasks[slug] = nil
        pending[slug] = nil
        try? fm.removeItem(at: titleDir(slug))
        titles.removeAll { $0.slug == slug }
        progress[slug] = nil
        chapterProgress.keys.filter { $0.hasPrefix("\(slug)#") }.forEach { chapterProgress[$0] = nil }
        save()
    }

    /// Показать тост и убрать его через пару секунд (если его не сменил новый).
    /// Internal (не private) — этим же тостом («Загрузка начата» и т.п., см.
    /// RootView.DownloadToast) пользуются и другие экраны для своих
    /// уведомлений, не только сама загрузка (см. RatingSheet).
    func showBanner(_ text: String) {
        let b = Banner(text: text)
        banner = b
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if banner?.id == b.id { banner = nil }
        }
    }

    // MARK: Процесс загрузки

    private func run(slug: String, title: String, typeLabel: String?, coverURLString: String?, heroURLString: String? = nil, chapters: [ChapterItem], branchId: Int?) async {
        try? fm.createDirectory(at: titleDir(slug), withIntermediateDirectories: true)

        // Сразу заводим запись (с пустым списком глав) — чтобы тайтл появился в
        // разделе «Загрузки» с прогресс-баром ещё до конца скачивания.
        upsertTitle(DownloadedTitle(slug: slug, title: title, typeLabel: typeLabel,
                                    coverURLString: coverURLString, chapters: [], addedAt: Date()))

        // Обложка, хиро-фон и карточка тайтла (описание/жанры/оценки) — для
        // оффлайн-показа (см. cachedDetail/cachedStats и MangaDetailViewModel).
        // При resume() (докачка после паузы) это скачается заново — не страшно,
        // просто перезапишет те же файлы.
        await saveTitleImages(slug: slug, coverURLString: coverURLString, heroURLString: heroURLString)
        await cacheDetailAndStats(slug: slug)

        // Качаем несколько глав ОДНОВРЕМЕННО (пул из concurrentChapterDownloads
        // штук), а не строго по одной — раньше "Скачать весь тайтл" шёл
        // строго последовательно (одна глава от начала до конца, потом
        // следующая), из-за чего был заметно медленнее, чем вручную потыкать
        // несколько иконок "скачать" подряд (те запускают независимые Task,
        // которые сеть качает параллельно — см. downloadChapter/runChapter).
        // Внутри одной главы страницы по-прежнему качаются последовательно
        // (не бьём по одному и тому же CDN-серверу пачкой запросов сразу).
        //
        // ВАЖНО: тело withTaskGroup в этом режиме компиляции НЕ наследует
        // MainActor-изоляцию run() (в отличие от обычного async-кода) — прямой
        // вызов chapterDir()/progress[...]/appendChapter() отсюда не
        // компилируется ("call to main actor-isolated ... in a synchronous
        // nonisolated context"). Поэтому каждое обращение к состоянию актора
        // явно оборачиваем в `await MainActor.run { ... }`.
        await withTaskGroup(of: (chapter: ChapterItem, branchId: Int?, pageCount: Int, total: Int).self) { group in
            var iterator = chapters.makeIterator()

            func startNext() async {
                guard let chapter = iterator.next() else { return }
                let bid = branchId ?? chapter.primaryBranchId
                let dir = await MainActor.run { self.chapterDir(slug, chapter.id, bid) }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if Task.isCancelled { return }
                // Ключ такой же, как у по-главного скачивания одной иконкой
                // (chapterKey) — поэтому кружок прогресса в списке глав
                // (chapterDownloadControl) зелёными кружками отражает и
                // главы, качающиеся как часть "Скачать весь тайтл", а не
                // только те, что скачали отдельной иконкой.
                let key = self.chapterKey(slug, chapter.id, bid)
                group.addTask {
                    let (saved, total) = await Self.downloadChapter(slug: slug, chapter: chapter, branchId: bid, into: dir) { frac in
                        Task { await MainActor.run { self.chapterProgress[key] = frac } }
                    }
                    return (chapter, bid, saved, total)
                }
            }

            for _ in 0..<Self.concurrentChapterDownloads { await startNext() }

            while let result = await group.next() {
                await MainActor.run {
                    // Кружок прогресса убираем ВСЕГДА (даже на паузе) —
                    // иначе он застревал бы на последнем значении после
                    // pause(). ВАЖНО: главу, которая успела докачаться
                    // ПОЛНОСТЬЮ (pageCount == total), засчитываем и
                    // сохраняем в манифест ДАЖЕ если pause() уже отменил
                    // задачу — иначе до 4 параллельно качавшихся глав
                    // (см. concurrentChapterDownloads) в момент "Стоп"
                    // терялись бесследно: файлы на диске были, а в
                    // manifest.json записи не было, и resume() качал их
                    // заново с нуля (баг: "Стоп" выглядел как полная
                    // отмена, а "Возобновить" — как загрузка с 0%).
                    // Если же главу прервали НА СЕРЕДИНЕ — недокачанные
                    // файлы подчищаем, чтобы resume() начал её заново, а
                    // не подхватил половину.
                    self.chapterProgress[self.chapterKey(slug, result.chapter.id, result.branchId)] = nil
                    if result.pageCount > 0 && result.pageCount == result.total {
                        self.appendChapter(
                            DownloadedChapter(id: result.chapter.id, volume: result.chapter.volume,
                                              number: result.chapter.number, name: result.chapter.name,
                                              pageCount: result.pageCount, branchId: result.branchId),
                            toSlug: slug
                        )
                        self.progress[slug]?.completed += 1
                    } else if result.pageCount > 0 {
                        try? self.fm.removeItem(at: self.chapterDir(slug, result.chapter.id, result.branchId))
                    }
                }
                await startNext()
            }
        }

        if Task.isCancelled { return } // приостановили (pause()) — pending остаётся для resume()

        // Если вообще ничего не скачалось — убираем пустую запись и помечаем сбой.
        if let idx = titles.firstIndex(where: { $0.slug == slug }), titles[idx].chapters.isEmpty {
            titles.remove(at: idx)
            try? fm.removeItem(at: titleDir(slug))
            save()
            progress[slug]?.failed = true
        }

        progress[slug]?.finished = true
        pending[slug] = nil
        save()

        // Убираем прогресс из UI через пару секунд после завершения.
        let s = slug
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); progress[s] = nil }
    }

    private func upsertTitle(_ entry: DownloadedTitle) {
        titles.removeAll { $0.slug == entry.slug }
        titles.insert(entry, at: 0)
        save()
    }

    private func appendChapter(_ chapter: DownloadedChapter, toSlug slug: String) {
        guard let idx = titles.firstIndex(where: { $0.slug == slug }) else { return }
        // Уникальность по (id главы, ветка) — одна глава может быть скачана в
        // разных переводах.
        if !titles[idx].chapters.contains(where: { $0.id == chapter.id && ($0.branchId ?? 0) == (chapter.branchId ?? 0) }) {
            titles[idx].chapters.append(chapter)
            save()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        // ВАЖНО: стратегия дат ДОЛЖНА совпадать с save() (.iso8601). Раньше
        // здесь был обычный JSONDecoder() (стратегия .deferredToDate — ждёт
        // число), а save() писал даты строкой ISO8601 — из-за рассинхрона
        // manifest НЕ декодировался после перезапуска, и все скачанные тайтлы
        // "пропадали" из вкладки Загрузки (файлы при этом оставались на диске).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([DownloadedTitle].self, from: data) {
            titles = decoded
        }
    }

    private func save() {
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(titles) {
            try? data.write(to: manifestURL)
        }
    }

    // MARK: Сеть/диск (nonisolated — вне главного потока)

    /// Отдельная сессия с обязательными заголовками (как в RemoteImageLoader —
    /// без User-Agent/Referer CDN отдаёт 403).
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            "User-Agent": MangaNetworkService.userAgent,
            "Referer": MangaNetworkService.referer,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        ]
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    /// Качает первый удавшийся URL из списка кандидатов (перебор серверов).
    nonisolated private static func fetchData(_ candidates: [URL]) async -> Data? {
        for url in candidates {
            do {
                let (data, resp) = try await session.data(from: url)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                if data.isEmpty { continue }
                return data
            } catch { continue }
        }
        return nil
    }

    /// Скачивает страницы одной главы (ветки branchId) в папку dir, возвращает
    /// число сохранённых. onProgress (0…1) — опционально, дёргается после
    /// каждой страницы; используется run() для зелёного кружка прогресса у
    /// главы, качающейся как часть "Скачать весь тайтл" (см. вызов в run()).
    nonisolated private static func downloadChapter(
        slug: String, chapter: ChapterItem, branchId: Int?, into dir: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> (saved: Int, total: Int) {
        guard let result = try? await MangaNetworkService.shared.fetchPages(
            slug: slug, volume: chapter.volume, number: chapter.number, branchId: branchId
        ) else { return (0, 0) }

        let total = result.pages.count
        var saved = 0
        for (idx, page) in result.pages.enumerated() {
            if Task.isCancelled { break }
            let candidates = MangaImageURL.pageURLs(for: page)
            if !candidates.isEmpty, let data = await fetchData(candidates) {
                let ext = (candidates.first?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "jpg"
                let file = dir.appendingPathComponent(String(format: "%03d.%@", idx, ext))
                try? data.write(to: file)
                saved += 1
            }
            if total > 0 { onProgress?(Double(idx + 1) / Double(total)) }
        }
        return (saved, total)
    }
}
