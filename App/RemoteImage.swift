import SwiftUI
import UIKit
import ImageIO

/// Кэш загруженных изображений в памяти.
final class RemoteImageCache {
    static let shared = RemoteImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
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

    func load(_ url: URL?, maxPixelSize: CGFloat? = nil) {
        guard let url else { state = .failure; return }
        load(candidates: [url], maxPixelSize: maxPixelSize)
    }

    /// Декодирование UIImage(data:)/UIImage(contentsOfFile:) — это CPU-тяжёлая
    /// операция (JPEG/WebP/PNG-декод), а класс сам @MainActor — без явного
    /// ухода в фон она бы выполнялась прямо на главном потоке (там же, где
    /// скролл и layout SwiftUI), из-за чего картинки иногда "зависали" в
    /// загрузке на долгое время, хотя сеть уже давно всё скачала. Вынесено в
    /// nonisolated + Task.detached, чтобы это было гарантировано фоном
    /// независимо от того, откуда вызвано.
    ///
    /// `maxPixelSize` — nil (по умолчанию, как раньше) декодирует картинку
    /// целиком в исходном разрешении. Если передан — вместо полного декода
    /// используется ImageIO-миниатюра (CGImageSourceCreateThumbnailAtIndex):
    /// она не держит в памяти полноразмерный CGImage перед сжатием, а сразу
    /// декодирует уменьшенную версию — для мелких превью (аватарки и т.п.,
    /// у которых на сервере нет отдельного маленького файла, в отличие от
    /// обложек тайтлов с их thumbnail) это заметно дешевле по памяти/CPU,
    /// чем декодировать оригинал и сжимать его уже на экране.
    nonisolated private static func decodeImage(data: Data, maxPixelSize: CGFloat?) async -> UIImage? {
        guard let maxPixelSize else {
            return await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
        }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return UIImage(data: data) // запасной путь, если ImageIO не справился
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    nonisolated private static func decodeImage(contentsOfFile path: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: path) }.value
    }

    /// Пробует список URL по очереди (перебор серверов картинок), пока один не отдаст изображение.
    func load(candidates: [URL], maxPixelSize: CGFloat? = nil) {
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
                    let (data, response) = try await Self.session.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        continue // сервер не отдал — пробуем следующий
                    }
                    guard let image = await Self.decodeImage(data: data, maxPixelSize: maxPixelSize) else { continue }
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
    static func fetchImage(candidates: [URL]) async -> UIImage? {
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
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                guard let img = await decodeImage(data: data, maxPixelSize: nil) else { continue }
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
                    guard let image = await decodeImage(data: data, maxPixelSize: nil) else { continue }
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
    /// nil (по умолчанию) — как раньше, полноразмерный декод. Передаётся для
    /// мелких превью без серверного thumbnail (см. RemoteImageLoader.decodeImage).
    private let maxPixelSize: CGFloat?
    private let content: (Image) -> AnyView
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    @StateObject private var loader = RemoteImageLoader()

    init(
        url: URL?,
        maxPixelSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.candidates = nil
        self.maxPixelSize = maxPixelSize
        self.content = { AnyView(content($0)) }
        self.placeholder = placeholder
        self.failure = failure
    }

    /// Вариант с несколькими URL-кандидатами (для страниц манги — перебор серверов).
    init(
        candidates: [URL],
        maxPixelSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = candidates.first
        self.candidates = candidates
        self.maxPixelSize = maxPixelSize
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
        .onAppear { loadCurrent() }
        .onChange(of: url) { _, _ in loadCurrent() }
    }

    private func loadCurrent() {
        if let candidates { loader.load(candidates: candidates, maxPixelSize: maxPixelSize) }
        else { loader.load(url, maxPixelSize: maxPixelSize) }
    }
}

extension RemoteImage where Failure == AnyView {
    /// Упрощённый инициализатор: одинаковый placeholder для загрузки и ошибки.
    init(
        url: URL?,
        maxPixelSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            maxPixelSize: maxPixelSize,
            content: content,
            placeholder: placeholder,
            failure: { AnyView(placeholder()) }
        )
    }
}
