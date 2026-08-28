import SwiftUI

/// "Настройки" из "..." вкладки «Уведомления» — реальный экран, ПОДТВЕРЖДЁН
/// перехватом на обе стороны (см. NotificationSettings/MangaNetworkService.
/// fetch/saveNotificationSettings, UserBookmarkFolder.notify/
/// saveBookmarkFolderNotifications). Два независимых блока с отдельными
/// "Сохранить" — на реальном сайте это тоже два разных эндпоинта
/// (`PUT /user/settings/notifications` и `PUT /bookmarks/folder/notifications`),
/// сохранение одного не трогает другой.
struct NotificationSettingsView: View {
    @State private var settings: NotificationSettings?
    @State private var folders: [UserBookmarkFolder] = []

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSavingSettings = false
    @State private var isSavingFolders = false

    /// Локальное состояние порога "старых" комментариев — отдельно от
    /// settings.disableOldCommentsNotif, чтобы при выключении тумблера не
    /// терять последний выбранный порог (снова включили — чип помнит, что
    /// было выбрано, ровно как на сайте).
    @State private var oldCommentsEnabled = false
    @State private var oldCommentsDays = 7

    private static let oldCommentsOptions: [(days: Int, title: String)] = [
        (7, "Старше недели"),
        (14, "Старше 2 недель"),
        (30, "Старше месяца"),
        (180, "Старше 6 месяцев"),
        (360, "Старше года"),
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(Theme.accent)
            } else if let loadError {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Не удалось загрузить",
                        systemImage: "wifi.slash",
                        description: Text(loadError)
                    )
                    Button("Повторить") { Task { await load() } }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        if settings != nil {
                            miscCard
                        }
                        if !folders.isEmpty {
                            foldersCard
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Настройки уведомлений")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { await load() }
    }

    // MARK: Загрузка

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let fetchedSettings = try await MangaNetworkService.shared.fetchNotificationSettings()
            var fetchedFolders: [UserBookmarkFolder] = []
            if let userId = AuthSession.shared.userId {
                fetchedFolders = try await MangaNetworkService.shared.fetchUserBookmarkFolders(userId: userId)
            }
            settings = fetchedSettings
            folders = fetchedFolders
            if case .days(let days) = fetchedSettings.disableOldCommentsNotif {
                oldCommentsEnabled = true
                oldCommentsDays = days
            } else {
                oldCommentsEnabled = false
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    // MARK: "Прочее" — PUT /user/settings/notifications

    private var miscCard: some View {
        card {
            settingsToggleRow(
                title: "Завершение тайтла из ваших списков",
                isOn: Binding(
                    get: { settings?.mediaStatusFinished ?? false },
                    set: { settings?.mediaStatusFinished = $0 }
                )
            )
            Divider().overlay(Theme.separator).padding(.leading, 16)

            settingsToggleRow(
                title: "Добавление новых Тайтлов",
                isOn: Binding(
                    get: { settings?.manga ?? false },
                    set: { settings?.manga = $0 }
                )
            )
            Divider().overlay(Theme.separator).padding(.leading, 16)

            // Поле на проводе — disableFriendsNotif ("отключить") — тумблер
            // в UI формулирует ровно наоборот ("Заявки в друзья" = хочу их
            // получать), поэтому здесь инверсия при чтении/записи.
            settingsToggleRow(
                title: "Заявки в друзья",
                isOn: Binding(
                    get: { !(settings?.disableFriendsNotif ?? false) },
                    set: { settings?.disableFriendsNotif = !$0 }
                )
            )
            Divider().overlay(Theme.separator).padding(.leading, 16)

            settingsToggleRow(
                title: "Отключить уведомления о главах с ранним доступом",
                isOn: Binding(
                    get: { settings?.disableChapterEarlyAccessNotif ?? false },
                    set: { settings?.disableChapterEarlyAccessNotif = $0 }
                )
            )
            Divider().overlay(Theme.separator).padding(.leading, 16)

            oldCommentsRow

            Divider().overlay(Theme.separator).padding(.leading, 16)

            saveButton(isSaving: isSavingSettings, action: saveSettings)
        }
    }

    private func settingsToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var oldCommentsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { oldCommentsEnabled },
                set: { newValue in
                    oldCommentsEnabled = newValue
                    settings?.disableOldCommentsNotif = newValue ? .days(oldCommentsDays) : .off
                }
            )) {
                Text("Отключить уведомления на старые комментарии").foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)

            if oldCommentsEnabled {
                Menu {
                    Picker("Порог", selection: Binding(
                        get: { oldCommentsDays },
                        set: { newValue in
                            oldCommentsDays = newValue
                            settings?.disableOldCommentsNotif = .days(newValue)
                        }
                    )) {
                        ForEach(Self.oldCommentsOptions, id: \.days) { option in
                            Text(option.title).tag(option.days)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.oldCommentsOptions.first { $0.days == oldCommentsDays }?.title ?? "Старше недели")
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: Theme.pillControlHeight)
                    .background(Theme.surface, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: "Уведомления из списков" — PUT /bookmarks/folder/notifications

    private var foldersCard: some View {
        card {
            Text("Уведомления из списков")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                folderRow(index: index, folder: folder)
                if index < folders.count - 1 {
                    Divider().overlay(Theme.separator).padding(.leading, 16)
                }
            }

            Divider().overlay(Theme.separator).padding(.leading, 16)

            saveButton(isSaving: isSavingFolders, action: saveFolders)
        }
    }

    private func folderRow(index: Int, folder: UserBookmarkFolder) -> some View {
        Button {
            folders[index].notify.toggle()
        } label: {
            HStack(spacing: 12) {
                let checked = folder.notify
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(checked ? Theme.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.separator, lineWidth: checked ? 0 : 1.5)
                    )
                    .overlay {
                        if checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.background)
                        }
                    }
                    .frame(width: 22, height: 22)

                if let color = Color(folderHex: folder.colorHex) {
                    Circle().fill(color).frame(width: 8, height: 8)
                }

                Text(folder.name)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Сохранение

    private func saveButton(isSaving: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Spacer(minLength: 0)
                if isSaving {
                    ProgressView().tint(Theme.background)
                } else {
                    Text("Сохранить").font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.background)
            .frame(height: 44)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .padding(16)
    }

    private func saveSettings() {
        guard let settings else { return }
        isSavingSettings = true
        Task {
            do {
                try await MangaNetworkService.shared.saveNotificationSettings(settings)
                DownloadsManager.shared.showBanner("Настройки уведомлений сохранены")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
            }
            isSavingSettings = false
        }
    }

    private func saveFolders() {
        isSavingFolders = true
        Task {
            do {
                try await MangaNetworkService.shared.saveBookmarkFolderNotifications(folders)
                DownloadsManager.shared.showBanner("Уведомления списков сохранены")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
            }
            isSavingFolders = false
        }
    }

    // MARK: Общие помощники

    // Радиус — эталон из PersonalizationSettingsView/раздела "Меню" (см.
    // SideMenuView.cardCornerRadius).
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Своя копия парсера hex-цвета папки (см. тот же приём в
/// UserBookmarksView — тамошний `private extension Color` не виден за
/// пределами файла).
private extension Color {
    init?(folderHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    NavigationStack { NotificationSettingsView() }
        .preferredColorScheme(.dark)
}
