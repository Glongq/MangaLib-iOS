import SwiftUI

/// Поле ввода одной категории — текст + кнопка добавления, ниже уже
/// добавленные значения чипами (тап по чипу убирает значение). БЕЗ
/// подсказок при наборе — общий переиспользуемый компонент для сайтов, где
/// автокомплит не подтверждён HAR (E-Hentai, 3Hentai — см. их
/// AdvancedFieldsPicker). Там, где подсказки ЕСТЬ (imhentai — локальная
/// таблица, Simply Hentai — реальный /search/autocomplete), у каждого
/// сайта свой собственный вариант этого поля с добавленным списком
/// подсказок — этот компонент такой логики намеренно не несёт, чтобы не
/// путать "подтверждено" с "нет".
struct SimpleChipFieldInput: View {
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
