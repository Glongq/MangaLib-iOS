import SwiftUI
import UIKit

/// Кэш загруженных изображений в памяти.
final class RemoteImageCache {
    static let shared = RemoteImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
    /// Для "Очистить кеш изображений" в Данные и память (см. StorageSettingsView) —
    /// сбрасывает только оперативную часть, дисковую чистит отдельно
    /// RemoteImageLoader.clearDiskCache() (это два разных кэша).
    func removeAll() { cache.removeAllObjects() }
}

/// URLSessionDataDelegate одной загрузки — накапливает данные по мере
/// прихода чанков и репортит прогресс (byte count / Content-Length) через
/// onProgress. См. RemoteImageLoader.fetchDataWithProgress — держится живым
/// ассоциированным объектом на самом URLSessionTask (task.delegate — weak).
/// Колбэки Foundation вызывает на своей внутренней (фоновой) очереди —
/// onProgress сам решает, нужен ли переход на MainActor.
private final class ProgressDataTaskDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var expectedLength: Int64 = -1
    private var response: URLResponse?
    private let onProgress: @Sendable (Double) -> Void
    private let continuation: CheckedContinuation<(Data, URLResponse), Error>

    init(onProgress: @escaping @Sendable (Double) -> Void, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        self.response = response
        expectedLength = response.expectedContentLength
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        guard expectedLength > 0 else { return }
        onProgress(min(1, Double(buffer.count) / Double(expectedLength)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (buffer, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// Загрузчик изображений через URLSession с обязательными заголовками MangaLib
/// (User-Agent, Referer) — обычный AsyncImage их не отправляет и получает 403.
@MainActor
final class RemoteImageLoader: ObservableObject {

    enum State {
        case loading
        case success(UIImage)
        case failure
    }

    @Published private(set) var state: State = .loading
    private var task: Task<Void, Never>?

    /// Отдельная сессия с нужными заголовками для картинок (обложки и страницы).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": MangaNetworkService.userAgent,
            "Referer": MangaNetworkService.referer,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        ]
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    /// Дисковый кэш обложек/страниц (те же картинки, что грузит RemoteImage
    /// по всему приложению — карточки, обложки тайтла, страницы читалки, всё
    /// через один и тот же session.urlCache) — для "Кеш изображений" в
    /// Данные и память (см. StorageSettingsView.imageCacheBytes/clearImageCache).
    static var diskCache: URLCache? { session.configuration.urlCache }

    /// Полная очистка кэша картинок — и дисковой части (URLCache), и
    /// оперативной (RemoteImageCache, см. её removeAll() выше).
    static func clearImageCache() {
        diskCache?.removeAllCachedResponses()
        RemoteImageCache.shared.removeAll()
    }

    func load(_ url: URL?, priority: Float? = nil) {
        guard let url else { state = .failure; return }
        load(candidates: [url], priority: priority)
    }

    /// Декодирование UIImage(data:)/UIImage(contentsOfFile:) — это CPU-тяжёлая
    /// операция (JPEG/WebP/PNG-декод), а класс сам @MainActor — без явного
    /// ухода в фон она бы выполнялась прямо на главном потоке (там же, где
    /// скролл и layout SwiftUI), из-за чего картинки иногда "зависали" в
    /// загрузке на долгое время, хотя сеть уже давно всё скачала. Вынесено в
    /// nonisolated + Task.detached, чтобы это было гарантировано фоном
    /// независимо от того, откуда вызвано.
    nonisolated private static func decodeImage(data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
    }

    nonisolated private static func decodeImage(contentsOfFile path: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: path) }.value
    }

    /// Скачивание с опциональным приоритетом сетевого запроса
    /// (URLSessionTask.priority). `session.data(from:)` такого контроля не
    /// даёт — приоритет есть только у самого URLSessionTask, поэтому вместо
    /// него используется dataTask(with:) с continuation. nil — как раньше,
    /// сессия сама ставит стандартный приоритет (0.5), поведение не меняется.
    nonisolated private static func fetchData(from url: URL, priority: Float?) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            if let priority { task.priority = priority }
            task.resume()
        }
    }

    /// Ключ ассоциированного объекта для ProgressDataTaskDelegate ниже — см.
    /// fetchDataWithProgress.
    private static var progressDelegateAssocKey: UInt8 = 0

    /// То же самое, что fetchData(from:priority:), но с РЕАЛЬНЫМ прогрессом
    /// скачивания (0...1, по факту принятых байт / Content-Length) — для
    /// видимой страницы читалки, по прямой просьбе: "реальный прогресс
    /// прогрузки картинки вместо деф спинера". `session.dataTask(with:
    /// completionHandler:)` прогресса не даёт вообще; `URLSession.bytes(for:)`
    /// даёт, но итерирует ПОБАЙТНО — заметно медленнее на страницах манги
    /// (сотни КБ) — поэтому здесь свой `URLSessionDataDelegate`,
    /// накапливающий данные целыми чанками (`didReceive data:`), как обычный
    /// загрузчик файлов.
    ///
    /// `task.delegate` (доступно с iOS 15 — делегат НА КОНКРЕТНЫЙ таск, а не
    /// на всю session, той же shared `session` для переиспользования кэша/
    /// соединений) — WEAK свойство у Foundation, поэтому делегат сам по себе
    /// немедленно деаллоцировался бы сразу после этой функции — держим его
    /// живым ассоциированным объектом НА САМОМ таске (тот и так жив, пока
    /// задача не завершится), без отдельного глобального реестра/лока.
    nonisolated private static func fetchDataWithProgress(
        from url: URL, priority: Float?, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url)
            let delegate = ProgressDataTaskDelegate(onProgress: onProgress, continuation: continuation)
            objc_setAssociatedObject(task, &progressDelegateAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            task.delegate = delegate
            if let priority { task.priority = priority }
            task.resume()
        }
    }

    /// Пробует список URL по очереди (перебор серверов картинок), пока один не отдаст изображение.
    ///
    /// `priority` — URLSessionTask.priority (0...1). Нужен для обложки/фона
    /// карточки тайтла в MangaDetailView: если экран открыт сразу после ленты
    /// «Читают», в очереди URLSession ещё могут висеть незавершённые запросы
    /// её карточек — без явного приоритета все они конкурируют за канал
    /// наравне, и герой-картинка грузится не быстрее остальных.
    func load(candidates: [URL], priority: Float? = nil) {
        guard let key = candidates.first else { state = .failure; return }

        if let cached = RemoteImageCache.shared.image(for: key) {
            state = .success(cached)
            return
        }

        task?.cancel()
        state = .loading
        task = Task { [weak self] in
            for url in candidates {
                if Task.isCancelled { return }
                // Локальный файл скачанной страницы: URLSession не умеет file://,
                // читаем картинку прямо с диска.
                if url.isFileURL {
                    if let image = await Self.decodeImage(contentsOfFile: url.path) {
                        RemoteImageCache.shared.insert(image, for: key)
                        if !Task.isCancelled { self?.state = .success(image) }
                        return
                    }
                    continue
                }
                do {
                    let (data, response) = try await Self.fetchData(from: url, priority: priority)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        continue // сервер не отдал — пробуем следующий
                    }
                    guard let image = await Self.decodeImage(data: data) else { continue }
                    RemoteImageCache.shared.insert(image, for: key)
                    if !Task.isCancelled { self?.state = .success(image) }
                    return
                } catch {
                    continue
                }
            }
            if !Task.isCancelled { self?.state = .failure }
        }
    }

    /// Загрузка UIImage для UIKit-вьюх (нативный зум-скролл в читалке, см.
    /// ZoomableImageScrollView): тот же кэш, те же заголовки и та же поддержка
    /// локальных файлов (file://), что и у SwiftUI-варианта.
    ///
    /// `priority` — URLSessionTask.priority (см. fetchData выше). Страница,
    /// которую читатель видит ПРЯМО СЕЙЧАС (см. вызовы в MangaReaderView —
    /// оба режима читалки передают URLSessionTask.highPriority), должна
    /// реально обгонять в очереди сети те же несколько страниц, что молча
    /// качает preload() вперёд — раньше все они были равны по сетевому
    /// приоритету (preload отличался только Swift Task priority .utility,
    /// который на порядок очереди самой сети не влияет), из-за чего текущая
    /// страница могла ждать наравне с "про запас".
    ///
    /// `onProgress` — РЕАЛЬНЫЙ прогресс скачивания (0...1) видимой страницы,
    /// по прямой просьбе (вместо неопределённого спиннера, см.
    /// MangaReaderView.ZoomableImageScrollView/VerticalPageImage). nil по
    /// умолчанию — остальные вызовы (превью-загрузка/предзагрузка вперёд/
    /// аватар в AccountInfoView) прогресс не показывают, им не нужен лишний
    /// делегат на таск (см. fetchDataWithProgress).
    static func fetchImage(candidates: [URL], priority: Float? = nil, onProgress: (@Sendable (Double) -> Void)? = nil) async -> UIImage? {
        guard let key = candidates.first else { return nil }
        if let cached = RemoteImageCache.shared.image(for: key) { return cached }
        for url in candidates {
            if Task.isCancelled { return nil }
            if url.isFileURL {
                if let img = await decodeImage(contentsOfFile: url.path) {
                    RemoteImageCache.shared.insert(img, for: key)
                    return img
                }
                continue
            }
            do {
                let (data, response): (Data, URLResponse)
                if let onProgress {
                    (data, response) = try await fetchDataWithProgress(from: url, priority: priority, onProgress: onProgress)
                } else {
                    (data, response) = try await fetchData(from: url, priority: priority)
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                guard let img = await decodeImage(data: data) else { continue }
                RemoteImageCache.shared.insert(img, for: key)
                return img
            } catch { continue }
        }
        return nil
    }

    /// Тихая предзагрузка "про запас" — без создания View/State, просто качает
    /// картинку и кладёт её в тот же RemoteImageCache/URLCache, которым потом
    /// пользуется обычный RemoteImage. Нужна для настройки "Предзагрузка
    /// страниц" в ридере (см. ReaderSettingsSheet/"reader_preload_count") —
    /// когда пользователь долистает до страницы, она уже готова в кэше.
    /// Тот же паттерн Task{...} (не detached), что и в load(candidates:) выше:
    /// созданный в MainActor-контексте, он выполняется на MainActor между
    /// await-точками, так что доступ к static session ниже безопасен.
    static func preload(candidates: [URL]) {
        guard let key = candidates.first else { return }
        if RemoteImageCache.shared.image(for: key) != nil { return } // уже в кэше
        Task(priority: .utility) {
            for url in candidates {
                if Task.isCancelled { return }
                if url.isFileURL {
                    if let image = await decodeImage(contentsOfFile: url.path) {
                        RemoteImageCache.shared.insert(image, for: key)
                        return
                    }
                    continue
                }
                do {
                    let (data, response) = try await session.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        continue
                    }
                    guard let image = await decodeImage(data: data) else { continue }
                    RemoteImageCache.shared.insert(image, for: key)
                    return
                } catch {
                    continue
                }
            }
        }
    }
}

