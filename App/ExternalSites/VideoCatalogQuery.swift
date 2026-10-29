import Foundation

/// IDs come from the site's suggestion service, never from display-name guesses.
struct Rule34VideoEntity: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case tag, category, artist
        var title: String {
            switch self { case .tag: return "Теги"; case .category: return "Категории"; case .artist: return "Авторы" }
        }
        var parameter: String {
            switch self { case .tag: return "tag_ids"; case .category: return "category_ids"; case .artist: return "model_ids" }
        }
        var exclusionPrefix: String {
            switch self { case .tag: return "tag"; case .category: return "cat"; case .artist: return "model" }
        }
    }
    let key: Int
    let kind: Kind
    let name: String
    let slug: String
    let count: Int
    var excluded = false
    var id: String { "\(kind.rawValue):\(key)" }
}

struct Rule34VideoQuery: Codable, Hashable, Sendable {
    var searchText = ""
    var entities: [Rule34VideoEntity] = []
    var allTags = true
    var allCategories = true
    var allArtists = false
    var types: Set<String> = []
    var period = ""
    var dateFrom = ""
    var dateTo = ""
    var durationFrom = ""
    var durationTo = ""
    var quality = ""
    var verification = ""
    var sort = ""

    var filterCount: Int {
        entities.count + types.count + [period, quality, verification, sort].filter { !$0.isEmpty }.count
            + ((dateFrom.isEmpty && dateTo.isEmpty) ? 0 : 1)
            + ((durationFrom.isEmpty && durationTo.isEmpty) ? 0 : 1)
    }

    func encoded(search: String) -> String {
        var copy = self
        copy.searchText = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // The query is also a SwiftUI identity; key order must not trigger a reload.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "r34v:" + ((try? encoder.encode(copy))?.base64EncodedString() ?? "")
    }

    static func decode(_ text: String) -> Self {
        guard text.hasPrefix("r34v:"), let data = Data(base64Encoded: String(text.dropFirst(5))),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            var value = Self(); value.searchText = text; return value
        }
        return value
    }

    func parameters(page: Int, block: String, pageVariable: String) -> [URLQueryItem] {
        var result: [URLQueryItem] = [
            .init(name: "mode", value: "async"), .init(name: "function", value: "get_block"),
            .init(name: "block_id", value: block), .init(name: pageVariable, value: String(page)),
            .init(name: "sort_by", value: sort.isEmpty ? (searchText.isEmpty ? "post_date" : "relevance") : sort),
            .init(name: "flag1", value: types.sorted().joined(separator: ",")), .init(name: "rd_flag1", value: "1"),
            .init(name: "post_date_from", value: period == "custom" ? dateFrom : period),
            .init(name: "post_date_to", value: period == "custom" ? dateTo : ""),
            .init(name: "duration_from", value: durationFrom), .init(name: "duration_to", value: durationTo),
            .init(name: "is_hd", value: quality), .init(name: "flag2", value: verification)
        ]
        for kind in Rule34VideoEntity.Kind.allCases {
            let ids = entities.filter { $0.kind == kind && !$0.excluded }.map { String($0.key) }
            let matchAll = kind == .tag ? allTags : (kind == .category ? allCategories : allArtists)
            result.append(.init(name: kind.parameter, value: (matchAll && !ids.isEmpty ? "all," : "") + ids.joined(separator: ",")))
        }
        result.append(.init(name: "temp_skip_items", value: entities.filter(\.excluded)
            .map { "\($0.kind.exclusionPrefix):\($0.key)" }.joined(separator: ",")))
        return result
    }
}

/// Only metatags documented by Rule34's own search cheat sheet are exposed.
struct Rule34CatalogQuery: Codable, Hashable, Sendable {
    var included: [String] = []
    var excluded: [String] = []
    var matchAll = true
    var rating = ""
    var sort = ""
    var uploader = ""
    var minScore = ""
    var minWidth = ""
    var minHeight = ""

    var filterCount: Int {
        included.count + excluded.count + [rating, sort, uploader, minScore, minWidth, minHeight].filter { !$0.isEmpty }.count
    }

    func search(_ text: String) -> String {
        var parts = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        let tags = included.map(Rule34Provider.searchTag)
        if !tags.isEmpty { parts.append(matchAll ? tags.joined(separator: " ") : "( " + tags.joined(separator: " ~ ") + " )") }
        parts += excluded.map { "-" + Rule34Provider.searchTag($0) }
        if !rating.isEmpty { parts.append("rating:\(rating)") }
        if !sort.isEmpty { parts.append("sort:\(sort)") }
        if !uploader.isEmpty { parts.append("user:\(Rule34Provider.searchTag(uploader))") }
        for (key, value) in [("score", minScore), ("width", minWidth), ("height", minHeight)] {
            if let number = Int(value), number >= 0 { parts.append("\(key):>=\(number)") }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
