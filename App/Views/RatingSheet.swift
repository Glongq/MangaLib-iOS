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
///
/// Без крестика — закрывается свайпом вниз/тапом мимо (стандартный жест
/// листа, drag-индикатор сверху и так на это намекает) — как попросили.
/// Высота листа — РОВНО по содержимому (не системный .medium с пустым
/// хвостом снизу): измеряем реальную высоту через GeometryReader+
/// PreferenceKey (единственный надёжный способ узнать intrinsic-размер
/// вида в SwiftUI — готового API "detent по содержимому" нет) и отдаём её в
/// `.presentationDetents([.height(...)])`. Контент прижат к верху
/// (`.frame(alignment: .top)`), а не центрируется по высоте листа — та же
/// причина: раньше .medium давал лишнюю высоту, и содержимое "плавало"
/// по центру этой лишней высоты.
struct RatingSheet: View {

    @ObservedObject var viewModel: MangaDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Int?
    @State private var isSubmitting = false
    /// Стартовое значение — приблизительная высота контента, чтобы лист не
    /// открывался с нулевой/чужой высотой на первом кадре и не "прыгал"
    /// заметно после первого измерения (см. HeightPreferenceKey ниже).
    @State private var contentHeight: CGFloat = 330

    init(viewModel: MangaDetailViewModel) {
        self.viewModel = viewModel
        _selected = State(initialValue: viewModel.detail?.rating?.user)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Оценка тайтла")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .center)

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
        // background — ДО .frame(maxHeight: .infinity) ниже: GeometryReader
        // тут меряет натуральную высоту самого VStack+padding, а не уже
        // растянутого на весь лист контейнера (иначе измерялась бы высота
        // листа, а не контента, — самоссылающийся результат).
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(HeightPreferenceKey.self) { contentHeight = $0 }
        .presentationDetents([.height(contentHeight)])
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

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
