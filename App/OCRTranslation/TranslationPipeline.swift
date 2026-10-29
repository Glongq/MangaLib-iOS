import Foundation
import Translation

/// Stage A — literal machine translation through Apple's on-device
/// Translation framework. Calls are serialized by TranslationRequestBroker
/// and always execute inside the owning `.translationTask` closure.
enum TranslationPipeline {
    /// Batch-translates all meaningful text blocks. OCR noise made only of
    /// digits or punctuation is passed through without asking Translation;
    /// control characters are removed to avoid invalid framework inputs.
    static func translateBatch(
        _ blocks: [RecognizedTextBlock],
        targetLanguage: String,
        session: TranslationSession
    ) async throws -> [UUID: String] {
        guard !blocks.isEmpty else { return [:] }

        var result: [UUID: String] = [:]
        let prepared = blocks.compactMap { block -> TranslationSession.Request? in
            let text = sanitized(block.text)
            guard shouldTranslate(text, targetLanguage: targetLanguage) else {
                if !text.isEmpty { result[block.id] = text }
                return nil
            }
            return TranslationSession.Request(sourceText: text, clientIdentifier: block.id.uuidString)
        }

        guard !prepared.isEmpty else { return result }
        let responses = try await session.translations(from: prepared)
        for response in responses {
            guard let idString = response.clientIdentifier,
                  let id = UUID(uuidString: idString) else { continue }
            result[id] = response.targetText
        }
        return result
    }

    private static func sanitized(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        return String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .prefix(1_000)
            .description
    }

    private static func shouldTranslate(_ text: String, targetLanguage: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }

        let matchingCount: Int
        switch targetLanguage {
        case "ru":
            matchingCount = letters.filter { scalar in
                (0x0400...0x052F).contains(scalar.value)
            }.count
        case "en":
            matchingCount = letters.filter { scalar in
                (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
            }.count
        default:
            return true
        }

        return Double(matchingCount) / Double(letters.count) < 0.7
    }
}
