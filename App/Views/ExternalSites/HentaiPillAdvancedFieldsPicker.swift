import SwiftUI

/// Selection of ONE dimension + value for HentaiPill (see the
/// HentaiPillAdvancedQuery doc-comment — the site can't combine
/// Tags/Parodies/Characters/Artists with each other, nor with the search
/// text, these are honestly DIFFERENT, incompatible routes). The screen's
/// shared search field (`.searchable()`) meanwhile keeps working as a
/// plain `/search?q=` — there's no separate "Search" field here, nor
/// suggestions (suggestions would need a separate network request per
/// letter, which the site honestly doesn't confirm, see the
/// capabilities.hasTagBrowser doc-comment on Characters/Artists).
struct HentaiPillAdvancedFieldsPicker: View {
    @Binding var query: HentaiPillAdvancedQuery

    private static let kinds: [(ExternalTagNamespace, String)] = [
        (.tag, "Tags"), (.series, "Parodies"), (.character, "Characters"), (.artist, "Artists")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Искать по").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Picker("Измерение", selection: $query.kind) {
                    ForEach(Self.kinds, id: \.0) { kind, title in
                        Text(title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Значение").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                TextField("Например: ahegao…", text: $query.value)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

#Preview {
    HentaiPillAdvancedFieldsPicker(query: .constant(HentaiPillAdvancedQuery(kind: .tag, value: "ahegao")))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
