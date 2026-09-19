import Foundation
import Translation

/// Stage A — literal machine translation via Apple's on-device
/// `Translation` framework. Free, private, no network dependency; this is
/// what has to land within the "couple of seconds" the user asked for.
enum TranslationPipeline {

    /// Serializes ALL calls to `session.translations(from:)` (one at a
    /// time) — every page's own load task AND the preload path
    /// (ExternalReaderView.preloadOCRTranslation, for pages ahead of the
    /// current one) share the SAME `TranslationSession` instance from
    /// PageTranslationRuntime, and `TranslationSession` isn't safe against
    /// overlapping requests: interleaved calls have been observed to crash
    /// the system Translation framework itself (assertion failure deep in
    /// `com.apple.translation.TextSession`, on-device crash log). Same
    /// idiom as RephraseClient.RequestGate for Stage-B/LM Studio.
    private static let requestGate = RequestGate()

    private actor RequestGate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    /// Batch-translates all of a page's blocks in one call. Correlates
    /// results by `clientIdentifier` (not array order) since the session
    /// doesn't guarantee response order matches request order.
    static func translateBatch(_ blocks: [RecognizedTextBlock], session: TranslationSession) async throws -> [UUID: String] {
        guard !blocks.isEmpty else { return [:] }
        let requests = blocks.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        await requestGate.acquire()
        defer { Task { await requestGate.release() } }
        let responses = try await session.translations(from: requests)
        var result: [UUID: String] = [:]
        for response in responses {
            guard let idString = response.clientIdentifier, let id = UUID(uuidString: idString) else { continue }
            result[id] = response.targetText
        }
        return result
    }
}
