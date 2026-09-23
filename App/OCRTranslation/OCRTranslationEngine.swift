import UIKit

/// OCR -> Stage A -> Stage B, split into two independent, composable
/// steps (NOT one monolithic pipeline) — Stage B needs to be toggled on
/// and off without ever re-running OCR/Stage-A or blanking whatever's
/// already showing (see PageTranslationController, which owns the
/// reactive wiring between the two).
enum OCRTranslationEngine {

    /// OCR + Stage A only — checks both cache tiers first. Used by the
    /// live page path (PageTranslationController.loadPage).
    static func processStageA(image: UIImage, cacheKey: OCRCacheKey, runtime: PageTranslationRuntime) async -> CachedPageTranslation? {
        if let cached = OCRTranslationMemoryCache.shared[cacheKey] { return cached }
        if let cached = await OCRTranslationDiskCache.shared.load(cacheKey) {
            OCRTranslationMemoryCache.shared[cacheKey] = cached
            return cached
        }

        var blocks = await OCRTextRecognizer.recognize(image: image, sourceLanguage: cacheKey.sourceLanguage)
        guard !blocks.isEmpty else { return nil }
        // Always computed (cheap — small cropped regions, not the whole
        // page) so the optional "erase original text" overlay style can
        // use it later without a separate cache/recompute path — see
        // RecognizedTextBlock.backgroundColor's doc-comment.
        for index in blocks.indices {
            blocks[index].backgroundColor = OCRBackgroundSampler.sample(rect: blocks[index].rect, in: image)
        }
        guard let stageA = await runtime.translate(blocks, targetLanguage: cacheKey.targetLanguage), !stageA.isEmpty else { return nil }

        let result = CachedPageTranslation(
            blocks: blocks,
            stageAText: Dictionary(uniqueKeysWithValues: stageA.map { ($0.key.uuidString, $0.value) }),
            stageBText: [:],
            imageSize: image.size
        )
        OCRTranslationMemoryCache.shared[cacheKey] = result
        await OCRTranslationDiskCache.shared.save(cacheKey, result)
        return result
    }

    /// Attempts Stage B on top of an already-known Stage-A result (fresh
    /// or from cache) — returns it unchanged if Stage B already succeeded
    /// for it WITH THIS SAME PROMPT, or nil if the attempt fails (network/
    /// timeout/malformed reply/wrong count); callers must keep showing
    /// Stage-A text on nil, no error UI (per product decision). A prompt
    /// that differs from `result.stageBPrompt` is treated the same as
    /// "not done yet" — otherwise editing the custom prompt in Settings
    /// would never affect a page that already has SOME cached Stage-B
    /// text, no matter how old/different that prompt was.
    ///
    /// English sources get a fresh DIRECT English->target translation
    /// from the LLM (reads more natural than rephrasing an already-
    /// literal Apple-translated pass); every other source language gets
    /// Stage-A's text rephrased. Either way Stage A has ALWAYS already
    /// been shown first — this only ever runs as a later, separate
    /// upgrade (see PageTranslationController.setStageBEnabled).
    static func attemptStageB(
        _ result: CachedPageTranslation,
        cacheKey: OCRCacheKey,
        rephraseClient: RephraseClient,
        targetLanguageName: String,
        promptTemplate: String
    ) async -> CachedPageTranslation? {
        guard result.stageBText.isEmpty || result.stageBPrompt != promptTemplate else { return result }

        let useDirectTranslation = cacheKey.sourceLanguage == "en"
        let orderedLines = result.blocks.map { block -> RephraseLineInput in
            let sourceText = useDirectTranslation ? block.text : (result.stageAText[block.id.uuidString] ?? "")
            return RephraseLineInput(text: sourceText, characterBudget: block.characterBudget(imageSize: result.imageSize))
        }

        let translated = try? await rephraseClient.translate(lines: orderedLines, targetLanguageName: targetLanguageName, promptTemplate: promptTemplate)
        guard let translated, translated.count == result.blocks.count else { return nil }

        var updated = result
        for (block, text) in zip(result.blocks, translated) {
            updated.stageBText[block.id.uuidString] = text
        }
        updated.stageBPrompt = promptTemplate
        OCRTranslationMemoryCache.shared[cacheKey] = updated
        await OCRTranslationDiskCache.shared.save(cacheKey, updated)
        return updated
    }
}
