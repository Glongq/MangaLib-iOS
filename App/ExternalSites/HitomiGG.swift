import Foundation

/// Порт gg.js hitomi.la (https://ltn.gold-usergeneratedcontent.net/gg.js) —
/// используется для сборки URL полноразмерных страниц чтения (см.
/// HitomiProvider.pageImageURL). НЕ используется для превью в сетке
/// каталога — там просто шардирование по первым символам хэша (см.
/// HitomiProvider.coverURL), без этого файла.
///
/// ВАЖНО (30.08, второй заход — подтверждено СРАВНЕНИЕМ двух живых снимков
/// gg.js, ~7 часов друг от друга): И `b` (таймстемп-путь), И весь состав
/// `case`-значений в `m()` — НЕ статичные, оба реально меняются со
/// временем (в обоих снимках по 2112 значений, но РАЗНЫЙ набор — сайт
/// реально перегенерирует таблицу целиком, не просто дописывает). Раньше
/// этот файл хардкодил ОДИН снимок как `static let` — из-за этого чтение
/// полноразмерных страниц рано или поздно молча ломалось (URL строился по
/// уже протухшему пути/неправильному бакету CDN-поддомена). Теперь b/
/// caseSet грузятся ЖИВЬЁМ и кэшируются в памяти на HitomiGGCache — 1-в-1
/// то, что делает сам сайт (он тоже дёргает `gg.js` заново при каждой
/// загрузке читалки).
enum HitomiGG {
    /// `gg.s(h)` — берёт последние 3 символа хэша, переставляет местами
    /// последний символ с предыдущими двумя, парсит как hex → десятичная
    /// строка (используется и как числовой бакет-путь, и как вход в `m`).
    /// Чистый алгоритм, от сервера не зависит — в отличие от b/caseSet
    /// (см. HitomiGGCache), обновлять/кэшировать не нужно.
    static func s(_ hash: String) -> String {
        guard hash.count >= 3 else { return "0" }
        let chars = Array(hash.suffix(3))
        let m1 = String(chars[0...1])   // предпоследние 2 символа
        let m2 = String(chars[2])       // последний символ
        let hex = m2 + m1
        return String(Int(hex, radix: 16) ?? 0)
    }

    /// `gg.m(g)` — 0, если `g` входит в ЖИВОЙ (не хардкоженный) набор
    /// `case` из gg.js (см. HitomiGGCache), иначе 1.
    static func m(_ g: Int, caseSet: Set<Int>) -> Int {
        caseSet.contains(g) ? 0 : 1
    }
}

/// Живой кэш `gg.b`/набора `case`-значений `gg.m()` — см. HitomiGG doc-
/// comment про то, почему это не может быть статичной константой.
/// `actor` — безопасный общий кэш между параллельными запросами страниц
/// одной главы (читалка резолвит несколько страниц сразу — см.
/// ExternalReaderView.preloadUpcoming/preloadVerticalWindow).
actor HitomiGGCache {
    static let shared = HitomiGGCache()

    private var cached: (b: String, caseSet: Set<Int>)?
    private var fetchedAt: Date?
    private var inFlight: Task<(b: String, caseSet: Set<Int>), Error>?

    /// Не чаще раза в час — между двумя реальными снимками этой сессии
    /// прошло около 7 часов, дёргать сеть на КАЖДУЮ страницу незачем.
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
