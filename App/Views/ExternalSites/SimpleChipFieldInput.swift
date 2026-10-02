import SwiftUI

/// Input field for one category — text + an add button, below it the
/// already-added values as chips (tapping a chip removes the value). NO
/// suggestions while typing — a shared reusable component for sites where
/// autocomplete isn't confirmed by HAR (E-Hentai, 3Hentai — see their
/// AdvancedFieldsPicker). Where suggestions DO exist (imhentai — a local
/// table, Simply Hentai — a real /search/autocomplete), each site has its
/// own dedicated variant of this field with a suggestion list added — this
/// component deliberately doesn't carry that logic, so as not to blur
/// "confirmed" with "not".
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
