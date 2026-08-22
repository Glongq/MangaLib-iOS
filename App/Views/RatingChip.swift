import SwiftUI

/// Единый бэйдж оценки тайтла — используется ВЕЗДЕ, где показывается оценка:
/// карточка каталога/поиска (MangaCardView), карточка тайтла (MangaDetailView.
/// coverRatingBadge) и закладки (BookmarksView) — чтобы оценка везде выглядела
/// и раскрашивалась ОДИНАКОВО, как явно попросили ("чтобы эти оценки были
/// везде, не только в каталоге").
///
/// Без иконки звёздочки — заливка цветом (не прозрачная обводка, поменяли по
/// запросу) + белая цифра оценки. Цвет фона зависит от значения (границы
/// подтверждены явно пользователем):
///   7.0–10.0 — зелёный
///   5.0–6.9  — жёлтый
///   0.1–4.9  — красный
///   0.0      — серый
///
/// rating == nil (оценка ещё НЕ известна, а не подтверждённый ноль — например
/// в закладках сразу после добавления, до того как реальное значение
/// подтянулось с сервера) — бэйдж вообще не рисуется, чтобы не показывать
/// обманчивое "0.0" для тайтла с реальной высокой оценкой (см. баг-репорт:
/// "оценка подтянулась в закладках сразу и там пишет 0.0 хотя тайтл не 0.0").
struct RatingChip: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let rating: Double?
    /// Необязательный размер шрифта — nil значит стандартный caption2 (как в
    /// каталоге/закладках). Задаётся, например, в карточке тайтла, чтобы бейдж
    /// оценки был ТОЙ ЖЕ высоты, что и бейдж статуса («Читаю») на обложке.
    var fontSize: CGFloat? = nil
    var horizontalPadding: CGFloat = 7
    var verticalPadding: CGFloat = 3

    private func color(for value: Double) -> Color {
        switch value {
        case 7.0...:      return .green
        case 5.0..<7.0:   return .yellow
        case 0.001..<5.0: return .red
        default:          return .gray // ровно 0.0
        }
    }

    @ViewBuilder
    var body: some View {
        if let rating {
            Text(String(format: "%.1f", rating))
                .font(fontSize.map { .system(size: $0, weight: .bold) } ?? .caption2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(color(for: rating), in: Capsule())
                .padding(6)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        RatingChip(rating: 9.4)
        RatingChip(rating: 6.9)
        RatingChip(rating: 4.9)
        RatingChip(rating: 0.0)
        RatingChip(rating: nil) // ничего не рисует
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
