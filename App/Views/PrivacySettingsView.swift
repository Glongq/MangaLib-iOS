import SwiftUI

/// "Приватность" (Меню → Настройки → Профиль → Приватность) — реальный
/// экран вместо StubView, 1-в-1 присланный скриншот реального сайта.
/// ПОДТВЕРЖДЕНО перехватом на обе стороны (см. PrivacySettings/
/// MangaNetworkService.fetch/savePrivacySettings) — тот же паттерн, что и у
/// NotificationSettingsView (полная загрузка объекта + единый "Сохранить",
/// full-object PUT).
struct PrivacySettingsView: View {
    @State private var settings: PrivacySettings?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false

    private struct SiteChipInfo: Identifiable {
        let id: Int
        let letter: String
        let color: Color
    }
    /// id 1-4 — те же реальные site_id, что и у LibSite (см. её комментарий:
    /// 1=MangaLib/2=SlashLib/3=RanobeLib/4=HentaiLib). id 5 — АнимеЛиб,
    /// которого в LibSite этого приложения принципиально нет (см.
    /// SideMenuView.searchSitesBlock), но он реально присутствует в
    /// statistics_site_ids перехвата — чип для него есть, просто не завязан
    /// на LibSite.
    private static let siteChips: [SiteChipInfo] = [
        .init(id: 1, letter: "M", color: .orange),
        .init(id: 2, letter: "S", color: .pink),
        .init(id: 3, letter: "R", color: .blue),
        .init(id: 4, letter: "H", color: .red),
        .init(id: 5, letter: "A", color: .purple)
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
            } else if settings != nil {
                ScrollView {
                    VStack(spacing: 20) {
                        visibilityCard(
                            title: "Отображение профиля",
                            options: PrivacyVisibilityOptions.profile,
                            selection: Binding(
                                get: { settings?.profileVisibility ?? 0 },
                                set: { settings?.profileVisibility = $0 }
                            )
                        )
                        statisticsCard
                        visibilityCard(
                            title: "Отображение старых никнеймов",
                            options: PrivacyVisibilityOptions.previousUsernames,
                            selection: Binding(
                                get: { settings?.previousUsernamesVisibility ?? 0 },
                                set: { settings?.previousUsernamesVisibility = $0 }
                            )
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Приватность")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { saveButton }
        }
        .tint(Theme.accent)
        .task { await load() }
    }

    // MARK: Загрузка/сохранение

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            settings = try await MangaNetworkService.shared.fetchPrivacySettings()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private var saveButton: some View {
        Button {
            saveSettings()
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(Theme.background)
                } else {
                    Text("Сохранить").font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSaving || settings == nil)
    }

    private func saveSettings() {
        guard let settings else { return }
        isSaving = true
        Task {
            do {
                try await MangaNetworkService.shared.savePrivacySettings(settings)
                DownloadsManager.shared.showBanner("Настройки приватности сохранены")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
            }
            isSaving = false
        }
    }

    // MARK: Карточки

    private func visibilityCard(title: String, options: [(id: Int, label: String)], selection: Binding<Int>) -> some View {
        card {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            dropdown(options: options, selection: selection)
        }
    }

    private var statisticsCard: some View {
        card {
            Text("Отображение статистики в профиле")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            dropdown(
                options: PrivacyVisibilityOptions.statistics,
                selection: Binding(
                    get: { settings?.statisticsVisibility ?? 0 },
                    set: { settings?.statisticsVisibility = $0 }
                )
            )

            Text("Отображение сайтов в статистике:")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)

            HStack(spacing: 10) {
                ForEach(Self.siteChips) { chip in
                    siteChip(chip)
                }
            }
        }
    }

    private func dropdown(options: [(id: Int, label: String)], selection: Binding<Int>) -> some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.id == selection.wrappedValue }?.label ?? "")
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Тап переключает сайт в statistics_site_ids (добавить/убрать) —
    /// зелёная галка в углу показывает "включён", цвет чипа держится даже
    /// когда выключен (просто без обводки/галки), как на скриншоте (H без
    /// галки, остальные — с).
    private func siteChip(_ chip: SiteChipInfo) -> some View {
        let isOn = settings?.statisticsSiteIds.contains(chip.id) ?? false
        return Button {
            guard settings != nil else { return }
            if isOn {
                settings?.statisticsSiteIds.removeAll { $0 == chip.id }
            } else {
                settings?.statisticsSiteIds.append(chip.id)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(chip.color.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isOn ? chip.color : Theme.separator, lineWidth: isOn ? 1.5 : 1)
                    )
                Text(chip.letter)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(chip.color)
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .background(Circle().fill(Theme.surface))
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    NavigationStack { PrivacySettingsView() }.preferredColorScheme(.dark)
}
