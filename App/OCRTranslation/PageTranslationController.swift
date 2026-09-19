import Translation
import UIKit

/// Per-page controller — one `@StateObject` instance per page wrapper
/// (ExternalHorizontalPageImage/ExternalVerticalPageImage), so its
/// lifecycle matches the page view: created when the page appears,
/// cancelled/deallocated when SwiftUI recycles it.
///
/// OCR/Stage-A loading (loadPage, via load(image:...)/load(imageURL:...))
/// and Stage-B toggling (setStageBEnabled) are DELIBERATELY independent:
/// flipping the Stage-B setting must never re-run OCR/Stage-A or blank
/// what's already on screen — it always shows Stage-A immediately, then
/// silently upgrades to Stage B once/if that finishes, and instantly
/// reverts to Stage-A (no network wait — it's already cached) the moment
/// Stage B gets turned back off.
final class PageTranslationController: ObservableObject {
    @Published private(set) var blocks: [RecognizedTextBlock] = []
    @Published private(set) var displayText: [UUID: String] = [:]

    var style: OCROverlayStyle = .backdropPlate {
        didSet { renderOverlay() }
    }
    /// Opt-in (see ExternalTranslationSettingsSheet's "Стирать оригинальный
    /// текст"): fills each block with its sampled background color instead
    /// of the fixed plate color, approximating erasing the original text.
    /// Best-effort — see OCRBackgroundSampler's doc-comment.
    var eraseOriginalText: Bool = false {
        didSet { renderOverlay() }
    }

    private var task: Task<Void, Never>?
    private var stageBTask: Task<Void, Never>?
    private var currentCacheKey: OCRCacheKey?
    private var currentResult: CachedPageTranslation?

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
    /// `stageBEnabled`/`rephraseClient` here are just the INITIAL
    /// preference for this page load (e.g. it was already on when the
    /// page first appeared) — ongoing toggling goes through
    /// `setStageBEnabled`, not this.
    func load(
        image: UIImage,
        cacheKey: OCRCacheKey,
        runtime: PageTranslationRuntime,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String,
        promptTemplate: String
    ) {
        loadPage(cacheKey: cacheKey, runtime: runtime, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, promptTemplate: promptTemplate) {
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
        targetLanguageName: String,
        promptTemplate: String
    ) {
        loadPage(cacheKey: cacheKey, runtime: runtime, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, promptTemplate: promptTemplate) {
            if let cached = RemoteImageCache.shared.image(for: imageURL) { return cached }
            return await RemoteImageLoader.fetchImage(candidates: [imageURL])
        }
    }

    private func loadPage(
        cacheKey: OCRCacheKey,
        runtime: PageTranslationRuntime,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String,
        promptTemplate: String,
        image: @escaping () async -> UIImage?
    ) {
        // Already loaded/loading this exact page — a settings change that
        // doesn't affect OCR/Stage-A (e.g. Stage-B toggling, which comes
        // through setStageBEnabled instead) must NOT retrigger this.
        guard currentCacheKey != cacheKey else { return }
        currentCacheKey = cacheKey
        currentResult = nil
        task?.cancel()
        stageBTask?.cancel()
        blocks = []
        displayText = [:]
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
            guard let result = await OCRTranslationEngine.processStageA(image: image, cacheKey: cacheKey, session: session) else { return }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.currentCacheKey == cacheKey else { return }
                self.handle(result, cacheKey: cacheKey, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, promptTemplate: promptTemplate)
            }
        }
    }

    /// Reactively called when the Stage-B setting (or its engine/URL/key
    /// config) changes, for whichever page is CURRENTLY loaded in this
    /// controller — never touches OCR/Stage-A. Turning it off instantly
    /// falls back to the already-cached Stage-A text (no network wait);
    /// turning it on shows Stage-A immediately and kicks off Stage B in
    /// the background, upgrading in place once/if it succeeds.
    func setStageBEnabled(_ enabled: Bool, rephraseClient: RephraseClient?, targetLanguageName: String, promptTemplate: String) {
        guard let result = currentResult, let cacheKey = currentCacheKey else { return }
        handle(result, cacheKey: cacheKey, stageBEnabled: enabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, promptTemplate: promptTemplate)
    }

    /// Shared by both loadPage's completion and setStageBEnabled: shows
    /// the current best text for `stageBEnabled`'s preference, and — only
    /// if enabled, configured, and not already done — kicks off Stage B.
    private func handle(
        _ result: CachedPageTranslation,
        cacheKey: OCRCacheKey,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String,
        promptTemplate: String
    ) {
        stageBTask?.cancel()
        currentResult = result
        blocks = result.blocks
        updateDisplay(from: result, preferStageB: stageBEnabled)

        guard stageBEnabled, let rephraseClient, result.stageBText.isEmpty || result.stageBPrompt != promptTemplate else { return }
        stageBTask = Task { [weak self] in
            guard let updated = await OCRTranslationEngine.attemptStageB(result, cacheKey: cacheKey, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, promptTemplate: promptTemplate) else { return }
            if Task.isCancelled { return }
            await MainActor.run {
                // The user may have navigated away (currentCacheKey
                // changed) or turned Stage B back off while this was in
                // flight — don't stomp on whatever's showing now.
                guard let self, self.currentCacheKey == cacheKey else { return }
                self.currentResult = updated
                self.updateDisplay(from: updated, preferStageB: stageBEnabled)
            }
        }
    }

    private func updateDisplay(from result: CachedPageTranslation, preferStageB: Bool) {
        var text: [UUID: String] = [:]
        for block in result.blocks {
            let key = block.id.uuidString
            let value = preferStageB ? (result.stageBText[key] ?? result.stageAText[key]) : result.stageAText[key]
            if let value { text[block.id] = value }
        }
        displayText = text
        renderOverlay()
    }

    /// Cancels any in-flight work and clears the overlay — called when
    /// translation gets turned off entirely (or a page fails to resolve)
    /// so a stale translation doesn't linger on screen.
    func clear() {
        task?.cancel()
        stageBTask?.cancel()
        currentCacheKey = nil
        currentResult = nil
        blocks = []
        displayText = [:]
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
        overlayView.render(blocks: blocks, texts: displayText, style: style, eraseOriginalText: eraseOriginalText)
    }

    deinit {
        task?.cancel()
        stageBTask?.cancel()
        overlayView.removeFromSuperview()
    }
}
