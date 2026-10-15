import Foundation

/// A namespaced interest. Creator identities stay scoped to their source site.
struct ExternalRecommendationFeature: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case tag, female, male, artist, group, character, series, format

        var weight: Double {
            switch self {
            case .artist: return 2
            case .tag, .female, .male: return 1.4
            case .series: return 1.2
            case .group: return 0.8
            case .character: return 0.65
            case .format: return 0.2
            }
        }
    }

    let kind: Kind
    let value: String
    var alias: String? = nil
    var siteID: String? = nil
    var entityID: String? = nil

    var id: String { "\(siteID ?? "*")|\(kind.rawValue)|\(entityID ?? Self.normalize(alias ?? value))" }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Compact metadata used for learning; full page lists and images are never persisted here.
struct ExternalRecommendationDocument: Codable, Identifiable {
    let siteID: String
    let galleryID: Int
    let title: String
    var pageCount: Int
    let language: String?
    let features: [ExternalRecommendationFeature]
    var publishedAt: Date? = nil

    var id: String { "\(siteID)#\(galleryID)" }

    /// Only exact metadata matches are collapsed across sites. Translations remain separate.
    var duplicateKey: String {
        let artists = features.filter { $0.kind == .artist }
            .map { ExternalRecommendationFeature.normalize($0.value) }.sorted()
        guard !artists.isEmpty else { return id }
        return [ExternalRecommendationFeature.normalize(title), artists.joined(separator: ","),
                String(pageCount), ExternalRecommendationFeature.normalize(language ?? "")].joined(separator: "|")
    }
}

enum ExternalRecommendationVote: String, Codable {
    case like, dislike
}

struct ExternalRecommendationFeedback: Codable {
    var document: ExternalRecommendationDocument
    var vote: ExternalRecommendationVote?
    var bookmarked = false
    var visibleSeconds: Double = 0
    var pagesRead = 0
    var impressions = 0
    var lastSeen: Date?
    var updatedAt: Date

    /// Explicit rejection takes precedence over every positive implicit signal.
    func signal(at now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(updatedAt)) / 86_400
        let explicitDecay = pow(0.5, age / 120)
        if vote == .dislike { return -5 * explicitDecay }
        var result = ((vote == .like ? 4.0 : 0) + (bookmarked ? 3.0 : 0)) * explicitDecay
        let implicitAge = max(0, now.timeIntervalSince(lastSeen ?? updatedAt)) / 86_400
        let implicitDecay = pow(0.5, implicitAge / 30)
        if visibleSeconds >= 3 {
            result += min(0.5, visibleSeconds / 40) * implicitDecay
        }
        if pagesRead >= 2 {
            let fraction = Double(pagesRead) / Double(max(1, document.pageCount))
            result += min(1.5, 0.5 + fraction) * implicitDecay
        } else if visibleSeconds >= 0.6 && visibleSeconds < 2 && vote == nil && !bookmarked {
            result -= 0.2 * implicitDecay
        }
        return result
    }
}

struct ExternalRecommendationPreference: Codable {
    enum Value: String, Codable { case prefer, hide }
    let feature: ExternalRecommendationFeature
    let value: Value
}

/// Feedback is stored as current facts, so changing a vote reverses its old contribution.
struct ExternalRecommendationProfile: Codable {
    var feedback: [String: ExternalRecommendationFeedback] = [:]
    var preferences: [String: ExternalRecommendationPreference] = [:]

    mutating func setVote(_ vote: ExternalRecommendationVote?, for document: ExternalRecommendationDocument, at now: Date) {
        var record = feedback[document.id] ?? ExternalRecommendationFeedback(document: document, updatedAt: now)
        record.document = document
        record.vote = vote
        record.updatedAt = now
        feedback[document.id] = record
    }

    mutating func setBookmark(_ saved: Bool, for document: ExternalRecommendationDocument, at now: Date) {
        var record = feedback[document.id] ?? ExternalRecommendationFeedback(document: document, updatedAt: now)
        record.document = document
        if record.bookmarked != saved { record.updatedAt = now }
        record.bookmarked = saved
        feedback[document.id] = record
    }

