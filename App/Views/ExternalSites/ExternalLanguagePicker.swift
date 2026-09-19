import SwiftUI

/// Multi-select "which languages to show" filter — unlike
/// ImhentaiLanguagePicker (imhentai-only, EXCLUDES languages via that
/// site's own bitmask query param), this is the cross-site INCLUSION
/// filter (see ExternalCatalogLanguage/ExternalCatalogFilterStore.
/// selectedLanguages): an empty selection means "no filter, show every
/// language"; picking one or more restricts results to just those,
/// applied client-side in ExternalCatalogGridView.filteredItems. Titles
/// with no declared language always show regardless of this selection.
struct ExternalLanguagePicker: View {
    @Binding var selected: Set<ExternalCatalogLanguage>

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(ExternalCatalogLanguage.allCases) { language in
                let isSelected = selected.contains(language)
                Button {
                    if isSelected { selected.remove(language) } else { selected.insert(language) }
                } label: {
                    Text(language.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Theme.background : Theme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(isSelected ? Theme.accent : Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    ExternalLanguagePicker(selected: .constant([.japanese]))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
