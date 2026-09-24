import UIKit

struct GoogleCloudLanguageClient {
    private let apiKey: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        return URLSession(configuration: configuration)
    }()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func recognize(image: UIImage, sourceLanguage: String) async -> [RecognizedTextLine]? {
        guard let data = image.jpegData(compressionQuality: 0.88),
              let url = endpoint("https://vision.googleapis.com/v1/images:annotate") else { return nil }

        let hints = sourceLanguage == "auto" ? [] : [languageCode(sourceLanguage)]
        let payload = VisionRequest(images: [
            .init(
                image: .init(content: data.base64EncodedString()),
                features: [.init(type: "DOCUMENT_TEXT_DETECTION", maxResults: 1)],
                imageContext: hints.isEmpty ? nil : .init(languageHints: hints)
            )
        ])
        guard let body = try? JSONEncoder().encode(payload),
              let responseData = await post(url: url, body: body),
              let response = try? JSONDecoder().decode(VisionResponse.self, from: responseData),
              let annotation = response.responses.first?.fullTextAnnotation else { return nil }

        let pixelWidth = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let pixelHeight = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let paragraphs = annotation.pages
            .flatMap(\.blocks)
            .flatMap(\.paragraphs)

        let lines = paragraphs.compactMap { paragraph -> RecognizedTextLine? in
            let words = paragraph.words.map { $0.symbols.map(\.text).joined() }
            let separator = words.joined().unicodeScalars.contains(where: isCJK) ? "" : " "
            let text = words.joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let rect = normalizedRect(paragraph.boundingBox, width: pixelWidth, height: pixelHeight) else { return nil }
            let confidences = paragraph.words.compactMap(\.confidence)
            let confidence = confidences.isEmpty ? 0.8 : confidences.reduce(0, +) / Float(confidences.count)
            return RecognizedTextLine(text: text, rect: rect, confidence: confidence)
        }
        return lines.isEmpty ? nil : lines
    }

    func translate(
        blocks: [RecognizedTextBlock],
        sourceLanguage: String,
        targetLanguage: String
    ) async -> [UUID: String]? {
        guard !blocks.isEmpty,
              let url = endpoint("https://translation.googleapis.com/language/translate/v2") else { return nil }

        let payload = TranslationRequest(
            q: blocks.map(\.text),
            target: languageCode(targetLanguage),
            source: sourceLanguage == "auto" ? nil : languageCode(sourceLanguage),
            format: "text"
        )
        guard let body = try? JSONEncoder().encode(payload),
              let responseData = await post(url: url, body: body),
              let response = try? JSONDecoder().decode(TranslationResponse.self, from: responseData),
              response.data.translations.count == blocks.count else { return nil }

        return Dictionary(uniqueKeysWithValues: zip(blocks, response.data.translations).map { block, translation in
            (block.id, decodeHTMLEntities(translation.translatedText))
        })
    }

    func testConnection() async -> Bool {
        let block = RecognizedTextBlock(
            id: UUID(),
            rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            text: "Hello",
            lines: []
        )
        return await translate(
            blocks: [block],
            sourceLanguage: "en",
            targetLanguage: "ru"
        )?[block.id] != nil
    }

    private func endpoint(_ string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url
    }

    private func post(url: URL, body: Data) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private func languageCode(_ value: String) -> String {
        switch value {
        case "zh": return "zh-CN"
        default: return value
        }
    }

    private func normalizedRect(_ polygon: BoundingPolygon, width: CGFloat, height: CGFloat) -> CGRect? {
        let points = polygon.vertices.compactMap { vertex -> CGPoint? in
            guard let x = vertex.x, let y = vertex.y else { return nil }
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        return CGRect(
            x: minX / width,
            y: minY / height,
            width: (maxX - minX) / width,
            height: (maxY - minY) / height
        )
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

private struct VisionRequest: Encodable {
    let images: [ImageRequest]

    struct ImageRequest: Encodable {
        let image: ImageContent
        let features: [Feature]
        let imageContext: ImageContext?
    }
    struct ImageContent: Encodable { let content: String }
    struct Feature: Encodable { let type: String; let maxResults: Int }
    struct ImageContext: Encodable { let languageHints: [String] }
}

private struct VisionResponse: Decodable {
    let responses: [ImageResponse]

    struct ImageResponse: Decodable { let fullTextAnnotation: FullTextAnnotation? }
    struct FullTextAnnotation: Decodable { let pages: [Page] }
    struct Page: Decodable { let blocks: [Block] }
    struct Block: Decodable { let paragraphs: [Paragraph] }
    struct Paragraph: Decodable {
        let boundingBox: BoundingPolygon
        let words: [Word]
    }
    struct Word: Decodable {
        let boundingBox: BoundingPolygon
        let symbols: [Symbol]
        let confidence: Float?
    }
    struct Symbol: Decodable { let text: String }
}

private struct BoundingPolygon: Decodable {
    let vertices: [Vertex]
    struct Vertex: Decodable { let x: Int?; let y: Int? }
}

private struct TranslationRequest: Encodable {
    let q: [String]
    let target: String
    let source: String?
    let format: String
}

private struct TranslationResponse: Decodable {
    let data: ResponseData
    struct ResponseData: Decodable { let translations: [Translation] }
    struct Translation: Decodable { let translatedText: String }
}
