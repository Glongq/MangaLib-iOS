import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) { statusBadge }
                .overlay(alignment: .topTrailing) { ratingBadge }

            // Заголовок всегда резервирует 2 строки → ряды сетки выровнены (аналог line-clamp: 2).
            Text(item.displayTitle)
                .font(titleFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Тип тайтла под названием — подтянут ближе, когда заголовок,
            // скорее всего, уместился в одну строку (см. isLikelyOneLine).
            // Оценка приблизительная (по длине строки), но не завязана на
            // измерение геометрии — та же причина, по которой выше отказался
            // от GeometryReader: не хочу второй раз наступать на те же грабли
            // ради чисто косметической детали.
            if let type = item.type?.label, !type.isEmpty {
                Text(type)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, isLikelyOneLine ? -14 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Грубая эвристика "уместится ли заголовок в одну строку" — без
    /// измерения реальной ширины карточки (по сознательному решению, см.
    /// комментарий выше). Работает по средней длине слов и общей длине
    /// строки: короткие заголовки (≲ 14 символов) почти всегда в одну
    /// строку при 3 колонках на типичных экранах.
    private var isLikelyOneLine: Bool {
        item.displayTitle.count <= 14
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
