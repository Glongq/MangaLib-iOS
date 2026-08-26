import SwiftUI

/// Лист оценки тайтла (1-10 звёзд) — открывается тапом по виджету «Оценки
/// пользователей» в карточке тайтла (см. MangaDetailView.ratingStatsBlock).
///
/// `POST /manga/rate` — ПОДТВЕРЖДЕНО реальным перехватом: тело
/// `{"score":Int,"rateable_id":Int,"rateable_type":"manga"}`, ответ —
/// актуальный агрегат (average/votes/user), см. MangaNetworkService.rateManga.
/// Ошибка (например 403 "Чтобы поставить оценку, нужно прочитать минимум 1
/// глав...") приходит с человекочитаемым текстом в
/// `{"data":{"toast":{"message":...}}}` (см. NetworkError.apiMessage) —
/// показываем тем же тостом, что и «Загрузка начата» (см.
/// DownloadsManager.showBanner), как и попросили.
struct RatingSheet: View {

    @ObservedObject var viewModel: MangaDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Int?
    @State private var isSubmitting = false

    init(viewModel: MangaDetailViewModel) {
        self.viewModel = viewModel
        _selected = State(initialValue: viewModel.detail?.rating?.user)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Оценка тайтла")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Theme.surfaceElevated, in: Circle())
                }
            }

            scoreBadge

            HStack(spacing: 6) {
                ForEach(1...10, id: \.self) { n in
                    Button {
                        selected = n
                    } label: {
                        Image(systemName: n <= (selected ?? 0) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(n <= (selected ?? 0) ? Theme.accent : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            actionButtons
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .interactiveDismissDisabled(isSubmitting)
    }

    /// Крупный цветной блок с выбранной оценкой в кружке по центру — цвет
    /// делит ту же шкалу 1→оранжевый…10→зелёный, что и полосы распределения
    /// (см. MangaDetailView.ratingColor, теперь не private — общий источник).
    private var scoreBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(selected.map { MangaDetailView.ratingColor(for: String($0)) } ?? Theme.surfaceElevated)
            Circle()
                .strokeBorder(.white.opacity(selected != nil ? 0.7 : 0), lineWidth: 2)
                .background(Circle().fill(.white.opacity(selected != nil ? 0.12 : 0)))
                .frame(width: 76, height: 76)
                .overlay {
                    Text(selected.map(String.init) ?? "—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(selected != nil ? .white : Theme.textSecondary)
                }
        }
        .frame(height: 108)
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
                .foregroundStyle(selected != nil ? Theme.background : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .background(selected != nil ? Theme.accent : Theme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(selected == nil || isSubmitting)
        }
    }

    private func submit() {
        guard let selected, !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                try await viewModel.submitRating(selected)
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
