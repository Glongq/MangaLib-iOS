import CoreGraphics
import Foundation

/// One OCR line, already converted to top-left-origin normalized
/// coordinates (Vision itself reports bottom-left-origin) — see
/// OCRTextRecognizer.
struct RecognizedTextLine: Codable, Hashable {
    let text: String
    /// Normalized (0...1), top-left origin, relative to the page image.
    let rect: CGRect
    let confidence: Float
}

/// A cluster of OCR lines grouped into a single speech-bubble-sized block
/// (see OCRTextRecognizer's clustering pass) — the unit the translation
/// pipeline and the overlay both operate on.
struct RecognizedTextBlock: Codable, Identifiable, Hashable {
    let id: UUID
    /// Normalized (0...1), top-left origin — union of all line rects.
    let rect: CGRect
    /// Lines joined top-to-bottom with "\n".
    let text: String
    let lines: [RecognizedTextLine]

    /// Rough character budget the translated text should aim for,
    /// estimated from this block's actual pixel footprint in the source
    /// image (`imageSize` — see CachedPageTranslation.imageSize) using the
    /// same font-size heuristic as the on-screen overlay (OCROverlayFit).
    /// A SOFT target for Stage-B's rephrase prompt, not a hard limit —
    /// the prompt is explicit that meaning must never be cut to fit it.
    func characterBudget(imageSize: CGSize) -> Int {
        guard imageSize.width > 0, imageSize.height > 0 else { return max(text.count, 8) }
        let pixelWidth = rect.width * imageSize.width
        let pixelHeight = rect.height * imageSize.height
        let estimatedFontSize = max(8, pixelHeight * 0.35)
        let avgCharWidth = estimatedFontSize * 0.55
        let charsPerLine = max(1, pixelWidth / avgCharWidth)
        let lineHeight = estimatedFontSize * 1.2
        let numLines = max(1, (pixelHeight * OCROverlayFit.maxHeightMultiplier) / lineHeight)
        return max(4, Int((charsPerLine * numLines).rounded()))
    }
}
