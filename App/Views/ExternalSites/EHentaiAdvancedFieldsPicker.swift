import SwiftUI

/// Расширенные поля поиска E-Hentai — своя строка поиска + Tags/Parodies/
/// Characters/Artists/Groups (см. EHentaiAdvancedQuery doc-comment в
/// EHentaiProvider.swift — `namespace:value`-команда прямо внутри f_search,
/// подтверждено HAR). Автокомплита на сайте не подтверждено (см.
/// EHentaiProvider.fetchAutocomplete — честно пуст) — поля здесь простые,
/// без подсказок.
struct EHentaiAdvancedFieldsPicker: View {
    @Binding var query: EHentaiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            field("Tags", values: $query.tags)
            field("Parodies", values: $query.series)
            field("Characters", values: $query.characters)
            field("Artists", values: $query.artists)
            field("Groups", values: $query.groups)
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Поиск").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField("Свободный текст…", text: $query.search)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func field(_ title: String, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            SimpleChipFieldInput(values: values)
        }
    }
}

#Preview {
    EHentaiAdvancedFieldsPicker(query: .constant(EHentaiAdvancedQuery(tags: ["nudity"])))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
