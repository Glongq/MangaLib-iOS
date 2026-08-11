import Foundation
import Combine

// MARK: - Модель скачанного

/// Одна скачанная глава: метаданные + число реально сохранённых страниц.
/// Файлы страниц лежат в <Documents>/Downloads/<slug>/<id>/000.jpg…
struct DownloadedChapter: Codable, Identifiable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let name: String?
    var pageCount: Int

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

        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
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

    private let fm = FileManager.default
    /// Активные задачи загрузки по slug — нужны, чтобы отменять скачивание.
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() { load() }

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

    /// Поставить ВСЕ переданные главы тайтла в очередь и начать загрузку.
    func download(slug: String, title: String, typeLabel: String?, coverURLString: String?, chapters: [ChapterItem]) {
        guard !chapters.isEmpty else { return }
        guard progress[slug]?.finished != false else { return } // уже качается

        progress[slug] = Progress(total: chapters.count, completed: 0, currentTitle: "", finished: false, failed: false)
        showBanner("Загрузка начата")
        let task = Task { [weak self] in
            await self?.run(slug: slug, title: title, typeLabel: typeLabel, coverURLString: coverURLString, chapters: chapters)
            self?.tasks[slug] = nil
        }
        tasks[slug] = task
    }

    /// Отменить активную загрузку (то же, что удалить — недокачанное
    /// выбрасывается). Отдельное имя ради читаемости на вызывающей стороне.
    func cancel(slug: String) { delete(slug: slug) }

    /// Удалить скачанный тайтл целиком (файлы + запись) и остановить загрузку,
    /// если она ещё идёт.
    func delete(slug: String) {
        tasks[slug]?.cancel()
        tasks[slug] = nil
        try? fm.removeItem(at: titleDir(slug))
        titles.removeAll { $0.slug == slug }
        progress[slug] = nil
        save()
    }

    /// Показать тост и убрать его через пару секунд (если его не сменил новый).
    private func showBanner(_ text: String) {
        let b = Banner(text: text)
        banner = b
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if banner?.id == b.id { banner = nil }
        }
    }

    // MARK: Процесс загрузки

    private func run(slug: String, title: String, typeLabel: String?, coverURLString: String?, chapters: [ChapterItem]) async {
        try? fm.createDirectory(at: titleDir(slug), withIntermediateDirectories: true)

        // Сразу заводим запись (с пустым списком глав) — чтобы тайтл появился в
        // разделе «Загрузки» с прогресс-баром ещё до конца скачивания.
        upsertTitle(DownloadedTitle(slug: slug, title: title, typeLabel: typeLabel,
                                    coverURLString: coverURLString, chapters: [], addedAt: Date()))

        // Обложка — для оффлайн-показа.
        if let coverURLString, let url = URL(string: coverURLString),
           let data = await Self.fetchData([url]) {
            try? data.write(to: titleDir(slug).appendingPathComponent("cover.jpg"))
        }

        for chapter in chapters {
            if Task.isCancelled { return } // отменили — cancel()/delete() уже всё убрал
            progress[slug]?.currentTitle = "Том \(chapter.volume) Глава \(chapter.number)"
            let dir = titleDir(slug).appendingPathComponent("\(chapter.id)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            let pageCount = await Self.downloadChapter(slug: slug, chapter: chapter, into: dir)
            if Task.isCancelled { return }
            if pageCount > 0 {
                appendChapter(
                    DownloadedChapter(id: chapter.id, volume: chapter.volume,
                                      number: chapter.number, name: chapter.name, pageCount: pageCount),
                    toSlug: slug
                )
            }
            progress[slug]?.completed += 1
        }

        if Task.isCancelled { return }

        // Если вообще ничего не скачалось — убираем пустую запись и помечаем сбой.
        if let idx = titles.firstIndex(where: { $0.slug == slug }), titles[idx].chapters.isEmpty {
            titles.remove(at: idx)
            try? fm.removeItem(at: titleDir(slug))
            save()
            progress[slug]?.failed = true
        }

        progress[slug]?.finished = true
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
        if !titles[idx].chapters.contains(where: { $0.id == chapter.id }) {
            titles[idx].chapters.append(chapter)
            save()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedTitle].self, from: data) else { return }
        titles = decoded
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

    /// Скачивает страницы одной главы в папку dir, возвращает число сохранённых.
    nonisolated private static func downloadChapter(slug: String, chapter: ChapterItem, into dir: URL) async -> Int {
        guard let result = try? await MangaNetworkService.shared.fetchPages(
            slug: slug, volume: chapter.volume, number: chapter.number, branchId: chapter.primaryBranchId
        ) else { return 0 }

        var saved = 0
        for (idx, page) in result.pages.enumerated() {
            if Task.isCancelled { break }
            let candidates = MangaImageURL.pageURLs(for: page)
            guard !candidates.isEmpty, let data = await fetchData(candidates) else { continue }
            let ext = (candidates.first?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "jpg"
            let file = dir.appendingPathComponent(String(format: "%03d.%@", idx, ext))
            try? data.write(to: file)
            saved += 1
        }
        return saved
    }
}
