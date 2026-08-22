import SwiftUI

/// Модальное окно фильтрации каталога.
struct FilterView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var constants = ConstantsStore.shared
    @State private var filter: MangaFilter
    private let onApply: (MangaFilter) -> Void

    init(initial: MangaFilter, onApply: @escaping (MangaFilter) -> Void) {
        _filter = State(initialValue: initial)
        self.onApply = onApply
    }

    // Две колонки для секций-чекбоксов.
    private let twoColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ZStack {
                // Сплошной фон — без стеклянного просвечивания.
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        multiSelectSection
                        rangesSection
                        checkboxSection("Возрастной рейтинг", constants.ageRatings, keyPath: \.ageRatings)
                        checkboxSection("Тип", constants.types, keyPath: \.types)
                        checkboxSection("Формат выпуска", constants.formats, keyPath: \.formats)
                        checkboxSection("Статус тайтла", constants.titleStatuses, keyPath: \.titleStatuses)
                        checkboxSection("Статус перевода", constants.translationStatuses, keyPath: \.translationStatuses)
                        checkboxSection("Другое", FilterCatalog.other, keyPath: \.other)
                        checkboxSection("Мои списки", FilterCatalog.myLists, keyPath: \.myLists)
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)

                VStack { Spacer(); bottomBar }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold))
                    }
                    .tint(Theme.textSecondary)
                }
            }
        }
        .tint(Theme.accent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    // MARK: 1. Диапазоны

    private var rangesSection: some View {
        section("Диапазоны") {
            rangeRow("Количество глав", from: $filter.chaptersFrom, to: $filter.chaptersTo)
            rangeRow("Год релиза", from: $filter.yearFrom, to: $filter.yearTo)
            rangeRow("Оценка", from: $filter.ratingFrom, to: $filter.ratingTo)
            rangeRow("Количество оценок", from: $filter.votesFrom, to: $filter.votesTo)
        }
    }

    private func rangeRow(_ title: String, from: Binding<String>, to: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                numberField("От", text: from)
                Text("—").foregroundStyle(Theme.textSecondary)
                numberField("До", text: to)
            }
        }
    }

    // Поля без собственного стекла — обводка/подложка теперь общая на всю секцию.
    private func numberField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textSecondary))
            .keyboardType(.numberPad)
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.surfaceElevated.opacity(0.6), in: Capsule())
            .onChange(of: text.wrappedValue) { _, newValue in
                let digits = newValue.filter(\.isNumber)
                if digits != newValue { text.wrappedValue = digits }
            }
    }

    // MARK: 2. Жанры и теги (трёхпозиционные)

    private var multiSelectSection: some View {
        VStack(spacing: 0) {
            NavigationLink {
                TriStateFilterView(title: "Жанры", options: constants.genres,
                                   selection: $filter.genres, strict: $filter.genresStrict)
            } label: {
                selectRow(title: "Жанры", selection: filter.genres)
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.separator)

            NavigationLink {
                TriStateFilterView(title: "Теги", options: constants.tags,
                                   selection: $filter.tags, strict: $filter.tagsStrict)
            } label: {
                selectRow(title: "Теги", selection: filter.tags)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func selectRow(title: String, selection: TriStateSelection) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if selection.count == 0 {
                Text("Любые").font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                if !selection.included.isEmpty {
                    countBadge(selection.included.count, color: Theme.accent, icon: "plus")
                }
                if !selection.excluded.isEmpty {
                    countBadge(selection.excluded.count, color: .red, icon: "minus")
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private func countBadge(_ n: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text("\(n)").font(.caption2.weight(.bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: 3. Трёхпозиционные чекбоксы в две колонки

    private func checkboxSection(_ title: String,
                                 _ options: [FilterOption],
                                 keyPath: WritableKeyPath<MangaFilter, TriStateSelection>) -> some View {
        section(title) {
            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 4) {
                ForEach(options) { option in
                    triCell(option, keyPath: keyPath)
                }
            }
        }
    }

    private func triCell(_ option: FilterOption,
                         keyPath: WritableKeyPath<MangaFilter, TriStateSelection>) -> some View {
        let state = filter[keyPath: keyPath].state(of: option.id)
        return Button {
            filter[keyPath: keyPath].cycle(option.id)
        } label: {
            HStack(spacing: 8) {
                triIcon(state)
                Text(option.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(fillColor(for: state), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Лёгкая цветная заливка ячейки в зависимости от трёхпозиционного состояния
    /// (не своё стекло — состояние подсвечивается прямо на общей подложке секции).
    private func fillColor(for state: TriState) -> Color {
        switch state {
        case .neutral: return .clear
        case .include: return Theme.accent.opacity(0.18)
        case .exclude: return Color.red.opacity(0.16)
        }
    }

    @ViewBuilder
    private func triIcon(_ state: TriState) -> some View {
        switch state {
        case .neutral:
            Image(systemName: "square").font(.title3).foregroundStyle(Theme.textSecondary)
        case .include:
            Image(systemName: "checkmark.square.fill").font(.title3).foregroundStyle(Theme.accent)
        case .exclude:
            Image(systemName: "minus.square.fill").font(.title3).foregroundStyle(.red)
        }
    }

    // MARK: Подвал

    // Одна общая сплошная капсула на весь подвал; "Применить" выделяется
    // акцентной заливкой поверх неё.
    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button {
                filter.reset()
            } label: {
                Text("Сбросить")
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }

            Button {
                onApply(filter)
                dismiss()
            } label: {
                Text("Применить")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: Хелпер секции

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    FilterView(initial: MangaFilter()) { _ in }
        .preferredColorScheme(.dark)
}
