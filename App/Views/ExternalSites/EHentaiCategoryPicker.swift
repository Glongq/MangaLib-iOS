import SwiftUI

/// Кнопки категорий e-hentai (Doujinshi/Manga/Artist CG/...) — визуально
/// повторяют сами кнопки на главной странице сайта (см. скриншот, которым
/// поделился пользователь). На сайте нажатие ВЫКЛЮЧАЕТ категорию из выдачи
/// (кнопка гаснет) — та же логика здесь: `excluded`, не `included`, пусто
/// по умолчанию значит "без ограничений" (см. EHentaiProvider.
/// fetchIdsBySearch(excludedCategoryBits:) — 0 вообще не добавляет f_cats
/// в URL, как и на самом сайте).
struct EHentaiCategoryPicker: View {
    @Binding var excluded: Set<EHentaiCategory>

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(EHentaiCategory.allCases) { category in
                let isExcluded = excluded.contains(category)
                Button {
                    if isExcluded { excluded.remove(category) } else { excluded.insert(category) }
                } label: {
                    Text(category.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isExcluded ? Theme.textSecondary.opacity(0.6) : .white)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(isExcluded ? Theme.surfaceElevated : Self.color(for: category), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Приблизительно повторяют цвета кнопок на самой странице e-hentai.org
    /// — для узнаваемости, не подтверждены точными hex-кодами сайта, взяты
    /// на глаз со скриншота.
    private static func color(for category: EHentaiCategory) -> Color {
        switch category {
        case .doujinshi: return Color(red: 0.90, green: 0.47, blue: 0.47)
        case .manga: return Color(red: 0.94, green: 0.62, blue: 0.20)
        case .artistCG: return Color(red: 0.82, green: 0.82, blue: 0.20)
        case .gameCG: return Color(red: 0.31, green: 0.65, blue: 0.31)
        case .western: return Color(red: 0.56, green: 0.82, blue: 0.51)
        case .nonH: return Color(red: 0.25, green: 0.75, blue: 0.80)
        case .imageSet: return Color(red: 0.30, green: 0.45, blue: 0.85)
        case .cosplay: return Color(red: 0.60, green: 0.35, blue: 0.80)
        case .asianPorn: return Color(red: 0.90, green: 0.55, blue: 0.75)
        case .misc: return Color(red: 0.55, green: 0.55, blue: 0.55)
        }
    }
}

#Preview {
    EHentaiCategoryPicker(excluded: .constant([.manga]))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
