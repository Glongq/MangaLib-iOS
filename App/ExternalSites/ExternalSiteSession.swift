import Foundation

/// External source selection stays separate from the Lib ecosystem's account and site.
/// Settings switches choose participating sources; contentKind selects manga or video.
/// Legacy single-site state is migrated to combined mode without losing preferences.
@MainActor
final class ExternalSiteSession: ObservableObject {
    static let shared = ExternalSiteSession()

    @Published var enabledSites: Set<ExternalSite> {
        didSet { persistEnabled() }
    }

    @Published var contentKind: ExternalContentKind {
        didSet {
            defaults.set(contentKind.rawValue, forKey: Keys.contentKind)
            activateConfiguredSites()
        }
    }

    @Published var activeExternalSite: ExternalSite? {
        didSet { persistActive() }
    }

    /// Catalog and feed query selectedSites together, including a single enabled source.
    /// Choosing a Lib site leaves external mode while retaining source preferences.
    @Published var combinedModeActive: Bool {
        didSet { persistCombined() }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let enabled = "external_site_enabled_set"
        static let active = "external_site_active"
        static let combined = "external_site_combined_active"
        static let contentKind = "external_site_content_kind"
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
        contentKind = defaults.string(forKey: Keys.contentKind)
            .flatMap(ExternalContentKind.init(rawValue:)) ?? .manga
        // Migrate the old single-site route into the enabled-source selection.
        if let activeExternalSite { enabledSites.insert(activeExternalSite) }
        if activeExternalSite != nil || combinedModeActive { activateConfiguredSites() }
    }

    /// Every enabled source of the selected media kind participates together.
    var selectedSites: [ExternalSite] {
        ExternalSite.allCases.filter { enabledSites.contains($0) && $0.contentKind == contentKind }
    }

    func setEnabled(_ enabled: Bool, for site: ExternalSite) {
        if enabled { enabledSites.insert(site) }
        else { enabledSites.remove(site) }
        if enabled && selectedSites.isEmpty { contentKind = site.contentKind }
        activateConfiguredSites()
    }

    private func activateConfiguredSites() {
        activeExternalSite = nil
        combinedModeActive = !enabledSites.isEmpty
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
