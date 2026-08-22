import SwiftUI
import UIKit

/// Карточка тайтла в сетке каталога.
/// Обложка с фиксированным соотношением 2:3 (как в карточке тайтла на
/// детальном экране) + заголовок в 1 или 2 строки (см. titleLineLimit) —
/// решает не сама карточка, а родительский ряд целиком, чтобы разные
/// картинки и длинные названия не ломали сетку.
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
    /// Сколько строк места резервировать под название — считается РОДИТЕЛЬСКОЙ
    /// сеткой один раз на весь ряд (см. MangaCatalogView.grid), а не самой
    /// карточкой: если хотя бы у одного соседа в ряду название в 2 строки —
    /// весь ряд резервирует 2 строки (жанр у всех съезжает на одну и ту же
    /// позицию, короткие названия просто оставляют пустую строку сверху от
    /// жанра). Если у ВСЕХ карточек ряда название в 1 строку — резерв 1
    /// строка, жанр прижат вплотную без пустого зазора.
    let titleLineLimit: Int
    /// Дефолт 2 — прежнее поведение для мест, которым не важна ужимка ряда
    /// по факту (см. CharacterView.grid: там сетка маленькая, отдельная
    /// row-логика ей не нужна). Каталог (MangaCatalogView) передаёт значение
    /// явно, посчитанное на весь ряд.
    init(item: MangaItem, width: CGFloat, titleLineLimit: Int = 2) {
        self.item = item
        self.width = width
        self.titleLineLimit = titleLineLimit
    }

    // Для бэйджа статуса закладки (см. statusBadge) — реактивно, чтобы
    // бэйдж сразу появлялся/менялся при добавлении/перемещении в закладках,
    // не только при следующей перезагрузке экрана.
    @ObservedObject private var bookmarks = BookmarksStore.shared

    private var titleFont: Font { .caption.weight(.medium) }
    private var typeFont: Font { .caption2 }
    private static var titleUIFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        return UIFont.systemFont(ofSize: base.pointSize, weight: .medium)
    }

    /// Сколько строк реально займёт название при данной ширине карточки —
    /// точный расчёт через UIKit (boundingRect), а не догадка по длине
    /// строки: шрифт и перенос слов зависят от конкретных символов, только
    /// система знает точную раскладку. Используется родительской сеткой,
    /// чтобы решить, нужно ли ряду резервировать 2 строки под название
    /// (см. titleLineLimit выше).
    static func titleLineCount(_ text: String, width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        let constraint = CGSize(width: width, height: .greatestFiniteMagnitude)
        let box = (text as NSString).boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleUIFont],
            context: nil
        )
        let lines = Int((box.height / titleUIFont.lineHeight).rounded(.up))
        return min(max(lines, 1), 2)
    }

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
                // Явные width/height (2:3 от width — тот же формат, что и у
                // обложки в карточке тайтла на детальном экране, см.
                // MangaDetailView.heroCoverSize), а не .aspectRatio — тот сам
                // решал высоту от ПРЕДЛОЖЕННОЙ ширины, что зависело от
                // текущего layout-прохода; здесь высота — прямое
                // арифметическое следствие того же числа width, что и у
                // всех остальных карточек ряда.
                .frame(width: width, height: (width * 3 / 2).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) { statusBadge }
                .overlay(alignment: .topTrailing) { ratingBadge }

            // Название — резерв в titleLineLimit строк (1 или 2, решает
            // ряд целиком, см. комментарий у titleLineLimit): если у соседа
            // в ряду название длиннее — эта карточка тоже резервирует 2
            // строки (даже если своё название короче, реальный текст
            // остаётся сверху, а жанр съезжает на позицию под резервом).
            // Если весь ряд с короткими названиями — резерв 1 строка, жанр
            // без зазора.
            Text(item.displayTitle)
                .font(titleFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(titleLineLimit, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)

            // Тип тайтла — строка всегда занимает место, даже когда его нет
            // у конкретного тайтла (opacity 0 вместо условного исчезновения
            // View), по той же причине: высота карточки должна быть одной
            // и той же у всех, а не зависеть от того, есть тип или нет.
            Text(typeLabel ?? " ")
                .font(typeFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .opacity(typeLabel == nil ? 0 : 1)
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
