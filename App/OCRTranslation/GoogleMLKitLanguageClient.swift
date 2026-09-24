import UIKit
import MLKitCommon
import MLKitLanguageID
import MLKitTextRecognition
import MLKitTextRecognitionChinese
import MLKitTextRecognitionCommon
import MLKitTextRecognitionJapanese
import MLKitTextRecognitionKorean
import MLKitTranslate
import MLKitVision

actor GoogleMLKitLanguageClient {
    static let shared = GoogleMLKitLanguageClient()

    func recognize(image: UIImage, sourceLanguage: String) async -> [RecognizedTextLine]? {
        let recognizer: TextRecognizer
        switch sourceLanguage {
        case "zh":
            recognizer = TextRecognizer.textRecognizer(options: ChineseTextRecognizerOptions())
        case "ko":
            recognizer = TextRecognizer.textRecognizer(options: KoreanTextRecognizerOptions())
        case "en":
            recognizer = TextRecognizer.textRecognizer(options: TextRecognizerOptions())
        default:
            recognizer = TextRecognizer.textRecognizer(options: JapaneseTextRecognizerOptions())
        }

        let visionImage = VisionImage(image: image)
        visionImage.orientation = image.imageOrientation
        let result: Text? = await withCheckedContinuation { continuation in
            recognizer.process(visionImage) { result, error in
                continuation.resume(returning: error == nil ? result : nil)
            }
        }
        guard let result else { return nil }

        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }
        let lines = result.blocks.flatMap(\.lines).compactMap { line -> RecognizedTextLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let frame = line.frame
            guard !text.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
            return RecognizedTextLine(
                text: text,
                rect: CGRect(
                    x: frame.minX / width,
                    y: frame.minY / height,
                    width: frame.width / width,
                    height: frame.height / height
                ),
                confidence: 0.85
            )
        }
        return lines.isEmpty ? nil : lines
    }

    func translate(
        blocks: [RecognizedTextBlock],
        sourceLanguage: String,
        targetLanguage: String
    ) async -> [UUID: String]? {
        guard !blocks.isEmpty else { return nil }
        let sourceCode: String
        if sourceLanguage == "auto" {
            let sample = blocks.map(\.text).joined(separator: "\n")
            sourceCode = await identifyLanguage(in: sample) ?? inferredLanguage(in: sample)
        } else {
            sourceCode = sourceLanguage
        }
        guard let source = translateLanguage(sourceCode),
              let target = translateLanguage(targetLanguage),
              source != target else { return nil }

        let options = TranslatorOptions(sourceLanguage: source, targetLanguage: target)
        let translator = Translator.translator(options: options)
        let conditions = ModelDownloadConditions(
            allowsCellularAccess: true,
            allowsBackgroundDownloading: false
        )
        let modelReady: Bool = await withCheckedContinuation { continuation in
            translator.downloadModelIfNeeded(with: conditions) { error in
                continuation.resume(returning: error == nil)
            }
        }
        guard modelReady else { return nil }

        var translated: [UUID: String] = [:]
        for block in blocks {
            guard let text = await translate(block.text, with: translator) else { return nil }
            translated[block.id] = text
        }
        return translated
    }

    private func identifyLanguage(in text: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            LanguageIdentification.languageIdentification().identifyLanguage(for: text) { languageCode, error in
                guard error == nil,
                      let languageCode,
                      languageCode != IdentifiedLanguage.undetermined else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: languageCode)
            }
        }
    }

    private func translate(_ text: String, with translator: Translator) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            translator.translate(text) { translatedText, error in
                continuation.resume(returning: error == nil ? translatedText : nil)
            }
        }
    }

    private func translateLanguage(_ code: String) -> TranslateLanguage? {
        switch code.lowercased().split(separator: "-").first.map(String.init) {
        case "ja": return .japanese
        case "ko": return .korean
        case "zh": return .chinese
        case "en": return .english
        case "ru": return .russian
        default: return nil
        }
    }

    private func inferredLanguage(in text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "ko" }
        if scalars.contains(where: {
            (0x3400...0x4DBF).contains($0.value) ||
                (0x4E00...0x9FFF).contains($0.value) ||
                (0xF900...0xFAFF).contains($0.value)
        }) { return "zh" }
        return "en"
    }
}
