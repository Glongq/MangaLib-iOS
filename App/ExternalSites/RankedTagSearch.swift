import Foundation

/// Generic ranked search over several tags on an external site (see the plan,
/// Part 5) — the SAME algorithm idea as App/SpecialFilterEngine.swift
/// (iterating over subsets of the selected tags from largest to smallest, ranking
/// by match count), but DUPLICATED here in full, by deliberate decision — we do not
/// touch/reuse SpecialFilterEngine.swift.
///
/// Difference from the LibSite version: there, a subset is checked with ONE network
/// request (the server itself can AND over genres[]/tags[]). hitomi.la has no such
/// request — instead, each SELECTED tag is queried SEPARATELY
/// (one .nozomi request per tag, not per subset), and a subset match
/// is computed as the INTERSECTION of the already-fetched ID sets —
/// locally, with no extra network requests.
@MainActor
enum RankedTagSearch {
    struct Choice: Hashable {
        let namespace: ExternalTagNamespace
        let value: String
    }

    struct Result {
        let id: Int
        let matchCount: Int
    }

    /// No more than 6 selected tags at once — otherwise the full subset
    /// enumeration (2^n - 1) blows up (see the same limit for the same reason in
    /// SpecialFilterEngine.maxItems).
    static let maxItems = 6
    private static let targetResultCount = 90
    /// How many IDs to fetch for EACH individual tag before intersecting — on
    /// hitomi, popular tags (e.g. "japanese") can have hundreds of thousands
    /// of titles; fetching all of them just for an intersection isn't practical
    /// (traffic/time). The intersection is computed within the first
    /// perTagLimit IDs of each tag — a KNOWN simplification (it can miss
    /// matches outside this window), acceptable for an MVP.
    private static let perTagLimit = 400

    static func search(provider: any ExternalSiteProvider, choices: [Choice]) async -> [Result] {
        let items = Array(choices.prefix(maxItems))
        guard !items.isEmpty else { return [] }

        var idSets: [Choice: Set<Int>] = [:]
        for choice in items {
            guard let (ids, _) = try? await provider.fetchIdsByTag(
                namespace: choice.namespace, value: choice.value, cursor: nil, limit: perTagLimit
            ) else { continue }
            idSets[choice] = Set(ids)
        }
        guard !idSets.isEmpty else { return [] }

        var best: [Int: Int] = [:]
        levels: for threshold in stride(from: items.count, through: 1, by: -1) {
            for subset in combinations(of: items, size: threshold) {
                let sets = subset.compactMap { idSets[$0] }
                guard sets.count == subset.count, let first = sets.first else { continue }
                let intersection = sets.dropFirst().reduce(first) { $0.intersection($1) }
                for id in intersection where threshold > (best[id] ?? 0) {
                    best[id] = threshold
                }
            }
            if best.count >= targetResultCount { break levels }
        }

        return best
            .map { Result(id: $0.key, matchCount: $0.value) }
            .sorted { $0.matchCount != $1.matchCount ? $0.matchCount > $1.matchCount : $0.id > $1.id }
    }

    /// A copy of SpecialFilterEngine.combinations — all subsets of `items`
    /// of size `size`, without duplicates.
    private static func combinations<T>(of items: [T], size: Int) -> [[T]] {
        guard size > 0, size <= items.count else { return [] }
        guard size < items.count else { return [items] }
        var result: [[T]] = []
        func pick(_ start: Int, _ current: [T]) {
            if current.count == size { result.append(current); return }
            let remaining = size - current.count
            guard items.count - start >= remaining else { return }
            pick(start + 1, current + [items[start]])
            pick(start + 1, current)
        }
        pick(0, [])
        return result
    }
}
