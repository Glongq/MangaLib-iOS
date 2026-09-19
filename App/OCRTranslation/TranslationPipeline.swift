import Foundation
import Translation

/// Stage A — literal machine translation via Apple's on-device
/// `Translation` framework. Free, private, no network dependency; this is
/// what has to land within the "couple of seconds" the user asked for.
enum TranslationPipeline {

    /// Batch-translates all of a page's blocks in one call. Correlates
    /// results by `clientIdentifier` (not array order) since the session
    /// doesn't guarantee response order matches request order.
    static func translateBatch(_ blocks: [RecognizedTextBlock], session: TranslationSession) async throws -> [UUID: String] {
        guard !blocks.isEmpty else { return [:] }
        let requests = blocks.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        let responses = try await session.translations(from: requests)
        var result: [UUID: String] = [:]
        for response in responses {
            guard let idString = response.clientIdentifier, let id = UUID(uuidString: idString) else { continue }
            result[id] = response.targetText
        }
        return result
    }
}
