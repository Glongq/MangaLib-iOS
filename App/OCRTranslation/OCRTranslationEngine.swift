import Translation
import UIKit

/// Stateless OCR -> Stage A -> Stage B orchestration, shared by the live
/// page path (PageTranslationController) and the preload path
/// (ExternalReaderView's preloadPage/preloadVerticalWindow extension) so
/// the pipeline and its caching are never duplicated.
enum OCRTranslationEngine {

    static func process(
        image: UIImage,
        cacheKey: OCRCacheKey,
        session: TranslationSession,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String,
        onStageAReady: @escaping (CachedPageTranslation) -> Void,
        onStageBReady: @escaping (CachedPageTranslation) -> Void
    ) async {
        if let cached = OCRTranslationMemoryCache.shared[cacheKey] {
            onStageAReady(cached)
            // The cache key doesn't encode "Stage B was on" — a page can
            // be cached from an earlier run where Stage B was off or
            // failed. Re-attempt it now if it's enabled and wasn't
            // already done, instead of silently sticking with Stage-A
            // text forever.
            await runStageB(cached, cacheKey: cacheKey, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, onStageBReady: onStageBReady)
            return
        }
        if let cached = await OCRTranslationDiskCache.shared.load(cacheKey) {
            OCRTranslationMemoryCache.shared[cacheKey] = cached
            onStageAReady(cached)
            await runStageB(cached, cacheKey: cacheKey, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, onStageBReady: onStageBReady)
            return
        }

        let blocks = await OCRTextRecognizer.recognize(image: image, sourceLanguage: cacheKey.sourceLanguage)
        guard !blocks.isEmpty else { return }
        guard let stageA = try? await TranslationPipeline.translateBatch(blocks, session: session), !stageA.isEmpty else { return }

        let result = CachedPageTranslation(
            blocks: blocks,
            stageAText: Dictionary(uniqueKeysWithValues: stageA.map { ($0.key.uuidString, $0.value) }),
            stageBText: [:]
        )
        OCRTranslationMemoryCache.shared[cacheKey] = result
        await OCRTranslationDiskCache.shared.save(cacheKey, result)
        onStageAReady(result)

        await runStageB(result, cacheKey: cacheKey, stageBEnabled: stageBEnabled, rephraseClient: rephraseClient, targetLanguageName: targetLanguageName, onStageBReady: onStageBReady)
    }

    /// Attempts Stage B on top of an already-known Stage-A result (fresh
    /// or from cache) — a no-op if it already succeeded, is disabled, or
    /// isn't configured.
    private static func runStageB(
        _ cached: CachedPageTranslation,
        cacheKey: OCRCacheKey,
        stageBEnabled: Bool,
        rephraseClient: RephraseClient?,
        targetLanguageName: String,
        onStageBReady: @escaping (CachedPageTranslation) -> Void
    ) async {
        guard !cached.stageBText.isEmpty else {
            guard stageBEnabled, let rephraseClient else { return }
            let orderedLines = cached.blocks.map { cached.stageAText[$0.id.uuidString] ?? "" }
            guard let stageB = try? await rephraseClient.rephrase(lines: orderedLines, targetLanguageName: targetLanguageName) else { return }

            var updated = cached
            for (block, text) in zip(cached.blocks, stageB) {
                updated.stageBText[block.id.uuidString] = text
            }
            OCRTranslationMemoryCache.shared[cacheKey] = updated
            await OCRTranslationDiskCache.shared.save(cacheKey, updated)
            onStageBReady(updated)
            return
        }
        onStageBReady(cached)
    }
}
