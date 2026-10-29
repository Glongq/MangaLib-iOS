import Foundation

/// Reader CDN routing extracted from Hitomi's current gg.js without executing remote code.
enum HitomiGG {
    struct Configuration: Sendable {
        let b: String
        let caseSet: Set<Int>
        let defaultValue: Int
        let caseValue: Int

        func imageURL(for hash: String) -> URL? {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
            let bucket = HitomiGG.s(hash)
            guard let value = Int(bucket) else { return nil }
            let host = (caseSet.contains(value) ? caseValue : defaultValue) + 1
            return URL(string: "https://a\(host).gold-usergeneratedcontent.net/\(b)\(bucket)/\(hash).avif")
        }
    }

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

    /// Both assignment values rotate along with the bucket set; neither polarity is fixed.
    static func parse(_ text: String) -> Configuration? {
        guard let path = captures(in: text, pattern: #"\bb\s*:\s*['"]([0-9]+/)['"]"#)?.first,
              let body = captures(in: text, pattern: #"\bm\s*:\s*function\s*\([^)]*\)\s*\{([\s\S]*?)\},\s*s\s*:"#)?.first,
              let initial = captures(in: body, pattern: #"\bvar\s+([A-Za-z_$][\w$]*)\s*=\s*([01])\s*;"#),
              let defaultValue = Int(initial[1]),
              let assigned = captures(in: body, pattern: "\\b" + NSRegularExpression.escapedPattern(for: initial[0]) + #"\s*=\s*([01])\s*;\s*break\s*;"#)?.first,
              let caseValue = Int(assigned), defaultValue != caseValue,
              let regex = try? NSRegularExpression(pattern: #"\bcase\s+(\d+)\s*:"#) else { return nil }
        let cases = Set(regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            return Int(body[range])
        })
        guard !cases.isEmpty, cases.allSatisfy({ (0..<4096).contains($0) }) else { return nil }
        return Configuration(b: path, caseSet: cases, defaultValue: defaultValue, caseValue: caseValue)
    }

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

/// The live cache for `gg.b`/the set of `case` values used by `gg.m()` — see the
/// HitomiGG doc comment for why this can't be a static constant.
/// `actor` — a safe shared cache across concurrent page requests within
/// one chapter (the reader resolves several pages at once — see
/// ExternalReaderView.preloadUpcoming/preloadVerticalWindow).
actor HitomiGGCache {
    static let shared = HitomiGGCache()

    private var cached: HitomiGG.Configuration?
    private var fetchedAt: Date?
    private var inFlight: Task<HitomiGG.Configuration, Error>?

    private static let ttl: TimeInterval = 300

    func current(session: URLSession) async throws -> HitomiGG.Configuration {
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

    /// Concurrent failures of an old URL must not discard a newer configuration.
    func invalidate(failedURL: URL, hash: String) {
        guard cached?.imageURL(for: hash) == failedURL else { return }
        cached = nil
        fetchedAt = nil
    }

    private static func fetchLive(session: URLSession) async throws -> HitomiGG.Configuration {
        guard let url = URL(string: "https://ltn.gold-usergeneratedcontent.net/gg.js") else {
            throw HitomiError.badResponse
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw HitomiError.badResponse
        }
        guard let configuration = HitomiGG.parse(text) else {
            throw HitomiError.decodingFailed
        }
        return configuration
    }
}
