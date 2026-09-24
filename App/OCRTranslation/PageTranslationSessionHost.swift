import Foundation
import SwiftUI
import Translation

/// Queues Stage-A requests and executes them only from the live
/// `.translationTask` closure that owns the `TranslationSession`.
///
/// A session must not escape that closure. Keeping it in an observable
/// object and calling it from page/preload tasks caused non-catchable
/// assertions inside `com.apple.translation.TextSession` when SwiftUI
/// cancelled or replaced the host session.
@MainActor
final class PageTranslationRuntime: ObservableObject {
    private let broker = TranslationRequestBroker()

    func translate(_ blocks: [RecognizedTextBlock], targetLanguage: String) async -> [UUID: String]? {
        await broker.submit(blocks, targetLanguage: targetLanguage)
    }

    func run(session: TranslationSession) async {
        await broker.run(session: session)
    }
}

private actor TranslationRequestBroker {
    private struct Job {
        let id: UUID
        let blocks: [RecognizedTextBlock]
        let targetLanguage: String
        let continuation: CheckedContinuation<[UUID: String]?, Never>
    }

    private var jobs: [Job] = []
    private var workerID: UUID?
    private var inFlightJobID: UUID?

    func submit(_ blocks: [RecognizedTextBlock], targetLanguage: String) async -> [UUID: String]? {
        guard !blocks.isEmpty, !Task.isCancelled else { return nil }
        let jobID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                jobs.append(Job(id: jobID, blocks: blocks, targetLanguage: targetLanguage, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelQueuedJob(jobID) }
        }
    }

    /// Runs for exactly the lifetime of SwiftUI's `.translationTask`
    /// closure. Requests are serialized here, and the session never leaves
    /// the closure that created it. Cancelling a page removes only queued
    /// work; an already-submitted framework request is allowed to finish so
    /// cancellation cannot tear down TextSession mid-callback.
    func run(session: TranslationSession) async {
        let id = UUID()
        workerID = id

        while !Task.isCancelled, workerID == id {
            guard inFlightJobID == nil, !jobs.isEmpty else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            let job = jobs.removeFirst()
            inFlightJobID = job.id
            // Keep the framework call alive even if SwiftUI cancels the
            // host task while the reader is closing. An unstructured task
            // does not inherit later parent cancellation, while awaiting
            // its value keeps this `.translationTask` closure alive until
            // TextSession has delivered its final callback.
            let operation = Task {
                try await TranslationPipeline.translateBatch(
                    job.blocks,
                    targetLanguage: job.targetLanguage,
                    session: session
                )
            }
            let result = try? await operation.value
            inFlightJobID = nil
            job.continuation.resume(returning: result)
        }

        if workerID == id {
            workerID = nil
            let abandoned = jobs
            jobs.removeAll()
            for job in abandoned {
                job.continuation.resume(returning: nil)
            }
        }
    }

    private func cancelQueuedJob(_ id: UUID) {
        guard inFlightJobID != id,
              let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: index)
        job.continuation.resume(returning: nil)
    }
}

/// Invisible plumbing view mounted once for the whole reader lifetime.
/// All use of the provided session remains inside this closure through
/// `PageTranslationRuntime.run(session:)`.
struct PageTranslationSessionHost: View {
    let sourceLanguage: Locale.Language?
    let targetLanguage: Locale.Language
    let runtime: PageTranslationRuntime

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .translationTask(.init(source: sourceLanguage, target: targetLanguage)) { session in
                await runtime.run(session: session)
            }
    }
}
