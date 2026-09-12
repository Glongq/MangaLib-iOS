import SwiftUI

/// Лист оценки ПЕРЕВОДА главы (не тайтла — см. RatingSheet для оценки
/// тайтла) — открывается кнопкой "Оценить перевод" на экране конца главы
/// (см. MangaReaderView.chapterActionButtons).
///
/// `POST /chapters/{id}/translation-rating` — ПОДТВЕРЖДЕНО реальным
/// перехватом: тело `{"translation_accuracy":Int,"readability_adaptation":
/// Int,"editing_formatting":Int}`, каждая 1-10, см.
/// MangaNetworkService.rateTranslation. Твоя предыдущая оценка (если была)
/// приходит прямо в ответе главы (см. ReaderViewModel.
/// chapterTranslationRating/TranslationRatingUser.myScores) — предзаполняет
/// три шкалы при открытии, тот же принцип, что и у RatingSheet.
struct TranslationRatingSheet: View {

    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var accuracy: Int
    @State private var readability: Int
    @State private var editing: Int
    @State private var isSubmitting = false

    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        let scores = viewModel.chapterTranslationRating?.user?.myScores
        _accuracy = State(initialValue: scores?.accuracy ?? 0)
        _readability = State(initialValue: scores?.readability ?? 0)
        _editing = State(initialValue: scores?.editing ?? 0)
    }

    private var canSubmit: Bool { accuracy > 0 && readability > 0 && editing > 0 }

    var body: some View {
        VStack(spacing: 18) {
            Text("Оценка перевода главы")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .center)

            starRow(title: "Точность перевода", score: $accuracy)
            starRow(title: "Адаптация и читаемость", score: $readability)
            starRow(title: "Вёрстка и оформление", score: $editing)

            actionButtons
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Было 440 — с явным запасом под содержимое (реальная сумма
        // высот/паддингов заголовка + 3 строк со звёздами + кнопок
        // ≈310-330) — по прямой просьбе ужато, тот же приём, что и у
        // RatingSheet.ratingSheetHeight.
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .interactiveDismissDisabled(isSubmitting)
    }

    private func starRow(title: String, score: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Text(score.wrappedValue > 0 ? "\(score.wrappedValue)" : "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            // Крупнее (было .footnote) и чуть плотнее (было spacing: 4) — по
            // прямой просьбе, "не сильно" в обе стороны.
            HStack(spacing: 3) {
                ForEach(1...10, id: \.self) { n in
                    Button {
                        score.wrappedValue = n
                    } label: {
                        Image(systemName: n <= score.wrappedValue ? "star.fill" : "star")
                            .font(.subheadline)
                            .foregroundStyle(n <= score.wrappedValue ? Theme.accent : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("Отменить")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(isSubmitting)

            Button {
                submit()
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().tint(Theme.background)
                    } else {
                        Text("Оценить")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(canSubmit ? Theme.background : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .background(canSubmit ? Theme.accent : Theme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!canSubmit || isSubmitting)
        }
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                try await viewModel.submitTranslationRating(accuracy: accuracy, readability: readability, editing: editing)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
                dismiss()
            }
        }
    }
}
