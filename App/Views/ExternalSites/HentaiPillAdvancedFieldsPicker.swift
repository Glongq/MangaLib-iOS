import SwiftUI

/// Выбор ОДНОГО измерения + значения для HentaiPill (см.
/// HentaiPillAdvancedQuery doc-comment — сайт не умеет комбинировать
/// Tags/Parodies/Characters/Artists между собой, ни с текстом поиска, это
/// честно РАЗНЫЕ несовместимые маршруты). Общее поле поиска экрана
/// (`.searchable()`) при этом продолжает работать как обычный `/search?q=`
/// — тут нет ни отдельного поля "Поиск", ни подсказок (для подсказок
/// понадобился бы отдельный сетевой запрос под каждую букву, который
/// сайт честно не подтверждает, см. capabilities.hasTagBrowser
/// doc-comment у Characters/Artists).
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
