import Foundation

/// Состояние «Других сайтов» — по образцу SiteSession (App/LibSite.swift),
/// но НАМЕРЕННО отдельный класс/файл, не расширение SiteSession: LibSite
/// (mangalib/slashlib/ranobelib/hentailib) и ExternalSite (hitomi и далее) —
/// два разных, не смешиваемых понятия "сайта" (см. план — новый код почти
/// не пересекается со старым).
///
/// `enabledSites` — какие внешние сайты вообще включены в Настройках
/// («Другие сайты», см. ExternalSitesSettingsView) — их список появляется
/// в переключателе активного сайта (см. SideMenuView.siteRow).
///
/// `activeExternalSite` — nil означает обычный режим (сейчас активен один
/// из LibSite, как и было всегда); non-nil — приложение "переключено" на
/// этот внешний сайт, экраны проверяют это первым делом (см.
/// ExternalScreenContent/план, Часть 3) и либо показывают свой контент для
/// него, либо «Недоступно». SiteSession.activeSite при этом НЕ трогается —
/// сохраняет своё последнее значение, чтобы вернуться к нему при выключении
/// внешнего режима.
@MainActor
final class ExternalSiteSession: ObservableObject {
    static let shared = ExternalSiteSession()

    @Published var enabledSites: Set<ExternalSite> {
        didSet { persistEnabled() }
    }

    @Published var activeExternalSite: ExternalSite? {
        didSet { persistActive() }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "external_site_enabled_set"
        static let active = "external_site_active"
    }

    private init() {
        if let raws = defaults.array(forKey: Keys.enabled) as? [String] {
            enabledSites = Set(raws.compactMap(ExternalSite.init(rawValue:)))
        } else {
            enabledSites = []
        }
        if let raw = defaults.string(forKey: Keys.active), let site = ExternalSite(rawValue: raw) {
            activeExternalSite = site
        } else {
            activeExternalSite = nil
        }
    }

    var activeProvider: (any ExternalSiteProvider)? {
        activeExternalSite.map(ExternalSiteRegistry.provider(for:))
    }

    private func persistEnabled() {
        defaults.set(enabledSites.map(\.rawValue), forKey: Keys.enabled)
    }

    private func persistActive() {
        if let activeExternalSite {
            defaults.set(activeExternalSite.rawValue, forKey: Keys.active)
        } else {
            defaults.removeObject(forKey: Keys.active)
        }
    }
}
