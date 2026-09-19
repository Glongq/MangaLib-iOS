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
}
