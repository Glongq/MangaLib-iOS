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

/// A crude estimate of the page background right around a text block —
/// see OCRBackgroundSampler. Stored as plain components (not UIColor,
/// which isn't cleanly Codable) so it survives the disk cache. Always
/// computed (cheap — a small cropped region, not the whole page), used
/// only when the user opts into "erase original text" — see
/// ExternalTranslationSettingsSheet.
struct OCRSampledColor: Codable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var isDark: Bool { (0.299 * red + 0.587 * green + 0.114 * blue) < 0.5 }
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
    /// nil for cache entries computed before this field existed, or if
    /// sampling failed (e.g. degenerate crop) — renderers fall back to a
    /// neutral color in that case. See OCRBackgroundSampler.
    var backgroundColor: OCRSampledColor? = nil

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
