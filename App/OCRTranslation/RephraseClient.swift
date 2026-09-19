import Foundation

/// Stage B — an optional "rephrase into natural style" pass over Stage-A's
/// literal MT output. One client, two engines: both LM Studio (local
/// network, OpenAI-compatible) and a cloud API speak the same chat-
/// completions schema, so only the base URL/auth differ.
enum RephraseEngine {
    /// LM Studio (or any local OpenAI-compatible server) on the LAN — no
    /// API key required by default.
    case local(baseURL: URL, model: String?)
    /// A cloud OpenAI-compatible endpoint — API key required.
    case cloud(baseURL: URL, apiKey: String, model: String)
}

enum RephraseError: Error {
    case invalidURL
    case badResponse
    case decodingFailed
    case countMismatch
    case missingAPIKey
}

/// One Stage-A line plus a soft length hint — see
/// RecognizedTextBlock.characterBudget(imageSize:) for how the budget is
/// estimated from the block's original on-screen footprint.
struct RephraseLineInput: Encodable {
    let text: String
    let characterBudget: Int

    private enum CodingKeys: String, CodingKey { case text, characterBudget = "budget" }
}

/// Own session/own tiny error enum, no shared HTTP base class — same
/// idiom as the external-site providers (see HitomiProvider).
struct RephraseClient {
    let engine: RephraseEngine

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    private var baseURL: URL {
        switch engine {
        case .local(let baseURL, _): return baseURL
        case .cloud(let baseURL, _, _): return baseURL
        }
    }

    private var model: String? {
        switch engine {
        case .local(_, let model): return model?.isEmpty == false ? model : nil
        case .cloud(_, _, let model): return model
        }
    }

    /// Rewrites `lines` (Stage-A literal translations, in order) into
    /// natural `targetLanguageName` style, nudged toward each line's
    /// `characterBudget` (a soft target — see RephraseLineInput) so the
    /// result more often fits back into the original speech bubble.
    /// Throws on ANY failure (network, timeout, malformed JSON, wrong
    /// count) — callers must catch and silently keep the Stage-A text, no
    /// error UI (per product decision).
    func rephrase(lines: [RephraseLineInput], targetLanguageName: String) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        if case .cloud(_, let apiKey, _) = engine, apiKey.isEmpty {
            throw RephraseError.missingAPIKey
        }

        var request = URLRequest(url: Self.endpoint(baseURL, "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case .cloud(_, let apiKey, _) = engine {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let userContent = (try? JSONEncoder().encode(lines)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "Rewrite this JSON array of literally machine-translated manga dialogue lines into natural, colloquial \(targetLanguageName). Each item has a \"budget\" — the approximate character count that fits back into the original speech bubble. Treat it as a SOFT target: prefer a more concise phrasing that gets close to it, but NEVER omit meaning or cut a sentence short just to fit — going over the budget is fine when it's genuinely needed. Preserve order and count. Reply with ONLY a JSON array of strings, the same length as the input — no markdown, no commentary."],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.3,
            "max_tokens": 700,
            "stream": false
        ]
        if let model { body["model"] = model }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RephraseError.badResponse
        }

        let content = try Self.extractContent(from: data)
        let rewritten = try Self.parseLines(from: content)
        guard rewritten.count == lines.count else { throw RephraseError.countMismatch }
        return rewritten
    }

    /// `GET {baseURL}/models` — cheap reachability check for the settings
    /// screen's "Проверить соединение" button.
    func testConnection() async -> Bool {
        var request = URLRequest(url: Self.endpoint(baseURL, "models"))
        if case .cloud(_, let apiKey, _) = engine {
            guard !apiKey.isEmpty else { return false }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Both LM Studio and OpenAI-compatible cloud APIs serve their REST
    /// surface under `/v1` — the user only enters the bare host (e.g.
    /// `http://192.168.1.23:1234` or `https://api.openai.com`).
    private static func endpoint(_ baseURL: URL, _ path: String) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent(path)
    }

    private static func extractContent(from data: Data) throws -> String {
        struct ChatResponse: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content else {
            throw RephraseError.decodingFailed
        }
        return content
    }

    /// Defensive parse: the model is asked for a bare JSON array, but a
    /// small local model may wrap it in markdown or add stray prose —
    /// fall back to slicing between the first `[` and last `]` before
    /// giving up.
    private static func parseLines(from content: String) throws -> [String] {
        if let direct = try? JSONDecoder().decode([String].self, from: Data(content.utf8)) {
            return direct
        }
        guard let start = content.firstIndex(of: "["), let end = content.lastIndex(of: "]"), start < end else {
            throw RephraseError.decodingFailed
        }
        let sliced = String(content[start...end])
        guard let fallback = try? JSONDecoder().decode([String].self, from: Data(sliced.utf8)) else {
            throw RephraseError.decodingFailed
        }
        return fallback
    }
}
