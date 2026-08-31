import SwiftUI

/// Мини-загрузчик картинок для внешних сайтов (hitomi.la и e-hentai.org) —
/// специально НЕ RemoteImage (см. App/RemoteImage.swift): та шлёт заголовки
/// MangaNetworkService.userAgent/referer, рассчитанные на apicdnlibs.org —
/// у чужих CDN хотлинк-защита проверяет СВОЙ Referer, чужой рискует словить
/// 403. По прямой просьбе — минимально пересекаться со старым сетевым кодом,
/// поэтому здесь свой, отдельный, совсем простой загрузчик (только
/// оперативный NSCache, без дискового кэша — картинки и так уже закэшированы
/// системным URLCache сессии на уровне HTTP).
private enum ExternalImageCache {
    static let shared = NSCache<NSURL, UIImage>()
}

/// Referer — ПО ХОСТУ конкретной картинки, не единый на весь загрузчик:
/// tn.gold-usergeneratedcontent.net (hitomi) хочет Referer hitomi.la, а
/// ehgt.org/*.hath.network (e-hentai — обложки/миниатюры и сами H@H-узлы)
/// хотят Referer e-hentai.org, ровно как у EHentaiProvider.session — раньше
/// здесь БЫЛ единый хардкод "hitomi.la", из-за чего e-hentai-картинки в этом
/// загрузчике (обложки в каталоге, превью-грид, Похожие тайтлы) рисковали
/// молча падать в 403 и никогда не подгружаться. `s*.3hentai.net`/`.xyz`
/// (3hentai) хотлинк-защиты вообще НЕ имеет (подтверждено живым curl —
/// 200 без Referer, 200 с ЛЮБЫМ чужим Referer тоже) — Referer тут ставится
/// не потому что без него сломается, а для единообразия с остальными двумя
/// сайтами (тот же принцип "честный per-хостовый Referer", не угадывание).
///
/// `m{N}.imhentai.xxx` (CDN картинок ImHentai — обложка/thumb.jpg, превью
/// {n}t.jpg, полноразмерные {n}.webp) — та же история повторилась ЕЩЁ РАЗ:
/// добавлен вместе с провайдером, но сюда забыли добавить ветку, из-за чего
/// молча падал в дефолт "hitomi.la" — ЧУЖОЙ Referer для этого CDN.
/// Обнаружено по жалобе (31.08): "обложки любые не грузятся... но при этом
/// 1 обложка загрузилась" — несогласованность объясняется тем, что CDN за
/// Cloudflare (см. ImhentaiProvider doc-comment), и промах кэша (см.
/// cf-cache-status в HAR) уходит на origin, который и проверяет Referer;
/// то единственное, что загрузилось, скорее всего уже лежало в edge-кэше
/// Cloudflare — тогда origin/Referer вообще не участвуют.
private func externalImageReferer(for url: URL) -> String {
    let host = url.host ?? ""
    if host.hasSuffix("e-hentai.org") || host.hasSuffix("ehgt.org") || host.hasSuffix("hath.network") {
        return "https://e-hentai.org/"
    }
    if host.hasSuffix("3hentai.net") || host.hasSuffix("3hentai.xyz") {
        return "https://ru.3hentai.net/"
    }
    if host.hasSuffix("imhentai.xxx") || host.hasSuffix("imhentai.com") {
        return "https://imhentai.xxx/"
    }
    return "https://hitomi.la/"
}

private let externalImageSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
    ]
    return URLSession(configuration: config)
}()

/// Один сетевой запрос картинки — общий для ExternalImageLoader/
/// ExternalSpriteLoader ниже (одинаковый Referer-по-хосту/кэш/сессия).
private func fetchExternalImage(_ url: URL) async -> UIImage? {
    if let cached = ExternalImageCache.shared.object(forKey: url as NSURL) { return cached }
    var request = URLRequest(url: url)
    request.setValue(externalImageReferer(for: url), forHTTPHeaderField: "Referer")
    guard let (data, _) = try? await externalImageSession.data(for: request),
          let decoded = UIImage(data: data) else { return nil }
    ExternalImageCache.shared.setObject(decoded, forKey: url as NSURL)
    return decoded
}

