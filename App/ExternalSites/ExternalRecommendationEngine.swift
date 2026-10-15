import Foundation

/// A namespaced interest. Creator identities stay scoped to their source site.
struct ExternalRecommendationFeature: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
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
struct ExternalRecommendationDocument: Codable, Identifiable, Sendable {
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

enum ExternalRecommendationVote: String, Codable, Sendable {
    case like, dislike
}

struct ExternalRecommendationFeedback: Codable, Sendable {
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
        if pagesRead > 0 {
            let fraction = min(1, Double(pagesRead) / Double(max(1, document.pageCount)))
            result += 1.5 * pow(fraction, 0.65) * min(1, visibleSeconds / 6) * implicitDecay
        } else if visibleSeconds >= 0.6 && visibleSeconds < 2 && vote == nil && !bookmarked {
            result -= 0.1 * implicitDecay
        }
        return result
    }
}

struct ExternalRecommendationPreference: Codable, Sendable {
    enum Value: String, Codable, Sendable { case prefer, hide }
    let feature: ExternalRecommendationFeature
    let value: Value
}

/// Feedback is stored as current facts, so changing a vote reverses its old contribution.
struct ExternalRecommendationProfile: Codable, Sendable {
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
        guard seconds.isFinite, seconds >= 0, pages >= 0 else { return }
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
        var negativeSigned: Double = 0
        var negativeMass: Double = 0
        var negativeCopies = Set<String>()
        var sessionSigned: Double = 0
        var sessionMass: Double = 0
    }

    private struct Topic {
        let features: [ExternalRecommendationFeature]
        let ids: Set<String>
    }

    let profile: ExternalRecommendationProfile
    let now: Date
    private var evidence: [String: Evidence] = [:]
    private var knownCopies = Set<String>()
    private var recentCopies = Set<String>()
    private var topics: [Topic] = []
    private var preferredTagIDs = Set<String>()

    init(profile: ExternalRecommendationProfile, now: Date = Date()) {
        self.profile = profile
        self.now = now
        preferredTagIDs = Set(profile.preferences.values.filter {
            $0.value == .prefer && [.tag, .female, .male].contains($0.feature.kind)
        }.map(\.feature.id))
        let records = profile.feedback.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.document.id < $1.document.id : $0.updatedAt > $1.updatedAt
        }
        for record in records {
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
                    if signal < 0 {
                        // A rejection excludes the work immediately, but generalizes only after repeated evidence.
                        if value.negativeCopies.insert(record.document.duplicateKey).inserted {
                            value.negativeSigned += contribution
                            value.negativeMass += abs(contribution)
                        }
                    } else {
                        value.signed += contribution
                        value.mass += abs(contribution)
                        if let seen = record.lastSeen, now.timeIntervalSince(seen) < 7 * 86_400 {
                            value.sessionSigned += contribution
                            value.sessionMass += abs(contribution)
                        }
                    }
                    evidence[feature.id] = value
                }
            }
        }
        let anchors = profile.feedback.values.filter { $0.signal(at: now) > 0.35 }
            .sorted {
                let left = $0.signal(at: now)
                let right = $1.signal(at: now)
                return left == right ? $0.document.id < $1.document.id : left > right
            }
        for anchor in anchors {
            let features = anchor.document.features.filter {
                $0.kind != .format && affinity(for: $0) > 0.12
            }.sorted {
                let left = affinity(for: $0) * $0.kind.weight
                let right = affinity(for: $1) * $1.kind.weight
                return left == right ? $0.id < $1.id : left > right
            }
            let selected = Array(features.prefix(4))
            let ids = Set(selected.map(\.id))
            guard !ids.isEmpty else { continue }
            let overlaps = topics.contains { topic in
                Double(ids.intersection(topic.ids).count) / Double(max(1, ids.union(topic.ids).count)) > 0.5
            }
            if !overlaps { topics.append(Topic(features: selected, ids: ids)) }
            if topics.count == 6 { break }
        }
    }

    /// Long-term evidence dominates; this week's reading can gently shift the ordering.
    func affinity(for feature: ExternalRecommendationFeature) -> Double {
        let value = evidence[feature.id]
        let negativeScale = value.map { $0.negativeCopies.count >= 3 ? min(1, Double($0.negativeCopies.count - 2) / 3) : 0 } ?? 0
        let signed = (value?.signed ?? 0) + (value?.negativeSigned ?? 0) * negativeScale
        let mass = (value?.mass ?? 0) + (value?.negativeMass ?? 0) * negativeScale
        let longTerm = signed / (2 + mass)
        let session = (value?.sessionSigned ?? 0) / (4 + (value?.sessionMass ?? 0))
        let learned = longTerm * 0.85 + session * 0.15
        guard let preference = profile.preferences[feature.id] else { return learned }
        // Keep the persisted "hide" value compatible, but make it a soft preference everywhere.
        if preference.value == .hide { return max(-1, learned - 0.55) }
        // Explicit tag preferences have a 25% stronger affinity floor than other preferences.
        let preferredAffinity = preferredTagIDs.contains(feature.id) ? 1.0 : 0.8
        return max(learned, preferredAffinity)
    }

    func isEligible(_ document: ExternalRecommendationDocument, ignoringSeen: Bool = false) -> Bool {
        guard document.pageCount > 0 else { return false }
        if knownCopies.contains(document.duplicateKey) { return false }
        if !ignoringSeen && recentCopies.contains(document.duplicateKey) { return false }
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
        let exposure = Double(profile.feedback[document.id]?.impressions ?? 0)
        let ids = Set(document.features.filter { $0.kind != .format }.map(\.id))
        let topicMatch = topics.map { topic in
            let overlap = topic.features.filter { ids.contains($0.id) }.reduce(0.0) { $0 + $1.kind.weight }
            let total = topic.features.reduce(0.0) { $0 + $1.kind.weight }
            return overlap / max(1, total)
        }.max() ?? 0
        let discouraged = document.features.filter { profile.preferences[$0.id]?.value == .hide }
        let preferencePenalty = min(1.2, discouraged.reduce(0.0) { $0 + 0.25 * $1.kind.weight })
        // Reward broader preference coverage without requiring every preferred tag to match.
        let preferredCoverage = Double(ids.intersection(preferredTagIDs).count) / Double(max(1, preferredTagIDs.count))
        return 3 * sum / max(1, weight) + 0.45 * topicMatch + 0.35 * preferredCoverage
            - preferencePenalty - min(0.8, exposure * 0.15)
    }

    func interestGroups() -> [[ExternalRecommendationFeature]] {
        let preferred = profile.preferences.values.filter { $0.value == .prefer }
            .sorted { $0.feature.id < $1.feature.id }.map(\.feature)
        let preferredGroups = preferred.map { [$0] }
        return Array((preferredGroups + topics.map(\.features)).prefix(12))
    }

    /// Round-robin the topics so one strong theme cannot consume every retrieval request.
    func interests(limit: Int = 16) -> [ExternalRecommendationFeature] {
        let groups = interestGroups()
        var result: [ExternalRecommendationFeature] = []
        var used = Set<String>()
        for index in 0..<4 {
            for group in groups where group.indices.contains(index) {
                if used.insert(group[index].id).inserted { result.append(group[index]) }
                if result.count == limit { return result }
            }
        }
        let remaining = evidence.values.map(\.feature).filter { $0.kind != .format && affinity(for: $0) > 0.12 }
            .sorted {
                let left = affinity(for: $0) * $0.kind.weight
                let right = affinity(for: $1) * $1.kind.weight
                return left == right ? $0.id < $1.id : left > right
            }
        for feature in remaining where used.insert(feature.id).inserted {
            result.append(feature)
            if result.count == limit { break }
        }
        return result
    }

    func ranked(_ candidates: [ExternalRecommendationDocument], after recent: [ExternalRecommendationDocument], offset: Int, limit: Int) -> [ExternalRecommendationDocument] {
        var seenKeys = Set<String>()
        var pool = candidates.sorted { $0.id < $1.id }
            .filter { isEligible($0) && seenKeys.insert($0.duplicateKey).inserted }
            .map(prepare)
        var history = recent.suffix(4).map(prepare)
        var result: [ExternalRecommendationDocument] = []
        var periods = Dictionary(grouping: recent.suffix(20).map { ExternalRecommendationPeriod.of($0.publishedAt, at: now) }, by: { $0 }).mapValues(\.count)
        periods.removeValue(forKey: .unknown)
        while !pool.isEmpty && result.count < limit {
            guard !Task.isCancelled else { return [] }
            let exploring = (offset + result.count + 1).isMultiple(of: 5)
            let bestRelevance = pool.map(\.score).max() ?? 0
            let datedCount = periods.values.reduce(0, +)
            func value(_ candidate: PreparedCandidate) -> Double {
                // Missing periods never force irrelevant titles or block a partially available source.
                let deficit = candidate.period.targetShare * Double(datedCount + 1) - Double(periods[candidate.period] ?? 0)
                let ageBalance = candidate.period != .unknown && candidate.score >= bestRelevance - 0.75
                    ? min(0.5, max(-0.35, deficit * 0.22)) : 0
                return rankingValue(candidate, history: history, exploring: exploring) + ageBalance
            }
            let winner = pool.indices.max { left, right in
                let a = value(pool[left])
                let b = value(pool[right])
                return a == b ? pool[left].document.id > pool[right].document.id : a < b
            }!
            let selected = pool.remove(at: winner)
            result.append(selected.document)
            if selected.period != .unknown { periods[selected.period, default: 0] += 1 }
            history.append(selected)
            if history.count > 4 { history.removeFirst() }
        }
        return result
    }

    private struct PreparedCandidate {
        let document: ExternalRecommendationDocument
        let featureIDs: Set<String>
        let creators: Set<String>
        let score: Double
        let novelty: Double
        let jitter: Double
        let period: ExternalRecommendationPeriod
        let unfamiliarCreator: Bool
    }

    /// Normalize metadata and compute invariant scores once, outside pairwise comparisons.
    private func prepare(_ document: ExternalRecommendationDocument) -> PreparedCandidate {
        let novelty = document.features.isEmpty ? 1 : document.features.reduce(0.0) {
            $0 + 1 / (1 + (evidence[$1.id]?.mass ?? 0))
        } / Double(document.features.count)
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let hash = "\(day)|\(document.id)".utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return PreparedCandidate(
            document: document,
            featureIDs: Set(document.features.filter { $0.kind != .format }.map(\.id)),
            creators: Set(document.features.filter { $0.kind == .artist }.map(\.id)),
            score: score(document), novelty: novelty, jitter: Double(hash % 1_000) / 20_000,
            period: .of(document.publishedAt, at: now),
            unfamiliarCreator: document.features.contains { $0.kind == .artist && (evidence[$0.id]?.mass ?? 0) < 0.5 }
        )
    }

    private func rankingValue(_ candidate: PreparedCandidate, history: [PreparedCandidate], exploring: Bool) -> Double {
        var penalty = 0.0
        for (index, item) in history.reversed().enumerated() {
            let decay = 1 / Double(index + 1)
            if !candidate.creators.isDisjoint(with: item.creators) { penalty += 0.8 * decay }
            let union = candidate.featureIDs.union(item.featureIDs).count
            if union > 0 {
                penalty += 0.45 * Double(candidate.featureIDs.intersection(item.featureIDs).count) / Double(union) * decay
            }
        }
        if history.suffix(2).count == 2 && history.suffix(2).allSatisfy({ $0.document.siteID == candidate.document.siteID }) {
            penalty += 0.2
        }
        let exploration = candidate.score * 0.70 + candidate.novelty * 0.35 + (candidate.unfamiliarCreator ? 0.20 : 0)
        return (exploring ? exploration : candidate.score) - penalty + candidate.jitter
    }
}