    mutating func recordExposure(_ document: ExternalRecommendationDocument, seconds: Double, pages: Int, at now: Date, incrementImpression: Bool = true) {
        guard seconds.isFinite, seconds >= 0, pages > 0 else { return }
        var record = feedback[document.id] ?? ExternalRecommendationFeedback(document: document, updatedAt: now)
        record.document = document
        record.visibleSeconds = max(record.visibleSeconds, min(120, seconds))
        record.pagesRead = max(record.pagesRead, min(document.pageCount, pages))
        if incrementImpression { record.impressions = min(100, record.impressions + 1) }
        record.lastSeen = now
        feedback[document.id] = record
    }

    mutating func setPreference(_ value: ExternalRecommendationPreference.Value?, for feature: ExternalRecommendationFeature) {
        preferences[feature.id] = value.map { ExternalRecommendationPreference(feature: feature, value: $0) }
    }

    mutating func prune(limit: Int = 800) {
        guard feedback.count > limit else { return }
        let ordered = feedback.sorted {
            let left = ($0.value.vote != nil || $0.value.bookmarked) ? 1 : 0
            let right = ($1.value.vote != nil || $1.value.bookmarked) ? 1 : 0
            if left != right { return left > right }
            return ($0.value.lastSeen ?? $0.value.updatedAt) > ($1.value.lastSeen ?? $1.value.updatedAt)
        }
        feedback = Dictionary(uniqueKeysWithValues: ordered.prefix(limit).map { ($0.key, $0.value) })
    }
}

/// Content-based online ranking with explicit negatives, confidence smoothing and exploration.
struct ExternalRecommendationEngine {
    private struct Evidence {
        var signed: Double = 0
        var mass: Double = 0
        var feature: ExternalRecommendationFeature
    }

    let profile: ExternalRecommendationProfile
    let now: Date
    private var evidence: [String: Evidence] = [:]
    private var knownCopies = Set<String>()
    private var recentCopies = Set<String>()

