import SwiftUI

/// Кнопки категорий imhentai (Manga/Doujinshi/Western/Image Set/Artist CG/
/// Game CG) — тот же стиль/принцип, что у EHentaiCategoryPicker (тап
/// ВЫКЛЮЧАЕТ категорию из выдачи, пусто по умолчанию значит "без
/// ограничений", см. ImhentaiCategory.bit doc-comment).
struct ImhentaiCategoryPicker: View {
    @Binding var excluded: Set<ImhentaiCategory>

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(ImhentaiCategory.allCases) { category in
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

    /// Свой набор цветов (не пересекается визуально с EHentaiCategoryPicker
    /// — на глаз, точные hex сайта не подтверждены, как и у e-hentai).
    private static func color(for category: ImhentaiCategory) -> Color {
        switch category {
        case .manga: return Color(red: 0.94, green: 0.62, blue: 0.20)
        case .doujinshi: return Color(red: 0.90, green: 0.47, blue: 0.47)
        case .western: return Color(red: 0.56, green: 0.82, blue: 0.51)
        case .imageSet: return Color(red: 0.30, green: 0.45, blue: 0.85)
        case .artistCG: return Color(red: 0.82, green: 0.82, blue: 0.20)
        case .gameCG: return Color(red: 0.31, green: 0.65, blue: 0.31)
        }
    }
}

#Preview {
    ImhentaiCategoryPicker(excluded: .constant([.manga]))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
