import SwiftUI
import UIKit

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

    func load(_ url: URL?) {
        guard let url else { state = .failure; return }
        load(candidates: [url])
    }

    /// Пробует список URL по очереди (перебор серверов картинок), пока один не отдаст изображение.
    func load(candidates: [URL]) {
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
                    if let image = UIImage(contentsOfFile: url.path) {
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
                    guard let image = UIImage(data: data) else { continue }
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
                if let img = UIImage(contentsOfFile: url.path) {
                    RemoteImageCache.shared.insert(img, for: key)
                    return img
                }
                continue
            }
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { continue }
                guard let img = UIImage(data: data) else { continue }
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
                    if let image = UIImage(contentsOfFile: url.path) {
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
                    guard let image = UIImage(data: data) else { continue }
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
    private let content: (Image) -> AnyView
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    @StateObject private var loader = RemoteImageLoader()

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.candidates = nil
        self.content = { AnyView(content($0)) }
        self.placeholder = placeholder
        self.failure = failure
    }

    /// Вариант с несколькими URL-кандидатами (для страниц манги — перебор серверов).
    init(
        candidates: [URL],
        @ViewBuilder content: @escaping (Image) -> some View,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = candidates.first
        self.candidates = candidates
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
        if let candidates { loader.load(candidates: candidates) }
        else { loader.load(url) }
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
