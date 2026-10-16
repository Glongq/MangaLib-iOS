import Foundation

/// Tags share one identity across sites; creators retain their source-specific identities.
struct ExternalRecommendationFeature: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case tag, female, male, artist, group, character, series, format

        var isTag: Bool { self == .tag || self == .female || self == .male }
        var sharedKind: Kind { isTag ? .tag : self }

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

    /// A site's gender namespace or local entity ID must not create another tag preference.
    var id: String {
        guard kind.isTag else { return retrievalID }
        return "*|tag|\(Self.normalize(sharedValue))"
    }

    var sharedValue: String {
        guard let alias, !Self.normalize(alias).isEmpty else { return value }
        return alias
    }

    /// Preserve the native namespace for searches and their pagination cursors.
    var retrievalID: String { "\(siteID ?? "*")|\(kind.rawValue)|\(entityID ?? Self.normalize(sharedValue))" }

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

    /// Keep native metadata for retrieval, but show and score each shared interest once.
    var uniqueFeatures: [ExternalRecommendationFeature] {
        var seen = Set<String>()
        return features.filter { seen.insert($0.id).inserted }
    }

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
    var likedAt: Date?
    var voteUpdatedAt: Date?
    var bookmarked = false
    var visibleSeconds: Double = 0
    var pagesRead = 0
    var impressions = 0
    var lastSeen: Date?
    var qualifiedReadAt: Date?
    var readingFactsVersion: Int?
    var updatedAt: Date

    var hasQualifiedReading: Bool {
        qualifiedReadAt != nil || (readingFactsVersion == nil
            && RecommendationExposure.qualityReading(seconds: visibleSeconds, pages: pagesRead, total: document.pageCount))
    }

    static func currentExplicit(in records: [Self]) -> Self? {
        let voted = records.filter { $0.vote != nil }.sorted {
            let left = $0.voteUpdatedAt ?? $0.updatedAt, right = $1.voteUpdatedAt ?? $1.updatedAt
            return left == right ? $0.document.id < $1.document.id : left > right
        }
        if let vote = voted.first { return vote }
        return records.filter(\.bookmarked).sorted {
            $0.updatedAt == $1.updatedAt ? $0.document.id < $1.document.id : $0.updatedAt > $1.updatedAt
        }.first
    }

    /// Explicit rejection takes precedence over every positive implicit signal.
    func signal(at now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(updatedAt)) / 86_400
        let explicitDecay = pow(0.5, age / 120)
        if vote == .dislike { return -5 * explicitDecay }
        var result = ((vote == .like ? 4.0 : 0) + (bookmarked ? 3.0 : 0)) * explicitDecay
        let implicitAge = max(0, now.timeIntervalSince(lastSeen ?? updatedAt)) / 86_400
        let implicitDecay = pow(0.5, implicitAge / 30)
        if hasQualifiedReading {
            result += min(0.5, visibleSeconds / 40) * implicitDecay
            let fraction = min(1, Double(pagesRead) / Double(max(1, document.pageCount)))
            result += 1.5 * pow(fraction, 0.65) * min(1, visibleSeconds / 6) * implicitDecay
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
        if vote == .like {
            if record.vote != .like { record.likedAt = now }
        } else {
            record.likedAt = nil
        }
        record.vote = vote
        record.voteUpdatedAt = now
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
        // Preserve eligible legacy reading once; new visits must qualify with their own metrics.
        if record.readingFactsVersion == nil && record.hasQualifiedReading { record.qualifiedReadAt = record.lastSeen ?? now }
        record.readingFactsVersion = 1
        if RecommendationExposure.qualityReading(seconds: seconds, pages: pages, total: document.pageCount) {
            record.qualifiedReadAt = now
        }
        record.visibleSeconds = max(record.visibleSeconds, min(120, seconds))
        record.pagesRead = max(record.pagesRead, min(document.pageCount, pages))
        if incrementImpression { record.impressions = min(100, record.impressions + 1) }
        record.lastSeen = now
        feedback[document.id] = record
    }

    mutating func setPreference(_ value: ExternalRecommendationPreference.Value?, for feature: ExternalRecommendationFeature) {
        preferences[feature.id] = value.map { ExternalRecommendationPreference(feature: feature, value: $0) }
    }

    /// Re-key existing preferences without losing feedback or multiplying a shared tag's weight.
    @discardableResult
    mutating func mergeSharedTagPreferences() -> Bool {
        var merged: [String: ExternalRecommendationPreference] = [:]
        var changed = false
        for (oldKey, preference) in preferences.sorted(by: { $0.key < $1.key }) {
            let key = preference.feature.id
            if oldKey != key { changed = true }
            if let existing = merged[key] {
                changed = true
                // Legacy preferences have no timestamps; preserve an explicit like on conflict.
                if existing.value != .prefer && preference.value == .prefer { merged[key] = preference }
            } else {
                merged[key] = preference
            }
        }
        if changed { preferences = merged }
        return changed
    }

    /// Freeze the best available date for legacy likes before later bookmark updates can change it.
    @discardableResult
    mutating func migrateLikeDates() -> Bool {
        var changed = false
        for (id, record) in feedback where record.vote == .like && record.likedAt == nil {
            feedback[id]?.likedAt = record.updatedAt
            changed = true
        }
        return changed
    }

    mutating func prune(limit: Int = 800) {
        guard feedback.count > limit else { return }
        let ordered = feedback.sorted {
            let left = ($0.value.vote != nil || $0.value.bookmarked) ? 1 : 0
            let right = ($1.value.vote != nil || $1.value.bookmarked) ? 1 : 0
            if left != right { return left > right }
            return ($0.value.lastSeen ?? $0.value.updatedAt) > ($1.value.lastSeen ?? $1.value.updatedAt)
        }
        // Explicit facts are durable; only implicit cache entries have a storage budget.
        let explicit = ordered.filter { $0.value.vote != nil || $0.value.bookmarked }
        let remaining = ordered.filter { $0.value.vote == nil && !$0.value.bookmarked }.prefix(limit)
        feedback = Dictionary(uniqueKeysWithValues: (explicit + Array(remaining)).map { ($0.key, $0.value) })
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
    }

    private struct Topic {
        let features: [ExternalRecommendationFeature]
    }

    let profile: ExternalRecommendationProfile
    let now: Date
    let learning: ExternalRecommendationLearningModel
    private var evidence: [String: Evidence] = [:]
    private var knownCopies = Set<String>()
    private var recentCopies = Set<String>()
    private var topics: [Topic] = []
    private var preferredTagIDs = Set<String>()

    init(profile: ExternalRecommendationProfile, learning: ExternalRecommendationLearningModel, now: Date = Date()) {
        self.profile = profile
        self.learning = learning
        self.now = now
        preferredTagIDs = Set(profile.preferences.values.filter {
            $0.value == .prefer && $0.feature.kind.isTag
        }.map(\.feature.id))
        let records = profile.feedback.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.document.id < $1.document.id : $0.updatedAt > $1.updatedAt
        }
        for record in records {
            if record.vote != nil || record.bookmarked { knownCopies.insert(record.document.duplicateKey) }
            if let seen = record.lastSeen, now.timeIntervalSince(seen) < 3 * 86_400 {
                recentCopies.insert(record.document.duplicateKey)
            }
        }
        for example in learning.examples {
            let signal = example.weight == 1 ? (example.positive ? 4.0 : -5.0) : 0.8
            let record = example.document
            let groups = Dictionary(grouping: record.uniqueFeatures, by: { $0.kind.sharedKind })
            for features in groups.values {
                let contribution = signal / sqrt(Double(max(1, features.count)))
                for feature in features {
                    var value = evidence[feature.id] ?? Evidence(feature: feature)
                    if signal < 0 {
                        // A rejection excludes the work immediately, but generalizes only after repeated evidence.
                        if value.negativeCopies.insert(record.duplicateKey).inserted {
                            value.negativeSigned += contribution
                            value.negativeMass += abs(contribution)
                        }
                    } else {
                        value.signed += contribution
                        value.mass += abs(contribution)
                    }
                    evidence[feature.id] = value
                }
            }
        }
        topics = learning.interests.map { Topic(features: $0.features) }
    }

    /// Explicit preferences remain positive even when their tags are common in the catalog.
    func affinity(for feature: ExternalRecommendationFeature) -> Double {
        let value = evidence[feature.id]
        let negativeScale = value.map { $0.negativeCopies.count >= 3 ? min(1, Double($0.negativeCopies.count - 2) / 3) : 0 } ?? 0
        let signed = (value?.signed ?? 0) + (value?.negativeSigned ?? 0) * negativeScale
        let mass = (value?.mass ?? 0) + (value?.negativeMass ?? 0) * negativeScale
        let longTerm = signed / (2 + mass)
        let learned = longTerm
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
        let features = document.uniqueFeatures
        let groups = Dictionary(grouping: features, by: { $0.kind.sharedKind })
        var sum = 0.0
        var weight = 0.0
        for (kind, features) in groups {
            let values = features.map { affinity(for: $0) * learning.importance($0) }
            let average = values.reduce(0, +) / Double(max(1, values.count))
            // Strong matching interests survive a long list of unrelated metadata.
            let best = values.max() ?? 0
            sum += (average * 0.65 + max(0, best) * 0.35) * kind.weight
            weight += kind.weight
        }
        let exposure = Double(profile.feedback[document.id]?.impressions ?? 0)
        let ids = Set(features.filter { $0.kind != .format }.map(\.id))
        let match = learning.bestInterest(document)
        let topicMatch = match?.1 ?? 0
        let discouraged = features.filter { profile.preferences[$0.id]?.value == .hide }
        let preferencePenalty = min(1.2, discouraged.reduce(0.0) { $0 + 0.25 * $1.kind.weight })
        // Coverage belongs to the matching direction, not to an impossible union of every taste.
        let direction = match.map { Set($0.0.features.map(\.id)).intersection(preferredTagIDs) } ?? []
        let relevantPreferences = direction.isEmpty ? ids.intersection(preferredTagIDs) : direction
        let preferredCoverage = Double(ids.intersection(relevantPreferences).count) / Double(max(1, relevantPreferences.count))
        let stable = 3 * sum / max(1, weight) + 0.45 * topicMatch
        let personalized = learning.session.isEmpty ? stable : 0.85 * stable + 0.15 * 3 * learning.sessionMatch(document)
        return personalized + 0.35 * preferredCoverage + learning.pairCorrection(document)
            - preferencePenalty - min(0.8, exposure * 0.15)
    }

    func interestGroups() -> [[ExternalRecommendationFeature]] {
        let preferred = profile.preferences.values.filter { $0.value == .prefer }
            .sorted { $0.feature.id < $1.feature.id }.map(\.feature)
        let preferredGroups = preferred.map { [$0] }
        return topics.map(\.features) + preferredGroups
    }

    /// Round-robin the topics so one strong theme cannot consume every retrieval request.
    func interests(limit: Int = 16, rotation: Int = 0) -> [ExternalRecommendationFeature] {
        let groups = interestGroups()
        var result: [ExternalRecommendationFeature] = []
        var used = Set<String>()
        let favorites = profile.preferences.values.filter { $0.value == .prefer }.map(\.feature).sorted { $0.id < $1.id }
        if !favorites.isEmpty {
            for step in 0..<min(8, favorites.count) {
                let feature = favorites[(rotation + step) % favorites.count]
                if used.insert(feature.id).inserted { result.append(feature) }
            }
        }
        let creators = evidence.values.map(\.feature).filter { $0.kind == .artist && affinity(for: $0) > 0.12 }
            .sorted {
                let left = affinity(for: $0), right = affinity(for: $1)
                return left == right ? $0.id < $1.id : left > right
            }
        for feature in creators.prefix(2) where used.insert(feature.id).inserted { result.append(feature) }
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

    func ranked(_ candidates: [ExternalRecommendationDocument], origins: [String: [RecommendationOrigin]],
                after recent: [ExternalRecommendationDocument], offset: Int, seed: UInt64, limit: Int) -> [RecommendationSelection] {
        var seenKeys = Set<String>()
        var pool = candidates.sorted { $0.id < $1.id }
            .filter { isEligible($0) && seenKeys.insert($0.duplicateKey).inserted }
            .map(prepare)
        var history = recent.suffix(4).map(prepare)
        var result: [RecommendationSelection] = []
        var random = RecommendationRandom(state: seed &+ UInt64(max(0, offset)))
        var periods = Dictionary(grouping: recent.suffix(20).map { ExternalRecommendationPeriod.of($0.publishedAt, at: now) }, by: { $0 }).mapValues(\.count)
        periods.removeValue(forKey: .unknown)
        while !pool.isEmpty && result.count < limit {
            guard !Task.isCancelled else { return [] }
            let bestRelevance = pool.map(\.score).max() ?? 0
            // Exploration and diversity remain relevant; an empty arm never consumes a feed slot.
            let relevant = pool.indices.filter { pool[$0].score >= bestRelevance - 1.25 }
            func channels(_ index: Int) -> [RecommendationChannel] {
                let found = origins[pool[index].document.id] ?? []
                return found.isEmpty ? [RecommendationChannel(kind: .catalog)] : found.map(\.channel)
            }
            let channel = learning.policy.choose(relevant.flatMap(channels), random: &random)
            let eligible = relevant.filter { index in channel.map { channels(index).contains($0) } ?? true }
            let exploring = channel?.isExploratory ?? false
            let datedCount = periods.values.reduce(0, +)
            func value(_ candidate: PreparedCandidate) -> Double {
                // Missing periods never force irrelevant titles or block a partially available source.
                let deficit = candidate.period.targetShare * Double(datedCount + 1) - Double(periods[candidate.period] ?? 0)
                let ageBalance = candidate.period != .unknown && candidate.score >= bestRelevance - 0.75
                    ? min(0.5, max(-0.35, deficit * 0.22)) : 0
                return rankingValue(candidate, history: history, exploring: exploring) + ageBalance
            }
            let winner = eligible.max { left, right in
                let a = value(pool[left])
                let b = value(pool[right])
                return a == b ? pool[left].document.id > pool[right].document.id : a < b
            }!
            let selected = pool.remove(at: winner)
            let origin = (origins[selected.document.id] ?? []).filter { $0.channel == channel }.sorted { $0.queryID < $1.queryID }.first
            result.append(RecommendationSelection(document: selected.document, origin: origin))
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
        let features = document.uniqueFeatures
        let novelty = features.isEmpty ? 1 : features.reduce(0.0) {
            $0 + 1 / (1 + (evidence[$1.id]?.mass ?? 0))
        } / Double(features.count)
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let hash = "\(day)|\(document.id)".utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return PreparedCandidate(
            document: document,
            featureIDs: Set(features.filter { $0.kind != .format }.map(\.id)),
            creators: Set(features.filter { $0.kind == .artist }.map(\.id)),
            score: score(document), novelty: novelty, jitter: Double(hash % 1_000) / 20_000,
            period: .of(document.publishedAt, at: now),
            unfamiliarCreator: features.contains { $0.kind == .artist && (evidence[$0.id]?.mass ?? 0) < 0.5 }
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
