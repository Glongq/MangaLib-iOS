import Foundation

enum Rule34VideoAuthError: LocalizedError {
    case notLoggedIn, storageFailed
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Rule34Video не подтвердил вход. Войдите на открытой странице и нажмите «Проверить вход»."
        case .storageFailed: return "Не удалось сохранить сессию Rule34Video в защищённом хранилище."
        }
    }
}

/// Password entry belongs to the website. Only first-party session cookies are persisted.
@MainActor
final class Rule34VideoAuthStore: ObservableObject {
    static let shared = Rule34VideoAuthStore()
    @Published private(set) var isLoggedIn = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var validationError: String?
    @Published private(set) var revision = UUID()

    var browserCookies: [HTTPCookie] { cookies.filter(Self.isUsable) }
    private var cookies: [HTTPCookie] = []
    private let keychain = KeychainHelper(service: "com.glongq.MangaLib.rule34video")
    private let sessionKey = "website_session_v1"
    private static let allowedNames: Set<String> = [
        "PHPSESSID", "__Host-kt_member_v2", "kt_acctoken", "kt_tcookie", "csrf_token",
        "__ddg1_", "__ddg8_", "__ddg9_", "__ddg10_"
    ]

    struct Credentials: Sendable {
        let header: String?
        let revision: UUID
    }

    private init() {
        guard let raw = keychain.readString(sessionKey), let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data), stored.version == 1 else { return }
        let restored = stored.cookies.compactMap(\.cookie).filter(Self.isUsable)
        guard Self.hasSessionCookies(restored) else { keychain.delete(sessionKey); return }
        cookies = restored
        isLoggedIn = true
    }

    func credentials(for url: URL?) -> Credentials {
        guard let url, url.scheme == "https", url.host?.lowercased() == "rule34video.com", isLoggedIn else {
            return Credentials(header: nil, revision: revision)
        }
        guard Self.hasSessionCookies(browserCookies) else { logout(); return Credentials(header: nil, revision: revision) }
        let applicable = browserCookies.filter { cookie in
            let path = url.path.isEmpty ? "/" : url.path
            return path == cookie.path || (path.hasPrefix(cookie.path)
                && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        }
        return Credentials(header: HTTPCookie.requestHeaderFields(with: applicable)["Cookie"], revision: revision)
    }

    func finishLogin(cookies proposed: [HTTPCookie]) async throws {
        let candidate = proposed.filter(Self.isUsable)
        guard Self.hasSessionCookies(candidate) else { throw Rule34VideoAuthError.notLoggedIn }
        let expectedRevision = revision
        let refreshed = try await Rule34VideoProvider.validateSession(cookies: candidate)
        try Task.checkCancellation()
        guard expectedRevision == revision else { throw CancellationError() }
        try persist(refreshed)
        cookies = refreshed
        isLoggedIn = true
        validationError = nil
        revision = UUID()
    }

    func validateStoredSession() async {
        guard isLoggedIn, !isRefreshing else { return }
        isRefreshing = true
        let expectedRevision = revision
        defer { isRefreshing = false }
        do {
            let refreshed = try await Rule34VideoProvider.validateSession(cookies: browserCookies)
            try Task.checkCancellation()
            guard expectedRevision == revision else { return }
            try persist(refreshed)
            cookies = refreshed
            validationError = nil
        } catch is CancellationError {
            return
        } catch Rule34VideoAuthError.notLoggedIn {
            if expectedRevision == revision { logout() }
        } catch {
            if expectedRevision == revision { validationError = error.localizedDescription }
        }
    }

    /// Apply rotations only to the same confirmed session that issued the request.
    func receiveCookies(_ updated: [HTTPCookie], revision expected: UUID) {
        guard revision == expected, isLoggedIn, !updated.isEmpty else { return }
        cookies = Self.merging(browserCookies, with: updated)
        guard Self.hasSessionCookies(cookies) else { logout(); return }
        do { try persist(cookies) }
        catch { validationError = error.localizedDescription }
    }

    func logout() {
        cookies = []
        isLoggedIn = false
        validationError = nil
        revision = UUID()
        keychain.delete(sessionKey)
    }

    static func hasSessionCookies(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { isUsable($0) && ["PHPSESSID", "__Host-kt_member_v2"].contains($0.name) }
    }

    static func merging(_ current: [HTTPCookie], with updated: [HTTPCookie]) -> [HTTPCookie] {
        var result = current.filter(isUsable)
        for cookie in updated where isFirstParty(cookie) && allowedNames.contains(cookie.name) {
            result.removeAll { $0.name == cookie.name && $0.path == cookie.path
                && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            if isUsable(cookie) { result.append(cookie) }
        }
        return result
    }

    private static func isFirstParty(_ cookie: HTTPCookie) -> Bool {
        cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "rule34video.com"
    }
    private static func isUsable(_ cookie: HTTPCookie) -> Bool {
        isFirstParty(cookie) && allowedNames.contains(cookie.name) && !cookie.value.isEmpty
            && (cookie.expiresDate.map { $0 > Date() } ?? true)
            && (cookie.name != "__Host-kt_member_v2" || (cookie.isSecure && cookie.path == "/" && cookie.domain == "rule34video.com"))
    }
    private func persist(_ cookies: [HTTPCookie]) throws {
        let stored = StoredSession(version: 1, cookies: cookies.filter(Self.isUsable).map(StoredCookie.init))
        let raw = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        keychain.save(raw, for: sessionKey)
        guard keychain.readString(sessionKey) == raw else { throw Rule34VideoAuthError.storageFailed }
    }

    private struct StoredSession: Codable {
        let version: Int
        let cookies: [StoredCookie]
    }
    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
        }
        var cookie: HTTPCookie? {
            var fields: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let expires { fields[.expires] = expires }
            if secure { fields[.secure] = "TRUE" }
            if httpOnly { fields[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: fields)
        }
    }
}
