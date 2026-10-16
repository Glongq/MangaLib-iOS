import SwiftUI

/// Advanced search field for 3Hentai — its own search box + Tags (see the
/// ThreeHentaiAdvancedQuery doc-comment — a comma in `q=` is confirmed by
/// HAR to AND together several tags; no other dimensions are confirmed on
/// the site). No suggestions — autocomplete isn't confirmed on the site
/// (see ThreeHentaiProvider.fetchAutocomplete).
struct ThreeHentaiAdvancedFieldsPicker: View {
    @Binding var query: ThreeHentaiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Поиск").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                TextField("Свободный текст…", text: $query.search)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                SimpleChipFieldInput(values: $query.tags)
            }
        }
    }
}

#Preview {
    ThreeHentaiAdvancedFieldsPicker(query: .constant(ThreeHentaiAdvancedQuery(tags: ["anal", "diaper"])))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
