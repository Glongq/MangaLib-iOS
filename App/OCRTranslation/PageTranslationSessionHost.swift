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

/// Invisible plumbing view mounted once per reader session (not per page,
/// and unconditionally — see ExternalReaderView.body's comment on why it's
/// not gated by the ocrEnabled toggle) — `.translationTask` needs a real
/// view in the hierarchy for the system to manage the translation session.
/// `Color.clear` sized by the surrounding ZStack (NOT an explicit 0x0
/// frame — that risks the view being treated as not actually part of the
/// visible hierarchy) so it stays fully invisible without ever disappearing.
struct PageTranslationSessionHost: View {
    let sourceLanguage: Locale.Language?
    let targetLanguage: Locale.Language
    let runtime: PageTranslationRuntime

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .translationTask(.init(source: sourceLanguage, target: targetLanguage)) { session in
                runtime.update(session)
                // NOT calling session.prepareTranslation() here: on a
                // language pair whose pack isn't installed yet, that
                // proactively triggers Apple's OWN system download-prompt
                // UI (a sheet presented on the app's scene). Confirmed via
                // device crash log — under LiveContainer (sideloaded, a
                // custom scene host) that private sheet-presentation path
                // crashes with "-[_UISceneHostingController
                // _setSheetConfiguration:]: unrecognized selector". Simply
                // not calling it means a missing pack just makes
                // translateBatch fail silently instead (already handled),
                // trading automatic pack installation for not crashing —
                // an acceptable trade given "не нужен идеал".
            }
    }
}
