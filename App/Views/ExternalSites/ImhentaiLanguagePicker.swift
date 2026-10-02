import SwiftUI

/// imhentai languages (English/Japanese/Spanish/French/Korean/German/Russian)
/// — the same style/principle as ImhentaiCategoryPicker (tapping DISABLES
/// the language from results, empty by default means "no restrictions",
/// see the ImhentaiLanguage.bit doc-comment). A flag emoji instead of a
/// colored background — languages don't need color coding, the flag is
/// already recognizable on its own.
struct ImhentaiLanguagePicker: View {
    @Binding var excluded: Set<ImhentaiLanguage>

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(ImhentaiLanguage.allCases) { language in
                let isExcluded = excluded.contains(language)
                Button {
                    if isExcluded { excluded.remove(language) } else { excluded.insert(language) }
                } label: {
                    HStack(spacing: 6) {
                        Text(language.flag)
                        Text(language.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isExcluded ? Theme.textSecondary.opacity(0.6) : Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(isExcluded ? Theme.surfaceElevated : Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    ImhentaiLanguagePicker(excluded: .constant([.german]))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
