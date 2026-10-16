import Foundation

/// Search pages and native URLs share one semantic arm instead of fragmenting its evidence.
struct RecommendationChannel: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case singleTag, tagPair, author, catalog, popular }
    var kind: Kind
    var interestID: String = "global"
    var id: String { "\(kind.rawValue)|\(interestID)" }
    var isExploratory: Bool { kind == .catalog || kind == .popular }
}

struct RecommendationOrigin: Codable, Hashable, Sendable {
    let queryID: String
    let siteID: String
    let depth: ExternalRecommendationDepth
    let channel: RecommendationChannel
    var samplesCorpus = false
}

struct RecommendationSelection: Sendable {
    let document: ExternalRecommendationDocument
    let origin: RecommendationOrigin?
}

/// One actual visit; repeated flushes replace the facts belonging to this ID.
struct RecommendationExposure: Codable, Sendable {
    let id: UUID
    let document: ExternalRecommendationDocument
    let origin: RecommendationOrigin
    let shownAt: Date
    var seconds: Double
    var pages: Int
    var imageLoaded: Bool

    var qualityReading: Bool {
        Self.qualityReading(seconds: seconds, pages: pages, total: document.pageCount)
    }

    static func qualityReading(seconds: Double, pages: Int, total: Int) -> Bool {
        seconds >= 10 && total > 0 && (pages >= 3 || Double(pages) / Double(total) >= 0.2)
    }
}

struct RecommendationInterest: Codable, Sendable {
    let id: String
    let center: [String: Double]
    let features: [ExternalRecommendationFeature]
}

struct LearningSnapshot: Codable, Sendable {
    static let algorithmVersion = 1
    var formatVersion = 1
    var corpus: [String: [ExternalRecommendationDocument]] = [:]
    var exposures: [RecommendationExposure] = []
    var interests: [RecommendationInterest] = []
}