/// Замена AsyncImage: грузит картинку с нужными заголовками и кэшированием.
/// Использовать для обложек и страниц манги.
struct RemoteImage<Placeholder: View, Failure: View>: View {

    let url: URL?
    /// Кандидаты (несколько серверов) — перебираются при ошибке. Если nil, грузится `url`.
    private let candidates: [URL]?
    /// URLSessionTask.priority (0...1). nil по умолчанию — как раньше,
    /// стандартный приоритет сессии. См. RemoteImageLoader.load(candidates:priority:).
    private let priority: Float?
    private let content: (Image) -> AnyView
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    @StateObject private var loader = RemoteImageLoader()

    init(
        url: URL?,
        priority: Float? = nil,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.candidates = nil
        self.priority = priority
        self.content = { AnyView(content($0)) }
        self.placeholder = placeholder
        self.failure = failure
    }

    /// Вариант с несколькими URL-кандидатами (для страниц манги — перебор серверов).
    init(
        candidates: [URL],
        priority: Float? = nil,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = candidates.first
        self.candidates = candidates
        self.priority = priority
        self.content = { AnyView(content($0)) }
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                placeholder()
            case .success(let uiImage):
                content(Image(uiImage: uiImage))
            case .failure:
                failure()
            }
        }
        // .task(id:) вместо .onAppear+.onChange(of:) — надёжнее именно
        // внутри TabView(.page)/переходов (.navigationTransition(.zoom) и
        // т.п.): .onAppear там иногда СОВСЕМ не срабатывал (см. фидбек
        // "картинка через раз появляется" в CoverGalleryView — блюр-фон
        // грузится синхронно снимком, а сама картинка страницы иногда
        // просто не запускала загрузку). .task(id:) — гарантированный SwiftUI
        // API именно под "запустить асинхронную работу, привязанную к
        // значению", сам перезапускается при смене url и сам отменяется при
        // уходе view с экрана — не нужно вручную дублировать эту логику.
        .task(id: url) { loadCurrent() }
    }

    private func loadCurrent() {
        if let candidates { loader.load(candidates: candidates, priority: priority) }
        else { loader.load(url, priority: priority) }
    }
}

extension RemoteImage where Failure == AnyView {
    /// Упрощённый инициализатор: одинаковый placeholder для загрузки и ошибки.
    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            content: content,
            placeholder: placeholder,
            failure: { AnyView(placeholder()) }
        )
    }
}
