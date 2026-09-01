import SwiftUI

/// Advanced search field for hitomi — a single free-text field (see the
/// HitomiAdvancedQuery doc-comment: unlike every other site, there's
/// nothing to structure into separate chip fields — the site's own search
/// bar IS one field with inline prefixes). Space-separated terms are ANDed
/// (see HitomiProvider.fetchIdsBySearch); each term may carry its own
/// `female:`/`male:`/`type:`/`tag:`/`artist:`/`group:`/`character:`/
/// `series:` prefix, or be left bare (auto-detected as a plain tag).
struct HitomiAdvancedFieldsPicker: View {
    @Binding var query: HitomiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Поиск").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField("horse female:anal type:doujinshi…", text: $query.search)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Text("Слово без префикса ищет как тег. Через пробел — несколько условий сразу (все должны совпасть). Префиксы: female:, male:, type:, tag:, artist:, group:, character:, series:")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

#Preview {
    HitomiAdvancedFieldsPicker(query: .constant(HitomiAdvancedQuery(search: "horse female:anal")))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
