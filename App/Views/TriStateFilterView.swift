import SwiftUI

extension Binding where Value == Bool {
    /// Оборачивает non-optional Binding<Bool> в Binding<Bool?> — нужен, чтобы
    /// прокидывать реальные (не спец-фильтровые) genresStrict/tagsStrict из
    /// MangaFilter в TriStateFilterView.strict, у которого теперь optional-тип
    /// (см. TriStateFilterView.strict).
    var toOptional: Binding<Bool?> {
        Binding<Bool?>(get: { self.wrappedValue }, set: { self.wrappedValue = $0 ?? false })
    }
}

/// Экран трёхпозиционного выбора (Жанры / Теги).
/// Каждый элемент циклически переключается: нейтрально → включить → исключить.
struct TriStateFilterView: View {

    let title: String
    let options: [FilterOption]

    @Binding var selection: TriStateSelection
    /// nil — экран используется вне обычного MangaFilter (например «Спец
    /// фильтр» в настройках, см. SpecialFilterSettingsView), где отдельного
    /// серверного параметра "строгое совпадение" нет и сам тумблер только
    /// сбивал бы с толку — тогда строка тумблера просто не показывается.
    @Binding var strict: Bool?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var search = ""
    /// Фокус поля поиска — показывает иконку "свернуть клавиатуру" слева от
    /// легенды Включить/Исключить в подвале (см. footer), пока клавиатура
    /// открыта; тап по иконке снимает фокус и убирает её саму.
    @FocusState private var searchFocused: Bool

    init(title: String, options: [FilterOption], selection: Binding<TriStateSelection>, strict: Binding<Bool?> = .constant(nil)) {
        self.title = title
        self.options = options
        _selection = selection
        _strict = strict
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
        .toolbarBackground(Theme.background, for: .navigationBar)
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
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surfaceElevated, in: Capsule())

            HStack {
                if let strictBinding = Binding($strict) {
                    Toggle(isOn: strictBinding) {
                        Text("Строгое совпадение")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                }

                Spacer(minLength: 16)

                Button {
                    selection.clear()
                } label: {
                    Text("Сбросить")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.background)
    }

    // MARK: Список

    private var list: some View {
        ScrollView {
            // Одна общая сплошная подложка на весь список (как в Комментариях/Главах),
            // строки внутри — обычные, разделены тонкими разделителями.
            VStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, option in
                    Button {
                        selection.cycle(option.id)
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ option: FilterOption) -> some View {
        let state = selection.state(of: option.id)
        return HStack(spacing: 12) {
            triBox(state)
            Text(option.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func triBox(_ state: TriState) -> some View {
        switch state {
        case .neutral:
            Image(systemName: "square")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
        case .include:
            Image(systemName: "plus.square.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .exclude:
            Image(systemName: "minus.square.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
    }

    // MARK: Подвал

    private var footer: some View {
        HStack {
            // Иконка "свернуть клавиатуру" — показывается только пока
            // реально открыта (поиск в фокусе), слева от легенды
            // Включить/Исключить; тап по ней снимает фокус, сама иконка
            // тут же пропадает вместе с клавиатурой.
            if searchFocused {
                Button {
                    searchFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

            legend(color: .green, text: "Включить")
            legend(color: .red, text: "Исключить")
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Выбрать")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.background, ignoresSafeAreaEdges: .bottom)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 13, height: 13)
            Text(text).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        TriStateFilterView(
            title: "Жанры",
            options: FilterCatalog.genres,
            selection: .constant(TriStateSelection())
        )
    }
    .preferredColorScheme(.dark)
}
