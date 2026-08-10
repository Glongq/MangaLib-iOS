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
    @State private var newFolderName = ""
    @State private var pendingFolderId: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.opacity(0.72).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.allFolders) { folder in
                            folderRow(folder)
                        }

                        if store.isBookmarked(slug: slug) {
                            Button(role: .destructive) {
                                store.remove(slug: slug)
                                dismiss()
                            } label: {
                                Text("Убрать из закладок")
                                    .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .foregroundStyle(.red)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.top, 8)
                        }

                        createFolderRow
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Добавить в")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
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
        .presentationBackground(.ultraThinMaterial)
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
                Text(folder.name).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(store.titlesCount(in: folder.id))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

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
                        .glassEffect(isEmpty ? .regular : .regular.tint(Theme.accent).interactive(),
                                     in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isEmpty)
            }
        }
    }
}

#Preview {
    AddToFolderSheet(slug: "test", title: "Пример", coverURL: nil)
        .preferredColorScheme(.dark)
}
