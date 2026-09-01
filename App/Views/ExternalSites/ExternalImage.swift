import SwiftUI

/// Mini image loader for external sites (hitomi.la and e-hentai.org) —
/// deliberately NOT RemoteImage (see App/RemoteImage.swift): that one sends
/// MangaNetworkService.userAgent/referer headers, tuned for apicdnlibs.org —
/// third-party CDNs' hotlink protection checks its OWN Referer, and a
/// foreign one risks getting a 403. Per a direct request to minimally
/// overlap with the old networking code, this has its own separate, very
/// simple loader (just an in-memory NSCache, no disk cache — images are
/// already cached at the HTTP level by the session's system URLCache).
private enum ExternalImageCache {
    static let shared = NSCache<NSURL, UIImage>()
}

/// Referer — PER-HOST for the specific image, not one single value for the
/// whole loader: tn.gold-usergeneratedcontent.net (hitomi) wants a Referer
/// of hitomi.la, while ehgt.org/*.hath.network (e-hentai — covers/thumbnails
/// and the H@H nodes themselves) want a Referer of e-hentai.org, exactly
/// like EHentaiProvider.session — this used to be a single hardcoded
/// "hitomi.la", which meant e-hentai images in this loader (catalog covers,
/// the preview grid, Similar titles) risked silently falling into a 403 and
/// never loading. `s*.3hentai.net`/`.xyz` (3hentai) has NO hotlink
/// protection at all (confirmed by a live curl — 200 with no Referer, 200
/// with ANY foreign Referer too) — the Referer is set here not because it
/// would break without it, but for consistency with the other two sites
/// (the same "honest per-host Referer" principle, not a guess).
///
/// `m{N}.imhentai.xxx` (ImHentai's image CDN — cover/thumb.jpg, previews
/// {n}t.jpg, full-size {n}.webp) — the same story repeated ONCE AGAIN: it
/// was added along with the provider, but the branch here was forgotten,
/// so it silently fell into the "hitomi.la" default — a FOREIGN Referer for
/// this CDN. Found from a complaint (08/31): "no covers load at all... but
/// still 1 cover loaded" — the inconsistency is explained by the CDN sitting
/// behind Cloudflare (see the ImhentaiProvider doc-comment), and a cache
/// miss (see cf-cache-status in the HAR) goes to the origin, which is what
/// checks the Referer; the one thing that did load was most likely already
/// sitting in Cloudflare's edge cache — in which case the origin/Referer
/// never come into play at all.
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
    // b{N}.hentaipill.{com,me,...} — HentaiPill's image CDN. Has no hotlink
    // protection (confirmed by a live curl — 200 with no Referer, 200 with
    // ANY foreign Referer too, exactly like 3hentai), but the branch was
    // added right away — the same lesson as with imhentai above (a forgotten
    // branch silently falling into the default).
    if host.hasSuffix("hentaipill.com") || host.hasSuffix("hentaipill.me") {
        return "https://hentaipill.com/"
    }
    // images.sh-cdn.com — Simply Hentai's image CDN, confirmed by HAR
    // (a real browser sends exactly this Referer).
    if host.hasSuffix("sh-cdn.com") {
        return "https://www.simply-hentai.com/"
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

/// A single network request for an image — shared by ExternalImageLoader/
/// ExternalSpriteLoader below (same per-host Referer/cache/session).
private func fetchExternalImage(_ url: URL) async -> UIImage? {
    if let cached = ExternalImageCache.shared.object(forKey: url as NSURL) { return cached }
    var request = URLRequest(url: url)
    request.setValue(externalImageReferer(for: url), forHTTPHeaderField: "Referer")
    guard let (data, _) = try? await externalImageSession.data(for: request),
          let decoded = UIImage(data: data) else { return nil }
    ExternalImageCache.shared.setObject(decoded, forKey: url as NSURL)
    return decoded
}

/// Real "just in case" preloading for external sites — used by the reader
/// (see ExternalReaderView.preloadPage/preloadUpcoming/
/// preloadVerticalWindow). NOT RemoteImageLoader.preload (what used to be
/// here) — that one downloads through ITS OWN session with a Referer from
/// MangaNetworkService.referer (the currently active MangaLib site —
/// mangalib.me/etc), which is simply WRONG for
/// tn.gold-usergeneratedcontent.net/ehgt.org/*.hath.network (see
/// externalImageReferer above) — a CDN with hotlink protection responds
/// with 404/403 to it, so preloading silently accomplished nothing, and
/// images only actually started loading once they entered the viewport
/// (complaint "I see seams", 08/30). The actual reader (ZoomableImageScroll
/// View/VerticalPageImage, see MangaReaderView.swift — reused DIRECTLY, not
/// copied) internally calls exactly `RemoteImageLoader.fetchImage`, which
/// FIRST checks `RemoteImageCache.shared` (a plain NSCache keyed by URL,
/// not tied to any particular session/headers) — so instead of trying to
/// swap out the session inside someone else's file (we don't touch
/// MangaReaderView.swift), this simply places the ALREADY downloaded image
/// (via our own, correct Referer session) here ahead of time —
/// RemoteImageLoader.fetchImage finds it in the cache and never touches the
/// network at all.
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

/// A replacement for RemoteImage for external-site images — the same usage
/// pattern (url + placeholder), a different implementation underneath.
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

/// A thumbnail "tile" cut out from a shared sprite — e-hentai's thumbnail
/// strip doesn't return a separate image per page, but one shared sprite
/// per batch of pages (~20, the size of one `?p=N` chunk) + a CSS
/// `background-position` offset for each (confirmed byte-for-byte against
/// the real markup, see EHentaiProvider.parsePages/ExternalGalleryPage.
/// thumbnailSpriteOffsetX). The sprite itself is loaded and cached by `url`
/// through the same ExternalImageCache as regular images — several tiles
/// from ONE sprite only actually download it once, after that each one
/// just crops its own piece out of the already-cached UIImage.
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
