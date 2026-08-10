import Foundation

/// ВРЕМЕННЫЙ debug-инструмент (по просьбе, на время тестирования) — журнал
/// ВСЕХ сетевых запросов приложения: метод, путь, тело запроса, статус/тело
/// ответа (или текст ошибки, если запрос вообще не дошёл), длительность,
/// точное время. Экран — см. NetworkLogsView.swift, доступ — из Настроек.
///
/// Единая точка записи — MangaNetworkService.executeLogged(_:), через
/// которую проходят ВООБЩЕ ВСЕ запросы (perform/performVoid/
/// performOptionalData — это просто три разных обработчика РЕЗУЛЬТАТА одного
/// и того же вызова, см. комментарий там) — поэтому логировать нужно ровно в
/// одном месте, а не в каждом отдельном методе API.
///
/// Хранится ТОЛЬКО в памяти процесса (не персистится на диск и не переживает
/// перезапуск приложения) — специально, чтобы тела запросов/ответов (slug'и,
/// названия папок, содержимое ответов сервера и т.п.) не оседали на
/// устройстве просто так. Authorization-заголовок (Bearer-токен) сюда
/// намеренно НЕ попадает — логируется только метод, URL, тело и ответ, без
/// заголовков, чтобы токен случайно не показался на экране.
///
/// Убрать перед релизом — временный инструмент на время тестирования.
@MainActor
final class NetworkLogger: ObservableObject {
    static let shared = NetworkLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let method: String
        let url: String
        let requestBody: Data?
        /// nil — запрос вообще не дошёл до сервера (см. errorText: обрыв
        /// сети, отмена и т.п.), а не HTTP-ошибка с телом ответа.
        let statusCode: Int?
        let responseBody: Data?
        let duration: TimeInterval
        let isError: Bool
        let errorText: String?

        /// Только путь+query, без "https://api.cdnlibs.org" — короче и легче
        /// читается в списке.
        var pathOnly: String {
            guard let comps = URLComponents(string: url) else { return url }
            var s = comps.path
            if let query = comps.query, !query.isEmpty { s += "?" + query }
            return s
        }

        var prettyRequestBody: String? { Self.pretty(requestBody) }
        var prettyResponseBody: String? { Self.pretty(responseBody) }

        /// Пытается красиво отформатировать JSON (с отступами, ключи по
        /// алфавиту — легче сравнивать разные ответы глазами); если тело не
        /// JSON — отдаёт как обычный текст, если это вообще не текст — короткую
        /// заглушку вместо мусора.
        private static func pretty(_ data: Data?) -> String? {
            guard let data, !data.isEmpty else { return nil }
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: prettyData, encoding: .utf8) {
                return text
            }
            if let text = String(data: data, encoding: .utf8) { return text }
            return "<\(data.count) байт, не текст>"
        }

        // Только время (без даты) — по просьбе, чтобы строка в списке логов
        // была короче и не растягивала ряды.
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
        var dateString: String { Self.dateFormatter.string(from: date) }

        /// Полный текстовый дамп записи (с телами запроса/ответа) — то, что
        /// копируется по умолчанию (см. NetworkLogsView) — специально одним
        /// куском, удобно вставить в чат.
        var fullText: String {
            var lines = summaryLines
            if let prettyRequestBody {
                lines.append("Тело запроса:\n\(prettyRequestBody)")
            }
            if let prettyResponseBody {
                lines.append("Тело ответа:\n\(prettyResponseBody)")
            }
            return lines.joined(separator: "\n")
        }

        /// Укороченная версия — только заголовок записи (метод/путь/статус/
        /// время), БЕЗ тел запроса и ответа. По просьбе: полные логи с телами
        /// (особенно списки закладок/каталога) весят много, когда их много
        /// нужно скопировать разом — короткая версия достаточно точно
        /// показывает ЧТО происходило (какие запросы, какие статусы), не
        /// раздувая текст целиком.
        var summaryOnlyText: String {
            summaryLines.joined(separator: "\n")
        }

        private var summaryLines: [String] {
            var lines: [String] = []
            lines.append("[\(dateString)] \(method) \(pathOnly)")
            if let statusCode {
                lines.append("Статус: \(statusCode) (\(String(format: "%.0f", duration * 1000)) мс)")
            } else {
                lines.append("Запрос НЕ дошёл: \(errorText ?? "неизвестная ошибка") (\(String(format: "%.0f", duration * 1000)) мс)")
            }
            return lines
        }
    }

    @Published private(set) var entries: [Entry] = []

    /// Ограничение по памяти — это debug-журнал в оперативке одной активной
    /// сессии, а не архив; после этого числа старые записи просто отваливаются.
    private let maxEntries = 400

    func log(method: String, url: String, requestBody: Data?, statusCode: Int?,
             responseBody: Data?, duration: TimeInterval, isError: Bool, errorText: String? = nil) {
        let entry = Entry(date: Date(), method: method, url: url, requestBody: requestBody,
                           statusCode: statusCode, responseBody: responseBody,
                           duration: duration, isError: isError, errorText: errorText)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }
}
