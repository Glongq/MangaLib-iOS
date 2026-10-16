import Foundation

/// All derived statistics and training are constructed by the ranking actor, never by SwiftUI.
struct ExternalRecommendationLearningModel {
    struct Example {
        let document: ExternalRecommendationDocument
        let positive: Bool
        let weight: Double
        let date: Date
    }

    let idf: [String: Double]
    let examples: [Example]
    let interests: [RecommendationInterest]
    let policy: RecommendationChannelPolicy
    let session: [String: Double]
    private let pairWeights: [String: Double]
    private let supportedPairs: Set<String>
    private let pairsEnabled: Bool

    init(profile: ExternalRecommendationProfile, snapshot: LearningSnapshot, now: Date) {
        idf = Self.buildIDF(snapshot.corpus)
        examples = Self.trainingExamples(profile)
        let explicit = examples.filter { $0.weight == 1 }
        pairsEnabled = explicit.count >= 20 && explicit.filter(\.positive).count >= 3
            && explicit.filter { !$0.positive }.count >= 3
        let trained = Self.train(examples, enabled: pairsEnabled)
        supportedPairs = trained.support
        pairWeights = trained.weights
        interests = Self.cluster(examples.filter(\.positive), idf: idf, previous: snapshot.interests)
        policy = RecommendationChannelPolicy(snapshot: snapshot, profile: profile, now: now)
        let currentFacts = Dictionary(grouping: profile.feedback.values, by: { $0.document.duplicateKey })
            .compactMapValues { ExternalRecommendationFeedback.currentExplicit(in: $0) }
        let recent = snapshot.exposures.filter { $0.imageLoaded && ($0.seconds >= 2 || currentFacts[$0.document.duplicateKey] != nil) }
            .sorted { $0.shownAt > $1.shownAt }.prefix(20)
        var sessionVector: [String: Double] = [:]
        for event in recent {
            let explicitFact = currentFacts[event.document.duplicateKey]
            let signal: Double
            if explicitFact?.vote == .dislike { signal = -1 }
            else if explicitFact != nil { signal = 1 }
            else { signal = event.qualityReading ? 0.2 : 0 }
            let vector = Self.vector(event.document, idf: idf)
            for (key, value) in vector { sessionVector[key, default: 0] += value * signal }
        }
        session = RecommendationMath.unit(sessionVector)
    }

    func importance(_ feature: ExternalRecommendationFeature) -> Double { idf[feature.id] ?? 1 }

    func pairCorrection(_ document: ExternalRecommendationDocument) -> Double {
        guard pairsEnabled else { return 0 }
        let features = Self.featureVector(document, support: supportedPairs)
        let logit = features.reduce(0.0) { $0 + $1.value * (pairWeights[$1.key] ?? 0) }
        return 0.6 * tanh(logit)
    }

    func bestInterest(_ document: ExternalRecommendationDocument) -> (RecommendationInterest, Double)? {
        let vector = Self.vector(document, idf: idf)
        return interests.map { ($0, RecommendationMath.dot(vector, $0.center)) }.max { $0.1 < $1.1 }
    }

    func sessionMatch(_ document: ExternalRecommendationDocument) -> Double {
        RecommendationMath.dot(Self.vector(document, idf: idf), session)
    }

    func interestID(for features: [ExternalRecommendationFeature]) -> String {
        let ids = Set(features.map(\.id))
        let match = interests.map { group in (group.id, group.center.reduce(0.0) { $0 + (ids.contains($1.key) ? $1.value : 0) }) }
            .max { $0.1 < $1.1 }
        if let match, match.1 > 0 { return match.0 }
        // Authors inherit the direction of their positively rated works, keeping native author IDs intact.
        let related = examples.filter { $0.positive && !$0.document.uniqueFeatures.filter({ ids.contains($0.id) }).isEmpty }
        if let group = related.compactMap({ example -> (String, Double)? in
            guard let match = bestInterest(example.document) else { return nil }
            return (match.0.id, match.1 * example.weight)
        }).max(by: { $0.1 < $1.1 }) { return group.0 }
        // Explicit favorites retain an independent rotating lane even before any clusters exist.
        return "favorite:\(features.first?.id ?? "global")"
    }

