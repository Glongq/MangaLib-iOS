import Foundation
import SwiftUI
import Translation

/// Holds the live `TranslationSession` handed to us by `.translationTask`
/// (see PageTranslationSessionHost) — read by PageTranslationController to
/// run Stage-A batch translation. `nil` until the session is ready (or if
/// the language pack still needs downloading/was declined).
@MainActor
final class PageTranslationRuntime: ObservableObject {
    @Published private(set) var session: TranslationSession?

    func update(_ session: TranslationSession) {
        self.session = session
    }

    /// The session is created asynchronously by PageTranslationSessionHost's
    /// `.translationTask` — callers (PageTranslationController,
    /// ExternalReaderView's OCR preload) frequently start before it's
    /// ready, so this waits (bounded) instead of giving up immediately.
    func waitForSession(timeout: TimeInterval = 6) async -> TranslationSession? {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if let session { return session }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return nil
    }
}

/// Invisible plumbing view mounted once per reader session (not per page)
/// — `.translationTask` needs a real view in the hierarchy for the system
/// to manage the translation session and, on first use of a language
/// pair, its one-time language-pack download prompt. We don't want any
/// visible system translation UI over the page content itself, so this
/// view renders nothing.
struct PageTranslationSessionHost: View {
    let sourceLanguage: Locale.Language?
    let targetLanguage: Locale.Language
    let runtime: PageTranslationRuntime

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(.init(source: sourceLanguage, target: targetLanguage)) { session in
                runtime.update(session)
                try? await session.prepareTranslation()
            }
    }
}
