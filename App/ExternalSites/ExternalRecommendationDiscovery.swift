import Foundation

struct ExternalRecommendationDiscoveryState: Codable {
    var cursor: String?
    var exhausted = false
    var failedAt: Date?
    var fetchedAt: Date?
    var pagesInWindow = 0
    var round = 0
    var upperPage: Int?
    var probeUpdatedAt: Date?
    var refreshedAt: Date?
    var windowDate: Date?

    mutating func refresh(for depth: ExternalRecommendationDepth, now: Date) {
        if let probeUpdatedAt, now.timeIntervalSince(probeUpdatedAt) > 7 * 86_400 { upperPage = nil }
        guard let fetchedAt else { return }
        if depth == .latest || depth == .popular {
            if now.timeIntervalSince(refreshedAt ?? fetchedAt) > 6 * 3_600 {
                cursor = nil
                exhausted = false
                pagesInWindow = 0
                refreshedAt = now
            }
        }
    }
}

struct ExternalRecommendationSavedCandidate: Codable {
    let site: ExternalSite
    let galleryID: Int
    var resolveKey: String?
    var origins: [RecommendationOrigin]? = nil
    var item: ExternalCatalogItem { .init(site: site, galleryId: galleryID) }
}

struct ExternalRecommendationDiscoverySnapshot: Codable {
    var lanes: [String: ExternalRecommendationDiscoveryState] = [:]
    var pending: [ExternalRecommendationSavedCandidate] = []
    var rotation = 0
    var updatedAt = Date()
}

/// Only opaque cursors and unconsumed IDs are persisted; no pages, images or background crawler.
@MainActor
final class ExternalRecommendationDiscoveryStore {
    private let defaults: UserDefaults
    private static let storageKey = "external_recommendation_discovery_v1"
    private var snapshots: [String: ExternalRecommendationDiscoverySnapshot]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshots = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: ExternalRecommendationDiscoverySnapshot].self, from: $0) } ?? [:]
    }

    func load(scope: String, now: Date = Date()) -> ExternalRecommendationDiscoverySnapshot {
        guard let snapshot = snapshots[scope], now.timeIntervalSince(snapshot.updatedAt) < 90 * 86_400 else { return .init() }
        return snapshot
    }

    func save(_ snapshot: ExternalRecommendationDiscoverySnapshot, scope: String) {
        var bounded = snapshot
        let lanes = bounded.lanes.sorted { ($0.value.fetchedAt ?? .distantPast) > ($1.value.fetchedAt ?? .distantPast) }
        bounded.lanes = Dictionary(uniqueKeysWithValues: lanes.prefix(160).map { ($0.key, $0.value) })
        bounded.pending = Array(bounded.pending.prefix(360))
        bounded.updatedAt = Date()
        snapshots[scope] = bounded
        let scopes = snapshots.sorted { $0.value.updatedAt > $1.value.updatedAt }
        snapshots = Dictionary(uniqueKeysWithValues: scopes.prefix(12).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(snapshots) { defaults.set(data, forKey: Self.storageKey) }
    }
}
