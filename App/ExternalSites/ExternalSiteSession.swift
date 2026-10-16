import Foundation

/// State for "Other sites" — modeled on SiteSession (App/LibSite.swift),
/// but DELIBERATELY a separate class/file, not an extension of SiteSession:
/// LibSite (mangalib/slashlib/ranobelib/hentailib) and ExternalSite (hitomi
/// and onward) are two different, never-mixed notions of a "site" (see the
/// plan — the new code barely overlaps with the old).
///
/// `enabledSites` — which external sites are enabled at all in Settings
/// ("Other sites", see ExternalSitesSettingsView) — their list shows up in
/// the active-site switcher (see SideMenuView.siteRow).
///
/// `activeExternalSite` — nil means the regular mode (one of the LibSite
/// values is currently active, as it always was); non-nil means the app has
/// "switched" to this external site, screens check this first thing (see
/// ExternalScreenContent/the plan, Part 3) and either show their own
/// content for it, or "Unavailable". SiteSession.activeSite is NOT touched
/// in the process — it keeps its last value so it can be returned to when
/// the external mode is turned off.
@MainActor
final class ExternalSiteSession: ObservableObject {
    static let shared = ExternalSiteSession()

    @Published var enabledSites: Set<ExternalSite> {
        didSet { persistEnabled() }
    }

    @Published var activeExternalSite: ExternalSite? {
        didSet { persistActive() }
    }

    /// "All sites" — combined mode (see ExternalCombinedCatalogView):
    /// instead of ONE active external site, the catalog/feed query ALL
    /// enabled sites at once and merge the result (see
    /// ExternalCatalogGridView, support for multiple sites). Mutually
    /// exclusive with activeExternalSite — picking one always resets the
    /// other (see SideMenuView.siteRow). Screens with no catalog equivalent
    /// (Bookmarks/Reading/New) still show "Unavailable" in this mode — with
    /// a generic wording not tied to a single site (see ExternalScreenContent,
    /// site: nil).
    @Published var combinedModeActive: Bool {
        didSet { persistCombined() }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "external_site_enabled_set"
        static let active = "external_site_active"
        static let combined = "external_site_combined_active"
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
        combinedModeActive = defaults.bool(forKey: Keys.combined)
    }

    var activeProvider: (any ExternalSiteProvider)? {
        activeExternalSite.map(ExternalSiteRegistry.provider(for:))
    }

    /// External mode (single-site OR combined) is active at all — screens
    /// where this is the only thing that matters (the LibSite else-branch
    /// etc.) don't need to check both flags separately.
    var isExternalModeActive: Bool { activeExternalSite != nil || combinedModeActive }

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

    private func persistCombined() {
        defaults.set(combinedModeActive, forKey: Keys.combined)
    }
}