    init(profile: ExternalRecommendationProfile, now: Date = Date()) {
        self.profile = profile
        self.now = now
        for record in profile.feedback.values {
            if record.vote != nil || record.bookmarked { knownCopies.insert(record.document.duplicateKey) }
            if let seen = record.lastSeen, now.timeIntervalSince(seen) < 3 * 86_400 {
                recentCopies.insert(record.document.duplicateKey)
            }
            let signal = record.signal(at: now)
            guard abs(signal) > 0.001 else { continue }
            let groups = Dictionary(grouping: record.document.features, by: \.kind)
            for features in groups.values {
                let unique = Dictionary(features.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let contribution = signal / sqrt(Double(max(1, unique.count)))
                for feature in unique.values {
                    var value = evidence[feature.id] ?? Evidence(feature: feature)
                    value.signed += contribution
                    value.mass += abs(contribution)
                    evidence[feature.id] = value
                }
            }
        }
    }

    func affinity(for feature: ExternalRecommendationFeature) -> Double {
        if let preference = profile.preferences[feature.id] {
            return preference.value == .hide ? -1 : 1
        }
        guard let value = evidence[feature.id] else { return 0 }
        return value.signed / (2 + value.mass)
    }

    func isEligible(_ document: ExternalRecommendationDocument, ignoringSeen: Bool = false) -> Bool {
        guard document.pageCount > 0 else { return false }
        if knownCopies.contains(document.duplicateKey) { return false }
        if !ignoringSeen && recentCopies.contains(document.duplicateKey) { return false }
        if document.features.contains(where: { profile.preferences[$0.id]?.value == .hide }) { return false }
        if let record = profile.feedback[document.id] {
            if record.vote == .dislike || record.vote == .like || record.bookmarked { return false }
            if !ignoringSeen, let seen = record.lastSeen, now.timeIntervalSince(seen) < 3 * 86_400 { return false }
        }
        return true
    }

    func score(_ document: ExternalRecommendationDocument) -> Double {
        let groups = Dictionary(grouping: document.features, by: \.kind)
        var sum = 0.0
        var weight = 0.0
        for (kind, features) in groups {
            let values = features.map { affinity(for: $0) }
            let average = values.reduce(0, +) / Double(max(1, values.count))
            // Strong matching interests survive a long list of unrelated metadata.
            let best = values.max() ?? 0
            sum += (average * 0.65 + max(0, best) * 0.35) * kind.weight
            weight += kind.weight
        }
        let freshness = document.publishedAt.map { 0.15 * exp(-max(0, now.timeIntervalSince($0)) / (30 * 86_400)) } ?? 0
        let exposure = Double(profile.feedback[document.id]?.impressions ?? 0)
        return 3 * sum / max(1, weight) + freshness - min(0.8, exposure * 0.15)
    }

    /// Candidate retrieval uses positive interests as well as the general catalog.
    func interests(limit: Int = 12) -> [ExternalRecommendationFeature] {
        var features = evidence.mapValues(\.feature)
        for preference in profile.preferences.values { features[preference.feature.id] = preference.feature }
        return features.values.filter { $0.kind != .format && affinity(for: $0) > 0.12 }
            .sorted {
                let left = affinity(for: $0) * $0.kind.weight
                let right = affinity(for: $1) * $1.kind.weight
                return left == right ? $0.id < $1.id : left > right
            }.prefix(limit).map { $0 }
    }

    func ranked(_ candidates: [ExternalRecommendationDocument], after recent: [ExternalRecommendationDocument], offset: Int, limit: Int) -> [ExternalRecommendationDocument] {
        var seenKeys = Set<String>()
        var pool = candidates.sorted { $0.id < $1.id }
            .filter { isEligible($0) && seenKeys.insert($0.duplicateKey).inserted }
        var result: [ExternalRecommendationDocument] = []
        while !pool.isEmpty && result.count < limit {
            let history = Array((recent + result).suffix(4))
            let exploring = (offset + result.count + 1).isMultiple(of: 5)
            let winner = pool.indices.max { left, right in
                let a = rankingValue(pool[left], history: history, exploring: exploring)
                let b = rankingValue(pool[right], history: history, exploring: exploring)
                return a == b ? pool[left].id > pool[right].id : a < b
            }!
            result.append(pool.remove(at: winner))
        }
        return result
    }

    private func rankingValue(_ document: ExternalRecommendationDocument, history: [ExternalRecommendationDocument], exploring: Bool) -> Double {
        let featureIDs = Set(document.features.filter { $0.kind != .format }.map(\.id))
        let creators = Set(document.features.filter { $0.kind == .artist }.map(\.id))
        var penalty = 0.0
        for (index, item) in history.reversed().enumerated() {
            let decay = 1 / Double(index + 1)
            let otherCreators = Set(item.features.filter { $0.kind == .artist }.map(\.id))
            if !creators.isDisjoint(with: otherCreators) { penalty += 0.8 * decay }
            let other = Set(item.features.filter { $0.kind != .format }.map(\.id))
            let union = featureIDs.union(other).count
            if union > 0 { penalty += 0.45 * Double(featureIDs.intersection(other).count) / Double(union) * decay }
        }
        if history.suffix(2).count == 2 && history.suffix(2).allSatisfy({ $0.siteID == document.siteID }) {
            penalty += 0.2
        }
        let novelty = document.features.isEmpty ? 1 : document.features.reduce(0.0) {
            $0 + 1 / (1 + (evidence[$1.id]?.mass ?? 0))
        } / Double(document.features.count)
        // Stable daily variation avoids a permanently identical cold-start ordering.
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let hash = "\(day)|\(document.id)".utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let jitter = Double(hash % 1_000) / 20_000
        return (exploring ? novelty + score(document) * 0.25 : score(document)) - penalty + jitter
    }
}