/// Реальная предзагрузка "про запас" для внешних сайтов — используется
/// читалкой (см. ExternalReaderView.preloadPage/preloadUpcoming/
/// preloadVerticalWindow). НЕ RemoteImageLoader.preload (то, что было
/// здесь раньше) — та качает через СВОЮ сессию с Referer от
/// MangaNetworkService.referer (текущий активный сайт MangaLib —
/// mangalib.me/etc), которая для tn.gold-usergeneratedcontent.net/ehgt.org/
/// *.hath.network просто НЕВЕРНАЯ (см. externalImageReferer выше) — CDN с
/// хотлинк-защитой на неё отвечает 404/403, предзагрузка молча ничего не
/// давала, картинки реально начинали грузиться только когда попадали в
/// кадр (жалоба "вижу стыки", 30.08). Настоящая читалка (ZoomableImageScroll
/// View/VerticalPageImage, см. MangaReaderView.swift — переиспользуются
/// НАПРЯМУЮ, не копируются) внутри себя дёргает именно
/// `RemoteImageLoader.fetchImage`, а та СНАЧАЛА проверяет
/// `RemoteImageCache.shared` (простой NSCache по URL, без привязки к
/// конкретной сессии/заголовкам) — поэтому вместо попытки подменить сессию
/// внутри чужого файла (не трогаем MangaReaderView.swift) сюда просто
/// заранее кладётся УЖЕ скачанная (нашей, правильной Referer-сессией)
/// картинка — RemoteImageLoader.fetchImage находит её в кэше и сеть больше
/// не трогает вовсе.
func preloadExternalImage(_ url: URL) async {
    guard RemoteImageCache.shared.image(for: url) == nil else { return }
    guard let image = await fetchExternalImage(url) else { return }
    RemoteImageCache.shared.insert(image, for: url)
}

@MainActor
private final class ExternalImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var task: Task<Void, Never>?

    func load(_ url: URL) {
        if let cached = ExternalImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        task?.cancel()
        image = nil
        task = Task { [weak self] in
            guard let decoded = await fetchExternalImage(url) else { return }
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

@MainActor
private final class ExternalSpriteLoader: ObservableObject {
    @Published var tile: UIImage?
    private var task: Task<Void, Never>?

    func load(url: URL, offsetX: Int, width: Int, height: Int) {
        task?.cancel()
        tile = nil
        guard width > 0, height > 0 else { return }
        task = Task { [weak self] in
            guard let sprite = await fetchExternalImage(url), let cg = sprite.cgImage else { return }
            let rect = CGRect(x: offsetX, y: 0, width: width, height: height)
            guard rect.maxX <= CGFloat(cg.width), rect.maxY <= CGFloat(cg.height),
                  let cropped = cg.cropping(to: rect) else { return }
            let result = UIImage(cgImage: cropped, scale: sprite.scale, orientation: sprite.imageOrientation)
            if !Task.isCancelled { self?.tile = result }
        }
    }
}

/// Миниатюра-"тайл", вырезанный из общего спрайта — у e-hentai полоса
/// миниатюр отдаёт НЕ отдельную картинку на страницу, а один общий спрайт
/// на партию страниц (~20, размер одного ?p=N-довеска) + CSS
/// `background-position`-смещение на каждую (подтверждено побайтово реальной
/// разметкой, см. EHentaiProvider.parsePages/ExternalGalleryPage.
/// thumbnailSpriteOffsetX). Сам спрайт грузится и кэшируется по `url` через
/// тот же ExternalImageCache, что и обычные картинки — несколько тайлов
/// ОДНОГО спрайта скачивают его реально только один раз, дальше просто
/// каждый вырезает свой кусок из уже закэшированного UIImage.
struct ExternalSpriteThumbnail<Placeholder: View>: View {
    let url: URL
    let offsetX: Int
    let tileWidth: Int
    let tileHeight: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @StateObject private var loader = ExternalSpriteLoader()

    var body: some View {
        Group {
            if let tile = loader.tile {
                Image(uiImage: tile).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            loader.load(url: url, offsetX: offsetX, width: tileWidth, height: tileHeight)
        }
    }
}
