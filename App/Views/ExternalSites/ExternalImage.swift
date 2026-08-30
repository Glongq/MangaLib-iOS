import SwiftUI

/// Мини-загрузчик картинок для внешних сайтов (hitomi.la и далее) — специально
/// НЕ RemoteImage (см. App/RemoteImage.swift): та шлёт заголовки
/// MangaNetworkService.userAgent/referer, рассчитанные на apicdnlibs.org —
/// у чужого CDN (gold-usergeneratedcontent.net) хотлинк-защита проверяет
/// Referer именно на hitomi.la, чужой Referer от MangaLib рискует словить
/// 403. По прямой просьбе — минимально пересекаться со старым сетевым кодом,
/// поэтому здесь свой, отдельный, совсем простой загрузчик (только
/// оперативный NSCache, без дискового кэша — картинки хитоми и так уже
/// закэшированы системным URLCache сессии на уровне HTTP).
private enum ExternalImageCache {
    static let shared = NSCache<NSURL, UIImage>()
}

@MainActor
private final class ExternalImageLoader: ObservableObject {
    @Published var image: UIImage?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://hitomi.la/"
        ]
        return URLSession(configuration: config)
    }()

    private var task: Task<Void, Never>?

    func load(_ url: URL) {
        if let cached = ExternalImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        task?.cancel()
        image = nil
        task = Task { [weak self] in
            guard let (data, _) = try? await Self.session.data(from: url),
                  let decoded = UIImage(data: data) else { return }
            ExternalImageCache.shared.setObject(decoded, forKey: url as NSURL)
            if !Task.isCancelled { self?.image = decoded }
        }
    }
}

/// Замена RemoteImage для картинок с внешних сайтов — тот же принцип
/// использования (url + placeholder), другая реализация под капотом.
struct ExternalImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder
    @StateObject private var loader = ExternalImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            loader.load(url)
        }
    }
}
