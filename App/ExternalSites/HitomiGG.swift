import Foundation

/// A port of hitomi.la's gg.js (https://ltn.gold-usergeneratedcontent.net/gg.js) —
/// used to build the URLs for full-size reader pages (see
/// HitomiProvider.pageImageURL). NOT used for catalog grid thumbnails —
/// those just use sharding based on the first characters of the hash (see
/// HitomiProvider.coverURL), no dependency on this file.
///
/// IMPORTANT (Aug 30, second attempt — confirmed by COMPARING two live snapshots
/// of gg.js, ~7 hours apart): BOTH `b` (the timestamp path) AND the entire set of
/// `case` values in `m()` are NOT static — both actually change over
/// time (both snapshots had 2112 values, but a DIFFERENT set — the site really
/// does regenerate the table wholesale, not just append to it). This file used
/// to hardcode a SINGLE snapshot as a `static let` — because of that, reading
/// full-size pages would sooner or later silently break (the URL would be built
/// from an already-stale path/wrong CDN subdomain bucket). Now b/
/// caseSet are loaded LIVE and cached in memory via HitomiGGCache — exactly
/// what the site itself does (it also refetches `gg.js` on every
/// load of the reader).
enum HitomiGG {
    /// `gg.s(h)` — takes the last 3 characters of the hash, swaps the
    /// last character with the preceding two, parses it as hex → a decimal
    /// string (used both as the numeric bucket path and as input to `m`).
    /// A pure algorithm, independent of the server — unlike b/caseSet
    /// (see HitomiGGCache), it doesn't need to be refreshed/cached.
    static func s(_ hash: String) -> String {
        guard hash.count >= 3 else { return "0" }
        let chars = Array(hash.suffix(3))
        let m1 = String(chars[0...1])   // the second-to-last 2 characters
        let m2 = String(chars[2])       // the last character
        let hex = m2 + m1
        return String(Int(hex, radix: 16) ?? 0)
    }

    /// `gg.m(g)` — 0 if `g` is in the LIVE (not hardcoded) set of `case`
    /// values from gg.js (see HitomiGGCache), otherwise 1.
    static func m(_ g: Int, caseSet: Set<Int>) -> Int {
        caseSet.contains(g) ? 0 : 1
    }
}

/// The live cache for `gg.b`/the set of `case` values used by `gg.m()` — see the
/// HitomiGG doc comment for why this can't be a static constant.
/// `actor` — a safe shared cache across concurrent page requests within
/// one chapter (the reader resolves several pages at once — see
/// ExternalReaderView.preloadUpcoming/preloadVerticalWindow).
actor HitomiGGCache {
    static let shared = HitomiGGCache()

    private var cached: (b: String, caseSet: Set<Int>)?
    private var fetchedAt: Date?
    private var inFlight: Task<(b: String, caseSet: Set<Int>), Error>?

    /// No more than once an hour — the two real snapshots taken in this session were
    /// about 7 hours apart, so there's no reason to hit the network on EVERY page.
    private static let ttl: TimeInterval = 3600

    func current(session: URLSession) async throws -> (b: String, caseSet: Set<Int>) {
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.ttl {
            return cached
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await Self.fetchLive(session: session) }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cached = result
        fetchedAt = Date()
        return result
    }

    private static func fetchLive(session: URLSession) async throws -> (b: String, caseSet: Set<Int>) {
        guard let url = URL(string: "https://ltn.gold-usergeneratedcontent.net/gg.js") else {
            throw HitomiError.badResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw HitomiError.badResponse
        }
        guard let b = firstMatch(in: text, pattern: #"b:\s*'([^']+)'"#) else {
            throw HitomiError.decodingFailed
        }
        var caseSet: Set<Int> = []
        if let regex = try? NSRegularExpression(pattern: #"case (\d+):"#) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: text), let value = Int(text[r]) else { return }
                caseSet.insert(value)
            }
        }
        guard !caseSet.isEmpty else { throw HitomiError.decodingFailed }
        return (b, caseSet)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges == 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
