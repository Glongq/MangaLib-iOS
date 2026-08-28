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

/// "Прочитано N раз" — история перечитываний тайтла (см.
/// AddToFolderSheet — строка-вход выше). ПОДТВЕРЖДЕНО перехватом:
/// `meta.rewatches_history` в теле `POST /bookmarks` (тот же запрос, что и
/// смена папки) — массив периодов `{start,end}`, `end == nil` — период ещё
/// не закрыт ("сейчас перечитывает"). См. BookmarksStore.startRewatch/
/// finishRewatch/deleteRewatchPeriod.
struct RewatchHistorySheet: View {
    let slug: String
    let title: String

    @ObservedObject private var store = BookmarksStore.shared

    private var history: [RewatchPeriod] {
        store.items.first { $0.slug == slug }?.rewatchHistory ?? []
    }
    private var hasOpenPeriod: Bool { history.contains { $0.end == nil } }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if history.isEmpty {
                ContentUnavailableView(
                    "Пока не отмечено",
                    systemImage: "arrow.clockwise",
                    description: Text("«\(title)» ещё не перечитывался.")
                )
            } else {
                List {
                    ForEach(history) { period in
                        periodRow(period)
                            .listRowBackground(Theme.surface)
                    }
                    .onDelete { offsets in store.deleteRewatchPeriod(forSlug: slug, at: offsets) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Прочитано \(history.count) раз")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasOpenPeriod {
                    Button("Завершить") { store.finishRewatch(forSlug: slug) }
                } else {
                    Button("Начать ещё раз") { store.startRewatch(forSlug: slug) }
                }
            }
        }
    }

    private func periodRow(_ period: RewatchPeriod) -> some View {
        HStack(spacing: 12) {
            Image(systemName: period.end == nil ? "book.fill" : "checkmark.circle")
                .foregroundStyle(period.end == nil ? Theme.accent : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(formatted(period.start))
                    .foregroundStyle(Theme.textPrimary)
                Text(period.end.map { "по \(formatted($0))" } ?? "сейчас читает")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Даты приходят/уходят как "yyyy-MM-dd" (см. RewatchPeriod) — показываем
    /// более читаемо (напр. "28 авг 2026"), с фолбэком на сырую строку, если
    /// формат вдруг не совпал.
    private func formatted(_ raw: String) -> String {
        guard let date = Self.isoFormatter.date(from: raw) else { return raw }
        return Self.displayFormatter.string(from: date)
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter
    }()
}

#Preview {
    AddToFolderSheet(slug: "test", title: "Пример", coverURL: nil)
        .preferredColorScheme(.dark)
}
