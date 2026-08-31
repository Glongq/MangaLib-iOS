import SwiftUI

/// Расширенные поля поиска ImHentai — Tags/Parodies/Artists/Characters/
/// Groups (см. /advsearch/ на самом сайте, скриншот пользователя 31.08) —
/// КАЖДОЕ поле копит СВОЙ список значений (можно добавить сразу несколько
/// тегов, несколько персонажей и т.д.), в отличие от обычной строки
/// поиска (одна строка — один текст). Значения собираются в
/// ImhentaiAdvancedQuery.clauses() — см. её doc-comment в
/// ImhentaiProvider.swift насчёт того, что именно подтверждено HAR, а что
/// нет (только `tag` подтверждён живьём).
struct ImhentaiAdvancedFieldsPicker: View {
    @Binding var query: ImhentaiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Tags", values: $query.tags)
            field("Parodies", values: $query.parodies)
            field("Artists", values: $query.artists)
            field("Characters", values: $query.characters)
            field("Groups", values: $query.groups)
        }
    }

    private func field(_ title: String, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            AdvancedFieldInput(values: values)
        }
    }
}

/// Поле ввода одной категории — текст + кнопка добавления, ниже уже
/// добавленные значения чипами (CollapsibleChips, переиспользован как есть
/// — тап по чипу убирает значение, тот же приём, что и у onTap-чипов в
/// ExternalGalleryDetailView, просто здесь действие — удаление, а не
/// переход).
private struct AdvancedFieldInput: View {
    @Binding var values: [String]
    @State private var draft = ""

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Добавить…", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(trimmedDraft.isEmpty ? Theme.textSecondary.opacity(0.4) : Theme.accent)
                }
                .disabled(trimmedDraft.isEmpty)
            }
            if !values.isEmpty {
                CollapsibleChips(items: values.map { value in
                    .init(text: value, onTap: { values.removeAll { $0 == value } })
                })
            }
        }
    }

    private func add() {
        guard !trimmedDraft.isEmpty, !values.contains(trimmedDraft) else { return }
        values.append(trimmedDraft)
        draft = ""
    }
}

#Preview {
    ImhentaiAdvancedFieldsPicker(query: .constant(ImhentaiAdvancedQuery(tags: ["Anal", "Big breasts"])))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
