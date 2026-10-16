import SwiftUI

/// e-hentai category buttons (Doujinshi/Manga/Artist CG/...) — visually
/// mirror the actual buttons on the site's home page (see the screenshot
/// the user shared). On the site, tapping DISABLES the category from
/// results (the button dims) — the same logic here: `excluded`, not
/// `included`, empty by default means "no restrictions" (see EHentaiProvider.
/// fetchIdsBySearch(excludedCategoryBits:) — 0 doesn't add f_cats to the URL
/// at all, just like on the actual site).
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

    /// Approximately match the button colors on the actual e-hentai.org
    /// page — for recognizability, not confirmed against the site's exact
    /// hex codes, eyeballed from a screenshot.
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
