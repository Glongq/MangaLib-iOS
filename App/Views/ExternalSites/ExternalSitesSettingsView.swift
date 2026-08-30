import SwiftUI

/// «Другие сайты» — раздел настроек (Настройки → Приложение, внизу
/// списка, по прямой просьбе). Простой список Toggle по ExternalSite.
/// allCases — включённые сайты появляются в переключателе активного сайта
/// (см. SideMenuView.siteRow) рядом с MangaLib/SlashLib/...
///
/// Стиль — 1-в-1 SpecialFilterSettingsView (та же карточка-объяснение +
/// карточка со строками-переключателями), копипастой, не общим
/// компонентом — по прямой просьбе минимально пересекаться со старым кодом.
struct ExternalSitesSettingsView: View {

    @ObservedObject private var session = ExternalSiteSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    explanationCard
                    sitesCard
                }
                .padding(16)
            }
        }
        .navigationTitle("Другие сайты")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Что это")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Это сайты с совсем другим API, не из экосистемы MangaLib — у них нет общего аккаунта с этим приложением, поэтому недоступны Закладки/История/Уведомления/Комментарии. Включите нужный сайт здесь, затем выберите его в переключателе сайта (там же, где обычно переключаете MangaLib/SlashLib/…) — вкладки останутся те же, просто покажут то, что есть у выбранного сайта. Если включено несколько сайтов сразу, там же появляется пункт «Все сайты» — совместный каталог и поиск сразу по всем включённым, карточка каждого тайтла подписана, с какого именно сайта он пришёл.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sitesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(ExternalSite.allCases.enumerated()), id: \.element) { index, site in
                siteRow(site)
                if index != ExternalSite.allCases.count - 1 {
                    Divider().overlay(Theme.separator).padding(.horizontal, 16)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func siteRow(_ site: ExternalSite) -> some View {
        HStack {
            Text(site.displayName)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { session.enabledSites.contains(site) },
                set: { isOn in
                    if isOn { session.enabledSites.insert(site) } else {
                        session.enabledSites.remove(site)
                        // Выключили сайт, который был активным — возвращаемся
                        // в обычный режим (тот же принцип, что и было бы,
                        // если бы сайт вообще пропал из списка выбора).
                        if session.activeExternalSite == site { session.activeExternalSite = nil }
                        // Совместный режим («Все сайты») без включённых
                        // сайтов вообще не имеет смысла — иначе он тихо
                        // остался бы висеть активным, показывая пустой каталог.
                        if session.enabledSites.isEmpty { session.combinedModeActive = false }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

#Preview {
    NavigationStack {
        ExternalSitesSettingsView()
    }
    .preferredColorScheme(.dark)
}
