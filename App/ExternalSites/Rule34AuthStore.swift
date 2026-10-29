import Foundation

struct Rule34Account {
    let id: Int
    let username: String?
}

enum Rule34AuthError: LocalizedError {
    case notLoggedIn
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Сайт не подтвердил вход. Войдите в аккаунт Rule34 ещё раз."
        case .storageFailed: return "Не удалось сохранить сессию в защищённом хранилище."
        }
    }
}

/// The website owns password entry and verification. Only its confirmed session
/// is persisted, separately from Lib and Pixiv credentials.
@MainActor
final class Rule34AuthStore: ObservableObject {
    static let shared = Rule34AuthStore()

    @Published private(set) var account: Rule34Account?
    @Published private(set) var isRefreshing = false
    @Published private(set) var validationError: String?

    var isLoggedIn: Bool { account != nil }
    var username: String? { account?.username }
    var browserCookies: [HTTPCookie] { cookies.filter(Self.isUsable) }

    private let keychain = KeychainHelper(service: "com.glongq.MangaLib.rule34")
    private let sessionKey = "website_session_v1"
    private var cookies: [HTTPCookie] = []
    private var revision = UUID()

    private init() {
        guard let raw = keychain.readString(sessionKey),
              let data = raw.data(using: .utf8),
              let saved = try? JSONDecoder().decode(StoredSession.self, from: data),
              saved.version == 1 else { return }
        let restored = saved.cookies.compactMap(\.cookie).filter(Self.isUsable)
        guard Self.credentialUserID(restored) == saved.userID else {
            keychain.delete(sessionKey)
            return
        }
        cookies = restored
        account = Rule34Account(id: saved.userID, username: saved.username)
    }

    /// Credentials are attached only to the exact HTTPS origin, never to media,
    /// autocomplete, unrelated providers or a redirect to another host.
    func cookieHeader(for url: URL?) -> String? {
        guard let url, url.scheme == "https", url.host?.lowercased() == "rule34.xxx",
              account != nil else { return nil }
        guard Self.credentialUserID(browserCookies) == account?.id else {
            logout()
            return nil
        }
        let applicable = browserCookies.filter { cookie in
            let path = url.path.isEmpty ? "/" : url.path
            return path == cookie.path || (path.hasPrefix(cookie.path)
                && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        }
        return HTTPCookie.requestHeaderFields(with: applicable)["Cookie"]
    }

    func finishLogin(cookies proposed: [HTTPCookie]) async throws {
        let candidate = proposed.filter(Self.isUsable)
        guard let cookieID = Self.credentialUserID(candidate) else { throw Rule34AuthError.notLoggedIn }
        let expectedRevision = revision
        let confirmed = try await Rule34Provider.validateAccount(cookies: candidate)
        try Task.checkCancellation()
        guard expectedRevision == revision else { throw CancellationError() }
        guard confirmed.id == cookieID else { throw Rule34AuthError.notLoggedIn }
        try persist(confirmed, cookies: candidate)
        cookies = candidate
        account = confirmed
        validationError = nil
        revision = UUID()
    }

    /// A network error keeps the stored session. A server-confirmed anonymous
    /// account page invalidates it instead of displaying a stale signed-in state.
    func validateStoredSession() async {
        guard isLoggedIn, !isRefreshing else { return }
        isRefreshing = true
        let expectedRevision = revision
        defer { isRefreshing = false }
        do {
            let confirmed = try await Rule34Provider.validateAccount(cookies: browserCookies)
            try Task.checkCancellation()
            guard expectedRevision == revision else { return }
            guard confirmed.id == account?.id else { throw Rule34AuthError.notLoggedIn }
            let refreshed = Rule34Account(id: confirmed.id, username: confirmed.username ?? account?.username)
            try persist(refreshed, cookies: browserCookies)
            account = refreshed
            validationError = nil
        } catch is CancellationError {
            return
        } catch Rule34AuthError.notLoggedIn {
            if expectedRevision == revision { logout() }
        } catch {
            if expectedRevision == revision { validationError = error.localizedDescription }
        }
    }

    func logout() {
        revision = UUID()
        cookies = []
        account = nil
        validationError = nil
        keychain.delete(sessionKey)
    }

    static func credentialUserID(_ cookies: [HTTPCookie]) -> Int? {
        let valid = cookies.filter(isUsable)
        guard let rawID = valid.first(where: { $0.name == "user_id" })?.value,
              let id = Int(rawID), id > 0,
              let hash = valid.first(where: { $0.name == "pass_hash" })?.value,
              !hash.isEmpty else { return nil }
        return id
    }

    private static func isUsable(_ cookie: HTTPCookie) -> Bool {
        cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "rule34.xxx"
            && (cookie.expiresDate.map { $0 > Date() } ?? true)
    }

    private func persist(_ account: Rule34Account, cookies: [HTTPCookie]) throws {
        let stored = StoredSession(version: 1, userID: account.id, username: account.username,
                                   cookies: cookies.map(StoredCookie.init))
        let raw = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        keychain.save(raw, for: sessionKey)
        guard keychain.readString(sessionKey) == raw else { throw Rule34AuthError.storageFailed }
    }

    private struct StoredSession: Codable {
        let version: Int
        let userID: Int
        let username: String?
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
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }
}
