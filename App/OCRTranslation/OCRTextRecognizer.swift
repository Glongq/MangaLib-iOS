import UIKit
import Vision

/// Runs Vision text recognition on a page bitmap and clusters the
/// resulting lines into speech-bubble-sized blocks. On-device, no
/// network — used only by the external-site reader's translation
/// overlay (see PageTranslationController).
enum OCRTextRecognizer {

    /// `sourceLanguage` — "auto"/"ja"/"ko"/"zh"/"en" (see
    /// ExternalTranslationSettingsSheet) — maps to a ranked
    /// `recognitionLanguages` hint list, not a hard per-line switch:
    /// Vision does one recognition pass for the whole image with these as
    /// candidates, so "auto" just tries the likelier scanlation languages
    /// first. Good enough for "не нужен идеал".
    static func recognize(image: UIImage, sourceLanguage: String) async -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            recognizeSync(cgImage: cgImage, sourceLanguage: sourceLanguage)
        }.value
    }

    private static func languages(for sourceLanguage: String) -> [String] {
        switch sourceLanguage {
        case "ja": return ["ja-JP"]
        case "ko": return ["ko-KR"]
        case "zh": return ["zh-Hans"]
        case "en": return ["en-US"]
        default: return ["ja-JP", "ko-KR", "zh-Hans", "en-US"]
        }
    }

    private static func recognizeSync(cgImage: CGImage, sourceLanguage: String) -> [RecognizedTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015
        request.recognitionLanguages = languages(for: sourceLanguage)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else {
            return []
        }

        let lines: [RecognizedTextLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.3,
                  !candidate.string.isEmpty else { return nil }
            let box = observation.boundingBox
            // Vision: normalized, bottom-left origin. Overlay math (UIKit
            // subviews and SwiftUI GeometryReader rects) wants top-left.
            let rect = CGRect(x: box.origin.x, y: 1 - box.origin.y - box.height,
                               width: box.width, height: box.height)
            return RecognizedTextLine(text: candidate.string, rect: rect, confidence: candidate.confidence)
        }

        return cluster(lines: lines)
    }

    /// Greedy single-pass clustering of OCR lines into bubble-level
    /// blocks — Vision only reports per-line boxes, not per-paragraph.
    /// A new line merges into an open cluster when it horizontally
    /// overlaps that cluster's last line by enough AND sits close enough
    /// below it (tight interline spacing inside one bubble); otherwise it
    /// starts a new cluster. Thresholds are heuristic, tuned for typical
    /// manga bubble line spacing, not exact.
    private static func cluster(lines: [RecognizedTextLine]) -> [RecognizedTextBlock] {
        let sorted = lines.sorted {
            $0.rect.midY == $1.rect.midY ? $0.rect.minX < $1.rect.minX : $0.rect.midY < $1.rect.midY
        }

        var clusters: [[RecognizedTextLine]] = []
        for line in sorted {
            if let lastIndex = clusters.indices.last(where: { index in
                guard let last = clusters[index].last else { return false }
                let overlap = max(0, min(line.rect.maxX, last.rect.maxX) - max(line.rect.minX, last.rect.minX))
                let overlapFraction = overlap / min(line.rect.width, last.rect.width)
                let verticalGap = line.rect.minY - last.rect.maxY
                let avgLineHeight = (line.rect.height + last.rect.height) / 2
                // Tightened (was 0.3/0.6x) — too loose was bridging lines
                // from visually separate bubbles/labels into one block,
                // inflating its rect (and so the overlay box) well past
                // the actual text's footprint ("большие отступы,
                // не попадает в размер оригинала").
                return overlapFraction >= 0.4 && verticalGap <= 0.45 * avgLineHeight
            }) {
                clusters[lastIndex].append(line)
            } else {
                clusters.append([line])
            }
        }

        return clusters.map { clusterLines in
            let rect = clusterLines.dropFirst().reduce(clusterLines[0].rect) { $0.union($1.rect) }
            let text = clusterLines.map(\.text).joined(separator: "\n")
            return RecognizedTextBlock(id: UUID(), rect: rect, text: text, lines: clusterLines)
        }
    }
}
