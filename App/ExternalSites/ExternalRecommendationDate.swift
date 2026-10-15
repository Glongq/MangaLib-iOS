import Foundation

/// Upload dates are source metadata, not necessarily the original publication date.
enum ExternalRecommendationDate {
    static func parse(_ raw: String?, now: Date = Date()) -> Date? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "a.m.", with: "AM")
            .replacingOccurrences(of: "p.m.", with: "PM")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        guard !text.isEmpty else { return nil }
        func valid(_ date: Date?) -> Date? {
            guard let date, date.timeIntervalSince1970 >= 0, date <= now.addingTimeInterval(86_400) else { return nil }
            return date
        }
        if let timestamp = Double(text), text.count >= 10 {
            return valid(Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp))
        }
        let iso = ISO8601DateFormatter()
        if let date = valid(iso.date(from: text)) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = valid(iso.date(from: text)) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm:ssXX", "yyyy-MM-dd HH:mm:ssXXXXX",
                       "yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss",
                       "yyyy/MM/dd", "MMM d, yyyy", "MMMM d, yyyy",
                       "MMM d, yyyy, h:mm a", "MMM. d, yyyy, h:mm a", "MMMM d, yyyy, h:mm a"] {
            formatter.dateFormat = format
            if let date = valid(formatter.date(from: text)) { return date }
        }
        return nil
    }
}

enum ExternalRecommendationPeriod: String, Codable, CaseIterable, Sendable {
    case recent, middle, archive, unknown

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func of(_ date: Date?, at now: Date) -> Self {
        guard let date else { return .unknown }
        let calendar = Self.calendar
        if date >= calendar.date(byAdding: .month, value: -6, to: now)! { return .recent }
        if date >= calendar.date(byAdding: .year, value: -3, to: now)! { return .middle }
        return .archive
    }

    var targetShare: Double {
        switch self {
        case .recent: return 0.30
        case .middle, .archive: return 0.35
        case .unknown: return 0
        }
    }
}

/// A depth is a retrieval strategy, never a claim about a title's actual age.
enum ExternalRecommendationDepth: String, Codable, Sendable {
    case latest, continuation, middle, archive, popular

    var samplesArchive: Bool { self == .middle || self == .archive }

    func fraction(seed: UInt64) -> Double {
        let unit = Double(seed % 10_000) / 10_000
        return self == .middle ? 0.05 + unit * 0.40 : 0.45 + unit * 0.53
    }

    func page(seed: UInt64, upperBound: Int?) -> Int {
        let lower = self == .middle ? 8 : 96
        let upper = self == .middle ? 96 : 2_048
        let maximum = max(1, min(upper, upperBound ?? upper))
        let minimum = min(lower, maximum)
        return minimum + Int(seed % UInt64(maximum - minimum + 1))
    }

    /// Search a bounded date window rather than repeatedly scanning the newest matching results.
    func dateWindow(round: Int, now: Date) -> DateInterval? {
        let calendar = ExternalRecommendationPeriod.calendar
        let today = calendar.startOfDay(for: now)
        let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: today)!
        let threeYearsAgo = calendar.date(byAdding: .year, value: -3, to: today)!
        switch self {
        case .middle:
            let end = calendar.date(byAdding: .month, value: -3 * (round % 10), to: sixMonthsAgo)!
            return DateInterval(start: calendar.date(byAdding: .month, value: -3, to: end)!, end: end)
        case .archive:
            let cutoffYear = calendar.component(.year, from: threeYearsAgo)
            let year = 2007 + round % max(1, cutoffYear - 2007 + 1)
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            return DateInterval(start: start, end: min(threeYearsAgo, calendar.date(byAdding: .year, value: 1, to: start)!))
        default: return nil
        }
    }

    static func seed(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

