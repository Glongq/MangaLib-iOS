import SwiftUI
import UIKit

/// Карточка тайтла в сетке каталога.
/// Строгая структура: обложка с фиксированным соотношением 3:4 + заголовок в 2 строки,
/// чтобы разные картинки и длинные названия не ломали сетку.
struct MangaCardView: View {
    let item: MangaItem
    /// Ширина карточки в поинтах — ЯВНО считается один раз родительской
    /// сеткой (см. gridCardWidth ниже) и передаётся сюда, а не выводится
    /// самой карточкой из .flexible()-колонки/.aspectRatio. Раньше ширина
    /// колонки (которую сама решает LazyVGrid для .flexible()) и высота
    /// обложки (которую сама решает .aspectRatio от предложенной ширины)
    /// считались НЕЗАВИСИМО друг от друга в двух разных местах — на практике
    /// эти два независимых расчёта иногда расходились на пиксель между
    /// соседними карточками (разная промежуточная перекомпоновка при
    /// подгрузке асинхронных обложек), из-за чего сетка выглядела "поплывшей"
    /// и текст под обложками сдвигался. Теперь и сетка (GridItem.fixed), и
    /// каждая карточка получают ОДНО И ТО ЖЕ число — расхождению неоткуда взяться.
    let width: CGFloat

    // Для бэйджа статуса закладки (см. statusBadge) — реактивно, чтобы
    // бэйдж сразу появлялся/менялся при добавлении/перемещении в закладках,
    // не только при следующей перезагрузке экрана.
    @ObservedObject private var bookmarks = BookmarksStore.shared

    private var titleFont: Font { .caption.weight(.medium) }
    private var typeFont: Font { .caption2 }

    /// Ширина одной карточки в сетке из `columns` равных колонок: общая
    /// ширина минус горизонтальные отступы контейнера с обеих сторон и
    /// промежутки между колонками, делённая на число колонок. Единая точка
    /// расчёта — вызывающая сетка использует ЭТО ЖЕ число и для
    /// GridItem(.fixed(...)), и для параметра width каждой карточки, поэтому
    /// они физически не могут разойтись (см. комментарий у width выше).
    static func gridCardWidth(totalWidth: CGFloat, columns: Int = 3, spacing: CGFloat = 12, containerPadding: CGFloat = 12) -> CGFloat {
        let available = totalWidth - containerPadding * 2 - spacing * CGFloat(columns - 1)
        return max(0, floor(available / CGFloat(columns)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                // Явные width/height (3:4 от width), а не .aspectRatio — тот
                // сам решал высоту от ПРЕДЛОЖЕННОЙ ширины, что зависело от
                // текущего layout-прохода; здесь высота — прямое
                // арифметическое следствие того же числа width, что и у
                // всех остальных карточек ряда.
                .frame(width: width, height: (width * 4 / 3).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) { statusBadge }
                .overlay(alignment: .topTrailing) { ratingBadge }

            // Название — максимум 2 строки, но БЕЗ фиксированной высоты: в
            // одну строку название занимает одну строку, в две — две, а тип
            // тайтла ниже всегда вплотную под последней реальной строкой
            // названия (а не отдельным "3-м слотом" с пустым местом над ним,
            // как было раньше при жёстком резерве под 2 строки). На
            // выравнивание сетки это не влияет: обложки у всех карточек
            // всё равно одной высоты и идут первыми в VStack — если у
            // соседних карточек в ряду название разной длины (1 и 2 строки),
            // просто сами карточки/ряд станут чуть выше по самой длинной, а
            // обложки останутся строго на одном уровне сверху.
            Text(item.displayTitle)
                .font(titleFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)

            // Тип тайтла — сразу под названием, только если он реально есть
            // (раньше строка держалась всегда, невидимой, ради фиксированной
            // высоты — это больше не нужно).
            if let typeLabel {
                Text(typeLabel)
                    .font(typeFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .top)
    }

    private var typeLabel: String? {
        guard let label = item.type?.label, !label.isEmpty else { return nil }
        return label
    }

    // MARK: Обложка (object-fit: cover + скелетон + fallback)

    private var cover: some View {
        RemoteImage(url: item.cover?.bestURL) { image in
            image
                .resizable()
                .scaledToFill()          // аналог object-fit: cover
        } placeholder: {
            SkeletonBox()
        } failure: {
            coverFallback
        }
        .clipped()
    }

    // MARK: Бэйдж статуса закладки (слева сверху)

    /// Если тайтл сейчас лежит в одной из папок закладок — маленькая цветная
    /// плашка со статусом ("Читаю"/"В планах"/"Брошено"/...) поверх обложки,
    /// слева сверху. Цвет — свой на каждую стандартную папку, см.
    /// BookmarkFolder.badgeColor.
    @ViewBuilder
    private var statusBadge: some View {
        if let folderId = bookmarks.folderId(forSlug: item.apiSlug),
           let folder = bookmarks.allFolders.first(where: { $0.id == folderId }) {
            Text(folder.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(folder.badgeColor, in: Capsule())
                .padding(6)
        }
    }

    private var coverFallback: some View {
        ZStack {
            Theme.surfaceElevated
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Единый бэйдж оценки (см. RatingChip) — везде одинаковый: без
    /// звёздочки, цвет по значению, сверху справа обложки. Показывается
    /// ВСЕГДА, даже без оценки (RatingChip сам красит nil/0.0 серым — как
    /// явно попросили, "если 0.0 то серым", а не скрывает бэйдж вовсе).
    private var ratingBadge: some View {
        RatingChip(rating: item.rating?.value)
    }
}

/// Анимированный скелетон-плейсхолдер на время загрузки изображения.
struct SkeletonBox: View {
    @State private var animate = false

    var body: some View {
        Rectangle()
            .fill(Theme.skeleton)
            .overlay {
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.06), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: animate ? 220 : -220)
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
