import SwiftUI

/// Лист выбора папки закладок с возможностью создать новую.
///
/// Модель выбора — ОТЛОЖЕННАЯ: тап по папке только меняет локальный
/// pendingFolderId (визуально выделяет её), реальное изменение на сервере и
/// закрытие листа происходит только по кнопке "Применить" — как попросили.
/// Повторный тап по УЖЕ выбранной папке снимает выбор (pendingFolderId =
/// nil) — тогда "Применить" уберёт тайтл из закладок целиком. Единственное
/// исключение — кнопка "Убрать из закладок" ниже: она как и раньше действует
/// сразу, без промежуточного шага.
struct AddToFolderSheet: View {

    let slug: String
    let title: String
    let coverURL: String?
    /// Оценка тайтла — прокидывается в store.add(), чтобы бэйдж оценки (см.
    /// RatingChip) сразу был на месте в закладках, без ожидания следующего
    /// syncFromServer(). Опционален с дефолтом nil — старые вызовы без этого
    /// параметра продолжают компилироваться без изменений.
    var rating: Double? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BookmarksStore.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var newFolderName = ""
    @State private var pendingFolderId: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(store.allFolders.enumerated()), id: \.element.id) { index, folder in
                            folderRow(folder)
                            if index < store.allFolders.count - 1 {
                                Divider().overlay(Theme.separator)
                            }
                        }

                        if store.isBookmarked(slug: slug) {
                            // "Прочитано N раз" — ПОДТВЕРЖДЕНО перехватом
                            // (meta.rewatches_history, см. RewatchHistorySheet/
                            // BookmarksStore.startRewatch). NavigationLink, не
                            // .sheet — этот лист уже сам в NavigationStack.
                            NavigationLink {
                                RewatchHistorySheet(slug: slug, title: title)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundStyle(Theme.textSecondary)
                                    Text("Прочитано \(store.rewatchCount(forSlug: slug)) раз")
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 48)
                            }
                            .padding(.top, 8)

                            Button(role: .destructive) {
                                store.remove(slug: slug)
                                dismiss()
                            } label: {
                                Text("Убрать из закладок")
                                    .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .foregroundStyle(.red)
                            .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.top, 8)
                        }

                        createFolderRow
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Добавить в")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Применить") { applyAndDismiss() }
                        .tint(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .onAppear {
            // Стартовое состояние — реальная папка тайтла на момент открытия
            // (или nil, если тайтла ещё нет в закладках).
            pendingFolderId = store.folderId(forSlug: slug)
        }
    }

    /// Коммитит pendingFolderId: nil → убрать из закладок, иначе → add/move.
    /// Ничего не делает (просто закрывает лист), если pendingFolderId не
    /// отличается от того, что уже реально сохранено.
    private func applyAndDismiss() {
        let actual = store.folderId(forSlug: slug)
        if pendingFolderId != actual {
            if let pendingFolderId {
                store.add(slug: slug, title: title, coverURL: coverURL, rating: rating, toFolder: pendingFolderId)
            } else {
                store.remove(slug: slug)
            }
        }
        dismiss()
    }

    private func folderRow(_ folder: BookmarkFolder) -> some View {
        let selected = pendingFolderId == folder.id
        return Button {
            // Повторный тап по уже выбранной папке — снимает выбор (тайтл
            // будет убран из закладок при нажатии "Применить").
            pendingFolderId = selected ? nil : folder.id
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(folder.name)
                    .font(.system(size: 17 * 1.2))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(selected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var createFolderRow: some View {
        VStack(spacing: 8) {
            Divider().overlay(Theme.separator).padding(.vertical, 4)
            HStack(spacing: 8) {
                TextField("", text: $newFolderName,
                          prompt: Text("Создать новую папку").foregroundColor(Theme.textSecondary))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Theme.surfaceElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                let isEmpty = newFolderName.trimmingCharacters(in: .whitespaces).isEmpty
                Button {
                    // Создаём папку и только ВЫБИРАЕМ её (pending) — как и
                    // остальные папки, реально сохранится по "Применить".
                    if let folder = store.createFolder(name: newFolderName) {
                        pendingFolderId = folder.id
                        newFolderName = ""
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(isEmpty ? Theme.textSecondary : Theme.background)
                        .frame(width: 44, height: 44)
                        .background(isEmpty ? Theme.surfaceElevated.opacity(0.6) : Theme.accent,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isEmpty)
            }
        }
    }
}

/// "История чтения" — 1-в-1 с реальным сайтом по прямой просьбе: "#N
/// прочтение" / "Начато: ..." / "Завершено: ...". ПОДТВЕРЖДЕНО перехватом:
/// `meta.rewatches_history` в теле `POST /bookmarks` (тот же запрос, что и
/// смена папки, ВСЕГДА весь массив целиком — нет отдельного эндпоинта
/// редактирования/удаления ОДНОЙ записи) — массив периодов `{start,end}`,
/// `end == nil` — период ещё не закрыт ("сейчас перечитывает"). Даты не
/// могут быть позже сегодняшней, а "Завершено" не может быть раньше
/// "Начато" — ПОДТВЕРЖДЕНО перехватом (422: `«Дата окончания» должна быть
/// дата после или равняться «Дата начала»`) — оба ограничения зашиты прямо
/// в диапазон DatePicker (см. DateEditSheet), выбрать невалидную дату
/// физически нельзя. См. BookmarksStore.startRewatch/updateRewatchPeriod/
/// deleteRewatchPeriod.
struct RewatchHistorySheet: View {
    let slug: String
    let title: String

    @ObservedObject private var store = BookmarksStore.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var editingField: EditingDateField?

    private var history: [RewatchPeriod] {
        store.items.first { $0.slug == slug }?.rewatchHistory ?? []
    }
    private var hasOpenPeriod: Bool { history.contains { $0.end == nil } }

    private enum EditingDateField: Identifiable {
        case start(index: Int)
        case end(index: Int)

        var id: String {
            switch self {
            case .start(let index): return "start-\(index)"
            case .end(let index): return "end-\(index)"
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if history.isEmpty {
                // Была "arrow.clockwise" (иконка "повторить"/retry) — для
                // пустой ИСТОРИИ перечитываний не по смыслу, заменена на ту
                // же иконку, что и у "История" в приложении.
                StateView(icon: "clock.arrow.circlepath", title: "Пока не отмечено", description: "«\(title)» ещё не перечитывался.", fillScreen: true)
            } else {
                List {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, period in
                        periodRow(index: index, period: period)
                            .listRowBackground(Theme.surface)
                    }
                    .onDelete { offsets in store.deleteRewatchPeriod(forSlug: slug, at: offsets) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("История чтения")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Новое прочтение — no-op, если уже есть незакрытое (см.
            // BookmarksStore.startRewatch), поэтому просто прячем кнопку
            // вместо "тапнул — ничего не произошло".
            if !hasOpenPeriod {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.startRewatch(forSlug: slug) } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingField) { field in
            dateEditSheet(for: field)
                .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
        }
    }

    private func periodRow(index: Int, period: RewatchPeriod) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("#\(index + 1) прочтение")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Button { editingField = .start(index: index) } label: {
                dateFieldRow(label: "Начато:", value: formatted(period.start), isPlaceholder: false)
            }
            .buttonStyle(.plain)

            Button { editingField = .end(index: index) } label: {
                dateFieldRow(
                    label: "Завершено:",
                    value: period.end.map(formatted) ?? "ещё читает",
                    isPlaceholder: period.end == nil
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func dateFieldRow(label: String, value: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Text(value).foregroundStyle(isPlaceholder ? Theme.textSecondary : Theme.accent)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func dateEditSheet(for field: EditingDateField) -> some View {
        switch field {
        case .start(let index) where history.indices.contains(index):
            let period = history[index]
            DateEditSheet(
                title: "Начато",
                initialDate: isoDate(period.start) ?? Date(),
                // Позже "Завершено" (если оно уже стоит) поставить
                // нельзя — тот же 422 с сайта ("Дата окончания" ПОСЛЕ ИЛИ
                // РАВНА "Дата начала"), тут просто недостижимо через UI.
                maxDate: min(Date(), isoDate(period.end) ?? Date()),
                allowsClear: false
            ) { newDate in
                guard let newDate else { return }
                store.updateRewatchPeriod(forSlug: slug, at: index, start: dateString(newDate), end: period.end)
            }
        case .end(let index) where history.indices.contains(index):
            let period = history[index]
            DateEditSheet(
                title: "Завершено",
                initialDate: isoDate(period.end) ?? Date(),
                minDate: isoDate(period.start),
                maxDate: Date(),
                allowsClear: true
            ) { newDate in
                store.updateRewatchPeriod(forSlug: slug, at: index, start: period.start, end: newDate.map(dateString))
            }
        default:
            EmptyView()
        }
    }

    /// Даты приходят/уходят как "yyyy-MM-dd" (см. RewatchPeriod) — показываем
    /// более читаемо (напр. "28 авг 2026"), с фолбэком на сырую строку, если
    /// формат вдруг не совпал.
    private func formatted(_ raw: String) -> String {
        guard let date = isoDate(raw) else { return raw }
        return Self.displayFormatter.string(from: date)
    }

    private func isoDate(_ raw: String?) -> Date? {
        raw.flatMap { BookmarksStore.rewatchDateFormatter.date(from: $0) }
    }

    private func dateString(_ date: Date) -> String {
        BookmarksStore.rewatchDateFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter
    }()
}

/// Правка одной даты (Начато/Завершено, см. RewatchHistorySheet) — сам
/// DatePicker ограничен диапазоном [minDate...maxDate], так что выбрать
/// дату позже сегодня или "Завершено" раньше "Начато" физически нельзя
/// (ПОДТВЕРЖДЕНО перехватом — та же пара ограничений, что и на сайте).
/// `allowsClear` — только у "Завершено": можно вернуть период в
/// "незакрытое" состояние ("ещё читает").
private struct DateEditSheet: View {
    let title: String
    let initialDate: Date
    var minDate: Date? = nil
    let maxDate: Date
    let allowsClear: Bool
    var onSave: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(title: String, initialDate: Date, minDate: Date? = nil, maxDate: Date, allowsClear: Bool, onSave: @escaping (Date?) -> Void) {
        self.title = title
        self.initialDate = initialDate
        self.minDate = minDate
        self.maxDate = maxDate
        self.allowsClear = allowsClear
        self.onSave = onSave
        _date = State(initialValue: min(max(initialDate, minDate ?? .distantPast), maxDate))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker(title, selection: $date, in: (minDate ?? .distantPast)...maxDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)

                if allowsClear {
                    Button("Отметить «ещё читает»") {
                        onSave(nil)
                        dismiss()
                    }
                    .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        onSave(date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    AddToFolderSheet(slug: "test", title: "Пример", coverURL: nil)
        .preferredColorScheme(.dark)
}
