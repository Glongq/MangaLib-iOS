import SwiftUI
import UIKit

/// Карточка тайтла в сетке каталога.
/// Строгая структура: обложка с фиксированным соотношением 3:4 + заголовок в 2 строки,
/// чтобы разные картинки и длинные названия не ломали сетку.
struct MangaCardView: View {
    let item: MangaItem

    // Для бэйджа статуса закладки (см. statusBadge) — реактивно, чтобы
    // бэйдж сразу появлялся/менялся при добавлении/перемещении в закладках,
    // не только при следующей перезагрузке экрана.
    @ObservedObject private var bookmarks = BookmarksStore.shared

    // ИСПРАВЛЕНО (регрессия): пробовал считать ширину карточки вручную через
    // GeometryReader (и на уровне ячейки, и на уровне всей сетки) — оба раза
    // это либо давало неоднозначную высоту (GeometryReader не участвует в
    // обычном "идеальном размере" наравне с другими вью), либо явно
    // вычисленное число расходилось с тем, что LazyVGrid САМА даёт
    // .flexible()-колонке, из-за чего карточки переставали совпадать со
    // своим слотом в сетке — отсюда и "поплывшие" обложки. Вернул исходный,
    // проверенный способ: .aspectRatio(fit) НАПРЯМУЮ на обложке (не на
    // GeometryReader) — это ровно то, для чего этот модификатор
    // предназначен, и он не имеет описанной выше двусмысленности. Именно
    // так это уже работало раньше, до серии моих правок.
    private var titleFont: Font { .caption.weight(.medium) }
    private var typeFont: Font { .caption2 }

    // ИСПРАВЛЕНО: `lineLimit(_:reservesSpace:)` в теории резервирует
    // одинаковую высоту под 2/1 строки на всех карточках, но по факту всё
    // равно "гуляло" по факту рендера (близко к системному округлению
    // строк/шрифта) — визуально сетка продолжала казаться неровной. Вместо
    // резервирования через lineLimit теперь у блока названия и у блока типа
    // явный ЧИСЛОВОЙ .frame(height:) в поинтах, посчитанный один раз из
    // реальной высоты строки шрифта (UIFont.lineHeight) — это уже не
    // эвристика и не резервирование, а буквально фиксированный прямоугольник
    // одного и того же размера на КАЖДОЙ карточке, вне зависимости от текста.
    private var titleBlockHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight * 2)
    }
    private var typeBlockHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .caption2).lineHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) { statusBadge }
                .overlay(alignment: .topTrailing) { ratingBadge }

            // Название — фиксированный прямоугольник высотой ровно в 2
            // строки шрифта, на ВСЕХ карточках одинаковый (см. комментарий выше).
            Text(item.displayTitle)
                .font(titleFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: titleBlockHeight, alignment: .top)

            // Тип тайтла под названием — фиксированный прямоугольник высотой
            // ровно в 1 строку шрифта на ВСЕХ карточках, просто невидимый,
            // если типа нет (место всё равно остаётся).
            Text(typeLabel ?? " ")
                .font(typeFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: typeBlockHeight, alignment: .top)
                .opacity(typeLabel == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
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