    private static func buildIDF(_ corpus: [String: [ExternalRecommendationDocument]]) -> [String: Double] {
        let documents = Dictionary(corpus.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard documents.count > 50 else { return [:] }
        let sites = Dictionary(grouping: documents.values, by: \.siteID)
        let count = Double(sites.count)
        let effectiveN = Double(documents.count) / max(1, count)
        var frequency: [String: Double] = [:]
        for sample in sites.values {
            var local: [String: Int] = [:]
            for document in sample {
                for tag in document.uniqueFeatures where tag.kind.isTag { local[tag.id, default: 0] += 1 }
            }
            for (key, df) in local { frequency[key, default: 0] += Double(df) / Double(sample.count) / count }
        }
        let confidence = min(1, Double(documents.count - 50) / 150)
        return frequency.mapValues { fraction in
            let raw = min(2, max(1, 1 + log((effectiveN + 1) / (fraction * effectiveN + 1))))
            return 1 + confidence * (raw - 1)
        }
    }

    private static func trainingExamples(_ profile: ExternalRecommendationProfile) -> [Example] {
        var explicit: [Example] = [], reading: [Example] = []
        for copies in Dictionary(grouping: profile.feedback.values, by: { $0.document.duplicateKey }).values {
            if let record = ExternalRecommendationFeedback.currentExplicit(in: copies) {
                explicit.append(Example(document: record.document, positive: record.vote != .dislike,
                                        weight: 1, date: record.voteUpdatedAt ?? record.updatedAt))
            } else if let record = copies.filter(\.hasQualifiedReading)
                .sorted(by: { ($0.qualifiedReadAt ?? $0.lastSeen ?? $0.updatedAt) > ($1.qualifiedReadAt ?? $1.lastSeen ?? $1.updatedAt) }).first {
                reading.append(Example(document: record.document, positive: true, weight: 0.2,
                                       date: record.qualifiedReadAt ?? record.lastSeen ?? record.updatedAt))
            }
        }
        func ordered(_ left: Example, _ right: Example) -> Bool {
            left.date == right.date ? left.document.id < right.document.id : left.date > right.date
        }
        return Array(explicit.sorted(by: ordered).prefix(512)) + Array(reading.sorted(by: ordered).prefix(256))
    }

    private static func rawFeatures(_ document: ExternalRecommendationDocument) -> (singles: [String], pairs: [String]) {
        // Bound the quadratic expansion without favoring site order or duplicate tag namespaces.
        let tags = document.uniqueFeatures.filter { $0.kind.isTag }.map(\.id).sorted().prefix(32)
        let authors = document.uniqueFeatures.filter { $0.kind == .artist }.map(\.id).sorted().prefix(8)
        let tagList = Array(tags)
        var pairs: [String] = []
        for left in tagList.indices {
            for right in tagList.indices where right > left { pairs.append("pair:\(tagList[left])\u{1}\(tagList[right])") }
        }
        for author in authors {
            for tag in tags { pairs.append("pair:\(author)\u{1}\(tag)") }
        }
        return (Array(tags) + Array(authors), pairs)
    }

    private static func featureVector(_ document: ExternalRecommendationDocument, support: Set<String>) -> [String: Double] {
        let raw = rawFeatures(document)
        let pairs = raw.pairs.filter { support.contains($0) }
        // Normalize the two blocks separately so hundreds of pairs cannot drown the single-tag controls.
        var result: [String: Double] = [:]
        for key in raw.singles { result[key] = 1 / sqrt(Double(max(1, raw.singles.count))) }
        for key in pairs { result[key] = 1 / sqrt(Double(max(1, pairs.count))) }
        return result
    }

    private static func train(_ examples: [Example], enabled: Bool) -> (support: Set<String>, weights: [String: Double]) {
        guard enabled, !Task.isCancelled else { return ([], [:]) }
        var counts: [String: Int] = [:]
        for example in examples {
            for pair in rawFeatures(example.document).pairs { counts[pair, default: 0] += 1 }
        }
        let supported = counts.filter { $0.value >= 3 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let support = Set(supported.prefix(2_048).map(\.key))
        let training = examples.map { ($0, featureVector($0.document, support: support).sorted { $0.key < $1.key }) }
        var weights: [String: Double] = [:]
        var bias = 0.0
        var singleScale = 1.0, pairScale = 1.0
        for epoch in 0..<10 {
            guard !Task.isCancelled else { return ([], [:]) }
            // Deterministic epoch shuffling avoids training-order bias without persisting optimizer state.
            let ordered = training.sorted {
                RecommendationMath.hash("\(epoch)|\($0.0.document.id)") < RecommendationMath.hash("\(epoch)|\($1.0.document.id)")
            }
            for (example, vector) in ordered {
                let raw = vector.reduce(0.0) {
                    $0 + $1.value * (weights[$1.key] ?? 0) * ($1.key.hasPrefix("pair:") ? pairScale : singleScale)
                }
                let logit = max(-20, min(20, bias + raw))
                let error = (1 / (1 + exp(-logit)) - (example.positive ? 1 : 0)) * example.weight
                bias -= 0.05 * error
                // Lazy global L2 decay also regularizes coefficients absent from this example.
                singleScale *= 1 - 0.05 * 0.001
                pairScale *= 1 - 0.05 * 0.01
                for (key, value) in vector {
                    let old = weights[key] ?? 0
                    let scale = key.hasPrefix("pair:") ? pairScale : singleScale
                    weights[key] = old - 0.05 * error * value / scale
                }
            }
        }
        return (support, weights.filter { $0.key.hasPrefix("pair:") }.mapValues { $0 * pairScale })
    }

    private static func vector(_ document: ExternalRecommendationDocument, idf: [String: Double]) -> [String: Double] {
        RecommendationMath.unit(Dictionary(uniqueKeysWithValues: document.uniqueFeatures.filter { $0.kind.isTag }
            .map { ($0.id, idf[$0.id] ?? 1) }))
    }

    private static func cluster(_ examples: [Example], idf: [String: Double], previous: [RecommendationInterest]) -> [RecommendationInterest] {
        let works = examples.sorted { $0.weight == $1.weight ? $0.document.id < $1.document.id : $0.weight > $1.weight }
            .map { ($0, vector($0.document, idf: idf)) }.filter { !$0.1.isEmpty }
        guard let first = works.first else { return [] }
        let k = min(6, max(1, Int(ceil(sqrt(Double(works.count))))))
        var centers = [first.1]
        while centers.count < k {
            let distances = works.map { work in (work.1, centers.map { RecommendationMath.dot(work.1, $0) }.max() ?? 0) }
            guard let next = distances.min(by: { $0.1 < $1.1 }), next.1 < 0.95 else { break }
            centers.append(next.0)
        }
        for _ in 0..<5 {
            guard !Task.isCancelled else { return [] }
            var sums = Array(repeating: [String: Double](), count: centers.count)
            for (example, vector) in works {
                let winner = centers.indices.max { RecommendationMath.dot(vector, centers[$0]) < RecommendationMath.dot(vector, centers[$1]) }!
                for (key, value) in vector { sums[winner][key, default: 0] += value * example.weight }
            }
            for index in centers.indices where !sums[index].isEmpty { centers[index] = RecommendationMath.unit(sums[index]) }
        }
        var labels: [String: ExternalRecommendationFeature] = [:]
        for work in works {
            for feature in work.0.document.uniqueFeatures where feature.kind.isTag { labels[feature.id] = feature }
        }
        var assignments: [Int: String] = [:]
        var used = Set<String>()
        let matches = centers.indices.flatMap { index in previous.map { (index, $0.id, RecommendationMath.dot(centers[index], $0.center)) } }
            .sorted { $0.2 == $1.2 ? "\($0.0)|\($0.1)" < "\($1.0)|\($1.1)" : $0.2 > $1.2 }
        for (index, id, similarity) in matches where similarity >= 0.65 && assignments[index] == nil && !used.contains(id) {
            assignments[index] = id
            used.insert(id)
        }
        return centers.indices.map { index in
            let keys = centers[index].sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(12).map(\.key)
            let signature = centers[index].sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value * 10_000))" }.joined(separator: "|")
            let id = assignments[index] ?? "interest:\(RecommendationMath.hash(signature))"
            return RecommendationInterest(id: id, center: centers[index], features: keys.compactMap { labels[$0] })
        }
    }
}