/// Bounded neutral samples and presentation facts live separately from durable user preferences.
@MainActor
final class ExternalRecommendationLearningStore {
    private(set) var snapshot: LearningSnapshot
    private(set) var revision = 0
    private let defaults: UserDefaults
    private static let storageKey = "external_recommendation_learning_v1"
    private var saveTask: Task<Void, Never>?
    private var latestVisits: [String: RecommendationExposure] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(LearningSnapshot.self, from: $0) }
            .flatMap { $0.formatVersion == 1 ? $0 : nil } ?? LearningSnapshot()
    }

    func sample(_ document: ExternalRecommendationDocument, now: Date = Date()) {
        let bucket = "\(document.siteID)|\(ExternalRecommendationPeriod.of(document.publishedAt, at: now).rawValue)"
        var documents = snapshot.corpus[bucket] ?? []
        guard !documents.contains(where: { $0.id == document.id }) else { return }
        documents.append(document)
        documents.sort {
            let left = RecommendationMath.hash($0.id), right = RecommendationMath.hash($1.id)
            return left == right ? $0.id < $1.id : left < right
        }
        documents = Array(documents.prefix(64))
        guard documents.contains(where: { $0.id == document.id }) else { return }
        snapshot.corpus[bucket] = documents
        changed()
    }

    func record(_ exposure: RecommendationExposure, explicit: Bool) {
        guard exposure.imageLoaded, exposure.seconds.isFinite, exposure.seconds >= 0, exposure.pages >= 0 else { return }
        if var previous = latestVisits[exposure.document.id], previous.id == exposure.id {
            previous.seconds = max(previous.seconds, exposure.seconds)
            previous.pages = max(previous.pages, exposure.pages)
            latestVisits[exposure.document.id] = previous
        } else if latestVisits[exposure.document.id].map({ $0.shownAt <= exposure.shownAt }) ?? true {
            latestVisits[exposure.document.id] = exposure
        }
        if latestVisits.count > 32 {
            latestVisits = Dictionary(uniqueKeysWithValues: latestVisits.values.sorted { $0.shownAt > $1.shownAt }
                .prefix(32).map { ($0.document.id, $0) })
        }
        guard exposure.seconds >= 2 || explicit else { return }
        if let index = snapshot.exposures.firstIndex(where: { $0.id == exposure.id }) {
            var merged = snapshot.exposures[index]
            merged.seconds = max(merged.seconds, exposure.seconds)
            merged.pages = max(merged.pages, exposure.pages)
            guard merged.seconds != snapshot.exposures[index].seconds || merged.pages != snapshot.exposures[index].pages else { return }
            snapshot.exposures[index] = merged
        } else {
            snapshot.exposures.append(exposure)
        }
        snapshot.exposures.sort { $0.shownAt == $1.shownAt ? $0.id.uuidString < $1.id.uuidString : $0.shownAt > $1.shownAt }
        snapshot.exposures = Array(snapshot.exposures.prefix(2_000))
        changed()
    }

    func qualifyExplicit(_ document: ExternalRecommendationDocument) {
        if let visit = latestVisits[document.id] { record(visit, explicit: true) }
    }

    /// Cluster IDs are derived state; accepting them must not invalidate their own calculation.
    func accept(_ interests: [RecommendationInterest]) {
        guard interests.map(\.id) != snapshot.interests.map(\.id)
            || interests.map(\.center) != snapshot.interests.map(\.center) else { return }
        snapshot.interests = interests
        scheduleSave()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.storageKey) }
    }

    private func changed() {
        revision &+= 1
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

enum RecommendationMath {
    static func hash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    static func unit(_ vector: [String: Double]) -> [String: Double] {
        let norm = sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.mapValues { $0 / norm } : [:]
    }

    static func dot(_ left: [String: Double], _ right: [String: Double]) -> Double {
        left.reduce(0) { $0 + $1.value * (right[$1.key] ?? 0) }
    }
}

struct RecommendationPosterior: Sendable {
    var alpha = 2.0
    var beta = 2.0
    var variance: Double { alpha * beta / (pow(alpha + beta, 2) * (alpha + beta + 1)) }
}

/// Small reproducible random stream: a queue rebuild with the same facts keeps its choices.
struct RecommendationRandom {
    var state: UInt64

    mutating func uniform() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return (Double(value >> 11) + 0.5) / 9_007_199_254_740_992
    }

    private mutating func gamma(_ shape: Double) -> Double {
        let d = shape - 1 / 3.0
        let c = 1 / sqrt(9 * d)
        while true {
            let x = sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())
            let root = 1 + c * x
            guard root > 0 else { continue }
            let v = root * root * root
            let u = uniform()
            if u < 1 - 0.0331 * pow(x, 4) || log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    mutating func beta(_ posterior: RecommendationPosterior) -> Double {
        let a = gamma(posterior.alpha), b = gamma(posterior.beta)
        return a / (a + b)
    }
}

struct RecommendationChannelPolicy: Sendable {
    var posteriors: [String: RecommendationPosterior] = [:]
    var explorationProbability: Double = 0.2

    init() {}

    init(snapshot: LearningSnapshot, profile: ExternalRecommendationProfile, now: Date) {
        // A current explicit fact belongs to the most recent loaded visit, not to every copy or revisit.
        let facts = Dictionary(grouping: profile.feedback.values, by: { $0.document.duplicateKey })
            .compactMapValues { ExternalRecommendationFeedback.currentExplicit(in: $0) }
        let ordered = snapshot.exposures.sorted { $0.shownAt == $1.shownAt ? $0.id.uuidString > $1.id.uuidString : $0.shownAt > $1.shownAt }
        var explicitAssigned = Set<String>()
        var readingAssigned = Set<String>()
        for event in ordered where event.imageLoaded {
            let duplicate = event.document.duplicateKey
            let fact = facts[duplicate]
            let decay = pow(0.5, max(0, now.timeIntervalSince(event.shownAt)) / (30 * 86_400))
            var success = 0.0, failure = 0.0
            // A later revisit cannot renew or steal the reward of an earlier explicit action.
            let explicitDate = fact.map { $0.vote != nil ? ($0.voteUpdatedAt ?? $0.updatedAt) : $0.updatedAt }
            if let fact, let explicitDate, event.shownAt <= explicitDate,
               explicitAssigned.insert(duplicate).inserted {
                if fact.vote == .dislike { failure = 1 } else { success = 1 }
            } else if fact == nil && event.qualityReading && readingAssigned.insert(duplicate).inserted {
                success = 0.2
            } else if event.seconds >= 2 && !event.qualityReading && fact == nil {
                failure = 0.1
            }
            var posterior = posteriors[event.origin.channel.id] ?? RecommendationPosterior()
            posterior.alpha += success * decay
            posterior.beta += failure * decay
            posteriors[event.origin.channel.id] = posterior
        }
        let variance = posteriors.isEmpty ? 0.05 : posteriors.values.reduce(0) { $0 + $1.variance } / Double(posteriors.count)
        explorationProbability = 0.05 + 0.15 * min(1, max(0, variance / 0.05))
    }

    func choose(_ channels: [RecommendationChannel], random: inout RecommendationRandom,
                forceCatalog: Bool = false) -> RecommendationChannel? {
        let unique = Array(Set(channels)).sorted { $0.id < $1.id }
        guard !unique.isEmpty else { return nil }
        let explore = forceCatalog || random.uniform() < explorationProbability
        let preferred = unique.filter { $0.isExploratory == explore }
        let available = preferred.isEmpty ? unique : preferred
        var best: RecommendationChannel?
        var bestSample = -Double.infinity
        for channel in available {
            let sample = random.beta(posteriors[channel.id] ?? RecommendationPosterior())
            if sample > bestSample { best = channel; bestSample = sample }
        }
        return best
    }
}
