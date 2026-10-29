import SwiftUI

/// Bottom capsule suggesting to switch the OCR source language (and turn
/// on translation, if it's currently off) to match a title's own declared
/// language — see ExternalGalleryDetailView.evaluateLanguageSuggestion.
/// Same glass-capsule look as RootView.DownloadToast, just two lines
/// (message + Да/Нет) instead of one, and bottom-anchored.
struct TitleLanguageSuggestionCapsule: View {
    let language: DetectedTitleLanguage
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Тайтл на языке: \(language.displayName). Переводить с него?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button("Нет", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Да", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 24)
    }
}
