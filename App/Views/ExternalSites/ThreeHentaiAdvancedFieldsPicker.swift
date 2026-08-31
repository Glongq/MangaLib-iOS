import SwiftUI

/// Расширенное поле поиска 3Hentai — своя строка поиска + Tags (см.
/// ThreeHentaiAdvancedQuery doc-comment — запятая в `q=` подтверждена HAR
/// как AND нескольких тегов; никаких других измерений на сайте не
/// подтверждено). Без подсказок — автокомплит на сайте не подтверждён
/// (см. ThreeHentaiProvider.fetchAutocomplete).
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
