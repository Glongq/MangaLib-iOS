import SwiftUI

/// Экран трёхпозиционного выбора (Жанры / Теги).
/// Каждый элемент циклически переключается: нейтрально → включить → исключить.
struct TriStateFilterView: View {

    let title: String
    let options: [FilterOption]

    @Binding var selection: TriStateSelection
    @Binding var strict: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: TriStateSelection
    @State private var draftStrict: Bool
    @State private var search = ""

    init(title: String, options: [FilterOption], selection: Binding<TriStateSelection>, strict: Binding<Bool>) {
        self.title = title
        self.options = options
        _selection = selection
        _strict = strict
        _draft = State(initialValue: selection.wrappedValue)
        _draftStrict = State(initialValue: strict.wrappedValue)
    }

    private var filtered: [FilterOption] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? options : options.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                headerControls
                Divider().overlay(Theme.separator)
                list
                footer
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(Theme.accent)
    }

    // MARK: Шапка (поиск + строгое совпадение + сброс)

    private var headerControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("", text: $search,
                          prompt: Text("Поиск по названию").foregroundColor(Theme.textSecondary))
                    .foregroundStyle(Theme.textPrimary)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())

            HStack {
                Toggle(isOn: $draftStrict) {
                    Text("Строгое совпадение")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

                Spacer(minLength: 16)

                Button {
                    draft.clear()
                } label: {
                    Text("Сбросить")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    // MARK: Список

    private var list: some View {
        ScrollView {
            // Одна общая стеклянная панель на весь список (соединённая подложка),
            // строки внутри — обычные, разделены тонкими разделителями.
            VStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, option in
                    Button {
                        draft.cycle(option.id)
                    } label: {
                        row(option)
                    }
                    .buttonStyle(.plain)

                    if index < filtered.count - 1 {
                        Divider().overlay(Theme.separator).padding(.leading, 16)
                    }
                }
            }
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ option: FilterOption) -> some View {
        let state = draft.state(of: option.id)
        return HStack(spacing: 12) {
            triBox(state)
            Text(option.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(fillColor(for: state), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Лёгкая цветная заливка строки в зависимости от трёхпозиционного состояния
    /// (без собственного стекла — состояние подсвечивается на общей подложке списка).
    private func fillColor(for state: TriState) -> Color {
        switch state {
        case .neutral: return .clear
        case .include: return Theme.accent.opacity(0.18)
        case .exclude: return Color.red.opacity(0.16)
        }
    }

    @ViewBuilder
    private func triBox(_ state: TriState) -> some View {
        switch state {
        case .neutral:
            Image(systemName: "square")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
        case .include:
            Image(systemName: "checkmark.square.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
        case .exclude:
            Image(systemName: "minus.square.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
    }

    // MARK: Подвал

    private var footer: some View {
        HStack {
            legend(color: Theme.accent, text: "Включить")
            legend(color: .red, text: "Исключить")
            Spacer()
            Button {
                selection = draft
                strict = draftStrict
                dismiss()
            } label: {
                Text("Выбрать")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        TriStateFilterView(
            title: "Жанры",
            options: FilterCatalog.genres,
            selection: .constant(TriStateSelection()),
            strict: .constant(false)
        )
    }
    .preferredColorScheme(.dark)
}
