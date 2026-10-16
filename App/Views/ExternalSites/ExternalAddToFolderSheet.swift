import SwiftUI

/// Лист выбора локальной папки закладок для внешних сайтов — та же
/// отложенная модель выбора, что и AddToFolderSheet (см. его doc-comment):
/// тап по папке только меняет pendingFolderId, реальное сохранение — по
/// кнопке "Применить". Отличие от AddToFolderSheet: папки полностью
/// локальные (ExternalBookmarksStore.folders, UserDefaults, без серверной
/// синхронизации — см. ExternalBookmarksStore doc-comment), нет ни
/// рейтинга, ни истории перечитываний (внешние тайтлы этого не имеют).
struct ExternalAddToFolderSheet: View {
    let site: ExternalSite
    let galleryId: Int
    let title: String
    let coverURL: String?
    let type: String

    /// Из карточки тайтла (ExternalGalleryDetailView) — есть полный detail.
    init(detail: ExternalGalleryDetail) {
        site = detail.site
        galleryId = detail.id
        title = detail.title
        coverURL = detail.coverURL?.absoluteString
        type = detail.type
    }

    /// Из списка закладок (ExternalBookmarksView) — там для смены папки
    /// уже забукмарканного тайтла есть только сама ExternalBookmark, без
    /// полного detail (страницы/теги/... не загружены и не нужны здесь).
    init(bookmark: ExternalBookmark) {
        site = bookmark.site
        galleryId = bookmark.galleryId
        title = bookmark.title
        coverURL = bookmark.coverURL
        type = bookmark.type
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ExternalBookmarksStore.shared
    @State private var newFolderName = ""
    @State private var pendingFolderId: String?
    /// nil = ещё не в закладках вообще (тап "Применить" ничего не
    /// добавляет, пока не выбрана хотя бы папка/«Все») — отличается от
    /// pendingFolderId == nil, которое означает выбранную папку «Все».
    @State private var willBookmark = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 8) {
                        allFolderRow

                        ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                            folderRow(folder)
                            if index < store.folders.count - 1 {
                                Divider().overlay(Theme.separator)
                            }
                        }

                        if store.isBookmarked(site: site, id: galleryId) {
                            Button(role: .destructive) {
                                store.remove(site: site, id: galleryId)
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
            let alreadyBookmarked = store.isBookmarked(site: site, id: galleryId)
            willBookmark = alreadyBookmarked
            pendingFolderId = alreadyBookmarked ? store.folderId(site: site, id: galleryId) : nil
        }
    }

    private func applyAndDismiss() {
        let wasBookmarked = store.isBookmarked(site: site, id: galleryId)
        if willBookmark {
            if wasBookmarked {
                // Just moving an already-saved bookmark to another folder —
                // add(site:...) falls through to move(), which never
                // touches resolveKey, so whatever it already has stays put.
                store.add(site: site, galleryId: galleryId, title: title, coverURL: coverURL, type: type, toFolder: pendingFolderId)
            } else {
                // A brand-new bookmark — read this site's resolve key (see
                // ExternalSiteProvider.resolveKey(for:)) RIGHT NOW, while
                // its cache is guaranteed populated (we're on this title's
                // own detail screen or just tapped its catalog card), so a
                // fresh open from Bookmarks later (e-hentai/simplyHentai,
                // see the protocol doc-comment) doesn't fail.
                Task {
                    let key = await ExternalSiteRegistry.provider(for: site).resolveKey(for: galleryId)
                    store.add(site: site, galleryId: galleryId, title: title, coverURL: coverURL, type: type, toFolder: pendingFolderId, resolveKey: key)
                }
            }
        } else if wasBookmarked {
            store.remove(site: site, id: galleryId)
        }
        dismiss()
    }

    /// «Все» — не настоящая папка (folderId == nil), но выбирается точно
    /// так же, как обычная строка — тот же принцип, что и selectedFolderId
    /// == nil в BookmarksView/ExternalBookmarksView.
    private var allFolderRow: some View {
        let selected = willBookmark && pendingFolderId == nil
        return Button {
            willBookmark = true
            pendingFolderId = nil
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text("Все")
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

    private func folderRow(_ folder: ExternalBookmarkFolder) -> some View {
        let selected = willBookmark && pendingFolderId == folder.id
        return Button {
            willBookmark = true
            pendingFolderId = folder.id
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
                    if let folder = store.createFolder(name: newFolderName) {
                        willBookmark = true
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
