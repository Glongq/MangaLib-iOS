import Translation
import UIKit

/// Per-page controller — one `@StateObject` instance per page wrapper
/// (ExternalHorizontalPageImage/ExternalVerticalPageImage), so its
/// lifecycle matches the page view: created when the page appears,
/// cancelled/deallocated when SwiftUI recycles it. Drives OCR ->
/// Stage A -> Stage B for that one page and publishes the result for
/// both the UIKit overlay (attach(to:)) and the SwiftUI overlay
/// (blocks/displayText).
final class PageTranslationController: ObservableObject {
    @Published private(set) var blocks: [RecognizedTextBlock] = []
    @Published private(set) var displayText: [UUID: String] = [:]

    var style: OCROverlayStyle = .backdropPlate {
        didSet { renderOverlay() }
    }

    private var task: Task<Void, Never>?
    /// Owned for this controller's entire lifetime (NOT looked up by
    /// searching `imageView.subviews` for "whatever overlay happens to be
    /// there" — that assumed the imageView is never shared/reused across
    /// pages, which isn't a safe assumption to make about a UIKit view
    /// wrapped by SwiftUI. Owning it here and explicitly moving it between
    /// imageViews means this controller can never end up rendering into,
    /// or reading stale content left behind by, a DIFFERENT page's
    /// controller.
    private let overlayView = OCROverlayContainerView()
    private weak var attachedImageView: UIImageView?

    init() {
        overlayView.isUserInteractionEnabled = false
    }

    /// Vertical/SwiftUI mode — image already decoded by VerticalPageImage.
    func load(
        image: UIImage,
        cacheKey: OCRCacheKey,
        runtime: PageTranslationRuntime,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String
    ) {
        run(cacheKey: cacheKey, runtime: runtime, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName) {
            image
        }
    }

    /// Horizontal/UIKit mode — ZoomableImageScrollView decodes the image
    /// itself; we read it back from the shared cache (or fetch it) rather
    /// than duplicating that decode.
    func load(
        imageURL: URL,
        cacheKey: OCRCacheKey,
        runtime: PageTranslationRuntime,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String
    ) {
        run(cacheKey: cacheKey, runtime: runtime, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName) {
            if let cached = RemoteImageCache.shared.image(for: imageURL) { return cached }
            return await RemoteImageLoader.fetchImage(candidates: [imageURL])
        }
    }

    private func run(
        cacheKey: OCRCacheKey,
        runtime: PageTranslationRuntime,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String,
        image: @escaping () async -> UIImage?
    ) {
        task?.cancel()
        blocks = []
        displayText = [:]
        // Wipe any stale overlay content IMMEDIATELY — previously this
        // only happened once the next attach()/apply() fired, so a
        // just-recycled UIImageView (see attach(to:)'s doc-comment) could
        // keep showing the PREVIOUS page's translated text on screen for
        // a while after a new page/image had already started loading.
        renderOverlay()
        task = Task { [weak self] in
            // The session is created asynchronously by
            // PageTranslationSessionHost's .translationTask — it's
            // frequently not ready yet the instant a page's own task
            // starts, so this waits (bounded) rather than silently giving
            // up on that page forever.
            guard let session = await runtime.waitForSession() else { return }
            if Task.isCancelled { return }
            guard let image = await image() else { return }
            if Task.isCancelled { return }
            await OCRTranslationEngine.process(
                image: image, cacheKey: cacheKey, session: session,
                stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName,
                onStageAReady: { result in Task { await MainActor.run { self?.apply(result) } } },
                onStageBReady: { result in Task { await MainActor.run { self?.apply(result) } } }
            )
        }
    }

    /// Cancels any in-flight work and clears the overlay — called when
    /// translation gets turned off (or a page fails to resolve) so a
    /// stale translation doesn't linger on screen.
    func clear() {
        task?.cancel()
        blocks = []
        displayText = [:]
        renderOverlay()
    }

    private func apply(_ result: CachedPageTranslation) {
        blocks = result.blocks
        var text: [UUID: String] = [:]
        for block in result.blocks {
            if let value = result.text(for: block.id) { text[block.id] = value }
        }
        displayText = text
        renderOverlay()
    }

    /// Called from ZoomableImageScrollView.Coordinator.layoutImage (via the
    /// onImageViewReady hook) whenever the base image/frame changes —
    /// (re)parents THIS controller's own overlay view under imageView, so
    /// UIScrollView's zoom transform scales it for free. Moves it rather
    /// than re-adding it if imageView hasn't actually changed.
    func attach(to imageView: UIImageView) {
        if attachedImageView !== imageView {
            overlayView.removeFromSuperview()
            imageView.addSubview(overlayView)
            attachedImageView = imageView
        }
        overlayView.frame = imageView.bounds
        renderOverlay()
    }

    private func renderOverlay() {
        overlayView.render(blocks: blocks, texts: displayText, style: style)
    }

    deinit {
        task?.cancel()
        overlayView.removeFromSuperview()
    }
}
