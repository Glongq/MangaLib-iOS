import Foundation
import CryptoKit
import Security

/// Errors for PixivProvider — the same deliberately simple scheme as the
/// other providers in this folder, plus `.notLoggedIn` (every single
/// app-api.pixiv.net endpoint requires `Authorization: Bearer …` — unlike
/// every other site in this folder, pixiv is a real account-gated API, not
/// an anonymous scrape).
enum PixivError: Error {
    case badResponse
    case notLoggedIn
    case oauthFailed(String)
}

// MARK: - PKCE (confirmed by a real HAR of the app's own login — see
// PixivLoginView.swift/PixivOAuth below)

/// One-shot PKCE pair for a single login attempt (see PixivOAuth.
/// startLoginURL/exchangeCode) — `verifier` is sent back at the very end
/// (the token exchange), `challenge` up front (the login URL) — the two
/// together are what proves the app that finishes the flow is the same one
/// that started it.
struct PixivPKCE {
    let verifier: String
    let challenge: String

    static func generate() -> PixivPKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).pixivBase64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).pixivBase64URLEncoded()
        return PixivPKCE(verifier: verifier, challenge: challenge)
    }
}

private extension Data {
    /// RFC 4648 base64url, no padding — exactly what `code_challenge`/
    /// `code_verifier` need (confirmed by the real request: `code_verifier`
    /// in the token-exchange body and `code_challenge` in the login URL are
    /// both this alphabet, no trailing `=`).
    func pixivBase64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The OAuth2/PKCE handshake and token refresh — a REAL, currently-working
/// flow confirmed by a live HAR of the official iOS app's own "log in"
/// button (Sep 16), not the years-old `MOBrBDS8...`/gappleto97 client
/// id/secret published for the ANDROID app that circulates in most
/// unofficial pixiv API wrappers — this is the actual iOS one:
///
/// 1. `GET https://app-api.pixiv.net/web/v1/login?code_challenge={challenge}
///    &code_challenge_method=S256&client=pixiv-ios` in a WKWebView (see
///    PixivLoginView) — redirects through accounts.pixiv.net for the
///    actual username/password/2FA UI (a real browser page, handles its
///    own captcha/bot-detection, exactly like LoginWebView.swift does for
///    the main site's own login).
/// 2. On success it eventually 302s to
///    `pixiv://account/login?code={code}&via=login` — a custom URL scheme
///    the OS can't open, but a WKNavigationDelegate CAN intercept the
///    attempt and read `code` out of it before it fails (see
///    PixivLoginView.Coordinator).
/// 3. `POST https://oauth.secure.pixiv.net/auth/token` with that code +
///    the PKCE verifier exchanges it for `access_token`/`refresh_token`.
/// 4. From then on, `refresh_token` (persisted — see PixivAuthStore) gets a
///    fresh `access_token` the same way, `grant_type=refresh_token`
///    instead of `authorization_code`.
enum PixivOAuth {
    /// The iOS app's own OAuth client identity — confirmed live (Sep 16
    /// HAR of the app's real login flow), NOT the widely-published Android
    /// one. This is baked into every copy of the official app, the same
    /// way EVERY unofficial pixiv client (this one included) has always
    /// had to read it out of a HAR/decompile — it is not a secret tied to
    /// any one account.
    static let clientId = "KzEZED7aC0vird8jWyHM38mXjNTY"
    static let clientSecret = "W9JZoJe00qPvJsiyCGT3CCtC6ZUtdpKpzMbNlUGP"
    static let redirectURI = "https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback"
    /// The custom-scheme redirect PixivLoginView's WKNavigationDelegate
    /// watches for (see the enum doc-comment, step 2) — confirmed by the
    /// real `Location:` header of the callback redirect.
    static let redirectScheme = "pixiv://account/login"

    /// The WKWebView's start URL for a fresh login (see PixivLoginView) —
    /// `client=pixiv-ios` is what makes accounts.pixiv.net eventually 302
    /// back to `pixiv://account/login` instead of an Android/web scheme.
    static func startLoginURL(pkce: PixivPKCE) -> URL {
        var components = URLComponents(string: "https://app-api.pixiv.net/web/v1/login")!
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "client", value: "pixiv-ios")
        ]
        return components.url!
    }

    struct TokenResult {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let username: String?
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let name: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Int
        let user: User?
    }

    private static func requestToken(body: [String: String]) async throws -> TokenResult {
        guard let url = URL(string: "https://oauth.secure.pixiv.net/auth/token") else { throw PixivError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        PixivRequestSigning.apply(to: &request)
        var form = body
        form["client_id"] = clientId
        form["client_secret"] = clientSecret
        form["include_policy"] = "true"
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await PixivProvider.sharedAPISession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PixivError.badResponse }
        guard http.statusCode == 200, let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw PixivError.oauthFailed(message)
        }
        return TokenResult(accessToken: decoded.access_token, refreshToken: decoded.refresh_token, expiresIn: decoded.expires_in, username: decoded.user?.name)
    }

    /// Step 3 above — called once, right after PixivLoginView catches the
    /// `code` in the intercepted redirect.
    static func exchangeCode(_ code: String, pkce: PixivPKCE) async throws -> TokenResult {
        try await requestToken(body: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": redirectURI
        ])
    }

    /// Called by PixivAuthStore.validAccessToken() whenever the cached
    /// access token is missing/expired — `access_token` lives only ~1h
    /// (`expires_in: 3600`, confirmed by HAR), `refresh_token` is
    /// long-lived and is the only thing actually persisted (see
    /// PixivAuthStore).
    static func refresh(refreshToken: String) async throws -> TokenResult {
        try await requestToken(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

/// The app's own request-signing headers — `App-Version`/`App-OS`/
/// `App-OS-Version`/`User-Agent` are plain constants confirmed byte-for-byte
/// by HAR; `X-Client-Time`/`X-Client-Hash` are the app's per-request
/// signature (`X-Client-Hash` confirmed to be some `MD5(X-Client-Time +
/// SECRET)` shape by its format, but NOT byte-for-byte — the long-published
/// Android-client secret used by most unofficial pixiv API wrappers for
/// years does NOT reproduce the hashes seen in a live Sep 16 HAR of the
/// REAL iOS app, meaning pixiv has since rotated it and no current public
/// value is confirmed. Sent anyway on a best-effort basis, same shape/
/// length as the real header — several current unofficial clients report
/// the server doesn't actually reject a wrong value, only a MISSING one.
enum PixivRequestSigning {
    private static let bestEffortHashSeed = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2"

    static func apply(to request: inout URLRequest) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        formatter.timeZone = TimeZone.current
        let time = formatter.string(from: Date())
        let hash = Insecure.MD5.hash(data: Data((time + bestEffortHashSeed).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        request.setValue("8.9.0", forHTTPHeaderField: "App-Version")
        request.setValue("ios", forHTTPHeaderField: "App-OS")
        request.setValue("27.0", forHTTPHeaderField: "App-OS-Version")
        request.setValue("PixivIOSApp/8.9.0 (iOS 27.0; iPhone16,2)", forHTTPHeaderField: "User-Agent")
        request.setValue(time, forHTTPHeaderField: "X-Client-Time")
        request.setValue(hash, forHTTPHeaderField: "X-Client-Hash")
        request.setValue("en", forHTTPHeaderField: "app-accept-language")
    }
}

/// Persisted login state — in-memory access token (short-lived, refreshed
/// on demand), refresh token in Keychain (survives relaunch, the same
/// principle as AuthSession/KeychainHelper for the main app's own login).
/// Every PixivProvider network call goes through `validAccessToken()`
/// first.
@MainActor
final class PixivAuthStore: ObservableObject {
    static let shared = PixivAuthStore()

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var username: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var accessTokenExpiresAt = Date.distantPast

    private let keychain = KeychainHelper(service: "com.glongq.MangaLib.pixiv")
    private let refreshTokenKey = "refresh_token"
    private let usernameKey = "username"

    private init() {
        refreshToken = keychain.readString(refreshTokenKey)
        username = keychain.readString(usernameKey)
        isLoggedIn = refreshToken != nil
    }

    /// Called once by PixivLoginView right after PixivOAuth.exchangeCode
    /// succeeds.
    func login(_ result: PixivOAuth.TokenResult) {
        accessToken = result.accessToken
        refreshToken = result.refreshToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn - 60))
        username = result.username
        isLoggedIn = true
        keychain.save(result.refreshToken, for: refreshTokenKey)
        if let username = result.username { keychain.save(username, for: usernameKey) }
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        accessTokenExpiresAt = .distantPast
        username = nil
        isLoggedIn = false
        keychain.delete(refreshTokenKey)
        keychain.delete(usernameKey)
    }

    /// A Bearer token good for the next request — transparently refreshes
    /// first if the cached one is missing/expired. Throws `.notLoggedIn`
    /// if there's no refresh token at all (never logged in / logged out).
    func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiresAt { return accessToken }
        guard let refreshToken else { throw PixivError.notLoggedIn }
        let result = try await PixivOAuth.refresh(refreshToken: refreshToken)
        accessToken = result.accessToken
        self.refreshToken = result.refreshToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn - 60))
        if let username = result.username { self.username = username }
        keychain.save(result.refreshToken, for: refreshTokenKey)
        return result.accessToken
    }
}

// MARK: - Search filters ("Search options" in the official app — see the
// PixivAdvancedFieldsPicker doc-comment for which of these are confirmed by
// HAR vs. left out because they're either Premium-only account state
// (Bookmarked works/Bookmark date) or never actually exercised in the
// capture (Creation tools/Other)).

enum PixivContentType: String, CaseIterable, Identifiable, Hashable {
    case illustAndMangaAndUgoira = "illust_and_manga_and_ugoira"
    case illust
    case manga
    case illustAndUgoira = "illust_and_ugoira"
    case ugoira

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .illustAndMangaAndUgoira: return "Иллюстрации, манга, угоира"
        case .illust: return "Только иллюстрации"
        case .manga: return "Только манга"
        case .illustAndUgoira: return "Иллюстрации + угоира"
        case .ugoira: return "Только угоира"
        }
    }
}

enum PixivSearchTarget: String, CaseIterable, Identifiable, Hashable {
    case partialMatchForTags = "partial_match_for_tags"
    case exactMatchForTags = "exact_match_for_tags"
    case titleAndCaption = "title_and_caption"
    case keyword

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .partialMatchForTags: return "Теги (частичное совпадение)"
        case .exactMatchForTags: return "Теги (точное совпадение)"
        case .titleAndCaption: return "Название и описание"
        case .keyword: return "Ключевое слово"
        }
    }
}

/// `sort` — date_desc/date_asc confirmed live by HAR; popular_desc is
/// PIXIV PREMIUM ONLY (the "Likes" field in the official Search Options
/// screen carries a "P" badge) — sending it on a free account is expected
/// to either be ignored or error, same honest "let the server decide"
/// principle as every other provider in this folder.
enum PixivSort: String, CaseIterable, Identifiable, Hashable {
    case dateDesc = "date_desc"
    case dateAsc = "date_asc"
    case popularDesc = "popular_desc"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dateDesc: return "Сначала новые"
        case .dateAsc: return "Сначала старые"
        case .popularDesc: return "По лайкам (только Premium)"
        }
    }
}

/// `search_ai_type` — 0/1 confirmed live by HAR across several requests,
/// but WITHOUT a captured screenshot at the exact moment either value was
/// active, the display/hide mapping below follows pixiv's own documented
/// account-level "AI display setting" convention (0 = show everything,
/// 1 = hide AI-generated works) rather than being independently confirmed
/// from this capture alone.
enum PixivAiFilter: String, CaseIterable, Identifiable, Hashable {
    case showAll = "0"
    case hideAIGenerated = "1"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .showAll: return "Показывать"
        case .hideAIGenerated: return "Скрывать"
        }
    }
}

/// One "Search options" configuration — see the fields' doc-comments in
/// PixivContentType/PixivSearchTarget/PixivSort/PixivAiFilter above for
/// what's confirmed. Combines ADDITIVELY with the screen's shared search
/// field (unlike every EXCLUSIVE-advanced-query site in this folder —
/// SimplyHentai/EHentai/3Hentai/Hitomi/HentaiPill — pixiv's own Search
/// Options genuinely modify a normal keyword search rather than replacing
/// it, so there's no separate `search`/`isEmpty`-gates-everything field
/// here; `word` itself always comes from the shared field, see
/// PixivProvider.fetchIdsBySearch).
struct PixivAdvancedQuery: Equatable {
    var contentType: PixivContentType = .illustAndMangaAndUgoira
    var searchTarget: PixivSearchTarget = .partialMatchForTags
    var aiFilter: PixivAiFilter = .showAll
    var sort: PixivSort = .dateDesc
    var startDate: Date?
    var endDate: Date?
    var widthMin: Int?
    var widthMax: Int?
    var heightMin: Int?
    var heightMax: Int?

    var isEmpty: Bool {
        contentType == .illustAndMangaAndUgoira && searchTarget == .partialMatchForTags
            && aiFilter == .showAll && sort == .dateDesc && startDate == nil && endDate == nil
            && widthMin == nil && widthMax == nil && heightMin == nil && heightMax == nil
    }

    /// Soldered into ONE string together with the shared search word, the
    /// same private-control-character channel as
    /// SimplyHentaiAdvancedQuery.encoded() (see its doc-comment) — the
    /// `ExternalCatalogQuery.search(query:excludedCategoryBits:)` case only
    /// carries a single opaque `query: String`, so this is how the extra
    /// fields get to PixivProvider.fetchIdsBySearch, which unpacks them
    /// right back out (see decode(from:)) before building the real
    /// `/v1/search/illust` request.
    fileprivate static let fieldDelimiter = "\u{1}"
    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return formatter
    }()

    func encoded(word: String) -> String {
        var parts = [word.trimmingCharacters(in: .whitespaces)]
        func append(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            parts.append("\(Self.fieldDelimiter)\(key)=\(value)")
        }
        append("content_type", contentType == .illustAndMangaAndUgoira ? nil : contentType.rawValue)
        append("search_target", searchTarget == .partialMatchForTags ? nil : searchTarget.rawValue)
        append("search_ai_type", aiFilter == .showAll ? nil : aiFilter.rawValue)
        append("sort", sort == .dateDesc ? nil : sort.rawValue)
        append("start_date", startDate.map { Self.dateFormat.string(from: $0) })
        append("end_date", endDate.map { Self.dateFormat.string(from: $0) })
        append("width_min", widthMin.map(String.init))
        append("width_max", widthMax.map(String.init))
        append("height_min", heightMin.map(String.init))
        append("height_max", heightMax.map(String.init))
        return parts.joined()
    }

    /// The other half of encoded(word:) — see
    /// PixivProvider.fetchIdsBySearch.
    static func decode(_ encodedQuery: String) -> (word: String, params: [String: String]) {
        let components = encodedQuery.components(separatedBy: fieldDelimiter)
        let word = components.first ?? ""
        var params: [String: String] = [:]
        for component in components.dropFirst() {
            guard let equalsIndex = component.firstIndex(of: "=") else { continue }
            let key = String(component[component.startIndex..<equalsIndex])
            let value = String(component[component.index(after: equalsIndex)...])
            params[key] = value
        }
        return (word, params)
    }
}

// MARK: - JSON models (field names verified against a live HAR of
// `/v1/search/illust`/`/v1/user/illusts`/`/v2/illust/related` — Sep 16).

private struct PixivImageURLs: Decodable {
    let square_medium: String?
    let medium: String?
    let large: String?
    let original: String?
}

private struct PixivTag: Decodable {
    let name: String
    let translated_name: String?
}

private struct PixivUser: Decodable {
    let id: Int
    let name: String
}

private struct PixivMetaPage: Decodable {
    let image_urls: PixivImageURLs
}

private struct PixivIllust: Decodable {
    let id: Int
    let title: String
    let type: String
    let image_urls: PixivImageURLs
    let caption: String?
    let user: PixivUser
    let tags: [PixivTag]
    let create_date: String?
    let page_count: Int
    let width: Int
    let height: Int
    let total_view: Int?
    let total_bookmarks: Int?
    let series: PixivSeries?
    let meta_single_page: PixivImageURLs?
    let meta_pages: [PixivMetaPage]?
}

private struct PixivSeries: Decodable {
    let title: String?
}

private struct PixivSearchResponse: Decodable {
    let illusts: [PixivIllust]
}

private struct PixivAutocompleteResponse: Decodable {
    let tags: [PixivTag]
}

/// Client for pixiv.net's official mobile app API (app-api.pixiv.net) —
/// its OWN, fully separate implementation (own session, own models), not
/// connected to the rest of App/ExternalSites/ beyond the shared protocol.
/// Fundamentally different from the other 6 providers in this folder: a
/// real documented-shape JSON REST API instead of scraping HTML, but ALSO
/// the only one that's genuinely account-gated (see PixivAuthStore) — every
/// endpoint 401s without a valid Bearer token, there's no anonymous
/// browsing at all.
struct PixivProvider: ExternalSiteProvider {
    let site: ExternalSite = .pixiv
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // No alphabetical tag directory in the app API (tags are
        // discovered via search/autocomplete only, see fetchAutocomplete)
        hasTagBrowser: false,
        hasSearch: true,
        // Opens the "Filters" sheet — pixiv's own "Search options" screen
        // (see PixivAdvancedQuery/PixivAdvancedFieldsPicker), not a
        // category bitmask like EHentai/ImHentai, but the same UI hook.
        hasCategoryFilter: true,
        // Cursor is a plain offset we track ourselves (see
        // fetchIdsBySearch) — exact, like Hitomi.
        hasPageJump: true,
        // Sort lives INSIDE PixivAdvancedQuery instead (see its doc-
        // comment) — the shared sortKey mechanism in ExternalCatalogGridView
        // is hard-wired to HitomiProvider.SortOption specifically, not
        // actually generic.
        hasSortOptions: false,
        // pixiv DOES have real account bookmarks (POST .../bookmark/add,
        // confirmed by HAR) but this integration doesn't wire them up yet
        // (see the ExternalSiteCapabilities doc-comment on hasBookmarks —
        // "unavailable IN THIS CLIENT", not "the site has none"); the
        // app's own LOCAL bookmark folders (ExternalBookmarksStore) work
        // regardless of this flag.
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        hasComments: false,
        // 30 illusts/page confirmed live by HAR (`offset=30` on page 2).
        typicalPageSize: 30
    )

    /// A separate session — no shared cookies/cache with the other
    /// providers' sessions, same principle as HitomiProvider.session.
    static let sharedAPISession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.sharedAPISession }

    private func authorizedRequest(_ url: URL) async throws -> URLRequest {
        let token = try await PixivAuthStore.shared.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        PixivRequestSigning.apply(to: &request)
        return request
    }

    // MARK: Tag directory — honestly none (see capabilities.hasTagBrowser).

    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] { [] }

    /// `/v2/search/autocomplete` — confirmed live by HAR: given `word=`,
    /// returns `{tags:[{name, translated_name}]}`. `translated_name` is
    /// exactly the "type a Japanese/English word, get suggestions in the
    /// OTHER language too" behavior the real app's search bar has — kept
    /// in `category` (repurposed: this protocol's `category` field is a
    /// free-form display string on every other provider too, e.g.
    /// "tag"/"artist"; here it's the translation gloss instead) rather than
    /// baked into `name`, so a tap still searches the REAL tag text, not a
    /// "original · translation" composite.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        var components = URLComponents(string: "https://app-api.pixiv.net/v2/search/autocomplete")!
        components.queryItems = [
            URLQueryItem(name: "word", value: query),
            URLQueryItem(name: "merge_plain_keyword_results", value: "1")
        ]
        guard let url = components.url else { return [] }
        let request = try await authorizedRequest(url)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PixivAutocompleteResponse.self, from: data) else {
            return []
        }
        return decoded.tags.map { ExternalTagSuggestion(name: $0.name, count: 0, category: $0.translated_name ?? "") }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        ([], nil)
    }

    /// The word alone, no filters — used only when a caller reaches this
    /// via the protocol's plain overload (see the extension default in
    /// ExternalSiteProvider.swift); the real UI always goes through
    /// fetchIdsBySearch(excludedCategoryBits:...) below, which is where
    /// PixivAdvancedQuery actually gets unpacked.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, cursor: cursor, limit: limit)
    }

    /// `excludedCategoryBits` is unused here (pixiv has no such bitmask) —
    /// the real filters travel INSIDE `query` itself, smuggled in by
    /// PixivAdvancedQuery.encoded(word:) (see its doc-comment) and unpacked
    /// right back out via PixivAdvancedQuery.decode(_:) below.
    ///
    /// An EMPTY word (no search typed yet — the "Recently" feed on every
    /// other site) has no real pixiv equivalent: `/v1/search/illust`
    /// requires a non-empty `word` (an empty one is expected to error/
    /// return nothing useful). Falls back to `/v1/illust/ranking?mode=day`
    /// instead — pixiv's own default "what's popular right now" feed,
    /// confirmed to exist by pixiv's long-published public API shape (NOT
    /// itself captured in this HAR — the capture never visited the
    /// Discover/Ranking tab) — the closest honest analog to "Recently",
    /// ignoring PixivAdvancedQuery entirely for this one fallback case
    /// (ranking has its own separate, much smaller parameter set).
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let (word, params) = PixivAdvancedQuery.decode(query)
        let offset = cursor.flatMap(Int.init) ?? 0
        let trimmedWord = word.trimmingCharacters(in: .whitespaces)

        var components: URLComponents
        if trimmedWord.isEmpty {
            components = URLComponents(string: "https://app-api.pixiv.net/v1/illust/ranking")!
            components.queryItems = [
                URLQueryItem(name: "mode", value: "day"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
        } else {
            components = URLComponents(string: "https://app-api.pixiv.net/v1/search/illust")!
            var items = [
                URLQueryItem(name: "word", value: trimmedWord),
                URLQueryItem(name: "search_target", value: params["search_target"] ?? PixivSearchTarget.partialMatchForTags.rawValue),
                URLQueryItem(name: "sort", value: params["sort"] ?? PixivSort.dateDesc.rawValue),
                URLQueryItem(name: "content_type", value: params["content_type"] ?? PixivContentType.illustAndMangaAndUgoira.rawValue),
                URLQueryItem(name: "search_ai_type", value: params["search_ai_type"] ?? PixivAiFilter.showAll.rawValue),
                URLQueryItem(name: "merge_plain_keyword_results", value: "true"),
                URLQueryItem(name: "include_translated_tag_results", value: "true"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            for key in ["start_date", "end_date", "width_min", "width_max", "height_min", "height_max"] {
                if let value = params[key] { items.append(URLQueryItem(name: key, value: value)) }
            }
            components.queryItems = items
        }
        guard let url = components.url else { throw PixivError.badResponse }
        let request = try await authorizedRequest(url)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PixivError.badResponse }
        let decoded = try JSONDecoder().decode(PixivSearchResponse.self, from: data)
        let ids = decoded.illusts.map(\.id)
        Self.detailCache.store(decoded.illusts)
        let nextCursor = ids.isEmpty ? nil : String(offset + ids.count)
        return (ids, nextCursor)
    }

    /// Exact — the cursor IS the offset (see fetchIdsBySearch above), the
    /// same principle as HitomiProvider.cursorForPage.
    func cursorForPage(_ page: Int, limit: Int) -> String? {
        page <= 1 ? nil : String((page - 1) * limit)
    }

    /// Full detail — pixiv's search/related/user-illusts responses already
    /// return the FULL illust object (see PixivIllust — no separate "detail"
    /// endpoint the way scraped sites need one), so this is normally served
    /// straight out of the small cache fetchIdsBySearch just populated
    /// (see detailCache) with no extra network call at all; only a true
    /// cold-start (e.g. opening a bookmarked title before browsing anything
    /// this session) falls back to a real `/v1/illust/detail?illust_id=`
    /// request.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        if let cached = Self.detailCache.illust(for: id) {
            return Self.map(cached)
        }
        var components = URLComponents(string: "https://app-api.pixiv.net/v2/illust/detail")!
        components.queryItems = [URLQueryItem(name: "illust_id", value: "\(id)")]
        guard let url = components.url else { throw PixivError.badResponse }
        let request = try await authorizedRequest(url)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PixivError.badResponse }
        struct DetailResponse: Decodable { let illust: PixivIllust }
        let decoded = try JSONDecoder().decode(DetailResponse.self, from: data)
        Self.detailCache.store([decoded.illust])
        return Self.map(decoded.illust)
    }

    /// Already a direct pximg.net URL (see map(_:) below, where
    /// ExternalGalleryPage.key is set to it) — no per-page network request
    /// needed, unlike EHentai's expiring H@H links.
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: page.key) else { throw PixivError.badResponse }
        return url
    }

    // MARK: - Mapping

    private static func map(_ illust: PixivIllust) -> ExternalGalleryDetail {
        var pages: [ExternalGalleryPage] = []
        if let metaPages = illust.meta_pages, !metaPages.isEmpty {
            for (index, page) in metaPages.enumerated() {
                let original = page.image_urls.original ?? page.image_urls.large ?? ""
                let thumb = page.image_urls.square_medium ?? page.image_urls.medium
                pages.append(ExternalGalleryPage(
                    index: index,
                    key: original,
                    // Per-page dimensions aren't in meta_pages — only the
                    // top-level illust.width/height (page 0's size).
                    width: index == 0 ? illust.width : 0,
                    height: index == 0 ? illust.height : 0,
                    thumbnailURL: thumb.flatMap(URL.init(string:)),
                    thumbnailSpriteOffsetX: nil
                ))
            }
        } else {
            let single = illust.meta_single_page
            let original = single?.original ?? illust.image_urls.large ?? illust.image_urls.medium ?? ""
            pages.append(ExternalGalleryPage(
                index: 0,
                key: original,
                width: illust.width,
                height: illust.height,
                thumbnailURL: (illust.image_urls.square_medium ?? illust.image_urls.medium).flatMap(URL.init(string:)),
                thumbnailSpriteOffsetX: nil
            ))
        }

        // "original (translated)" — see fetchAutocomplete's doc-comment on
        // the same translation data; ExternalGalleryTag has no separate
        // slot for it, so it's folded into the one display string here.
        let tags = illust.tags.map { tag -> ExternalGalleryTag in
            let name = tag.translated_name.map { "\(tag.name) (\($0))" } ?? tag.name
            return ExternalGalleryTag(name: name, female: false, male: false)
        }

        return ExternalGalleryDetail(
            id: illust.id,
            site: .pixiv,
            title: illust.title,
            type: illust.type,
            language: nil,
            tags: tags,
            artists: [illust.user.name],
            groups: [],
            characters: [],
            series: illust.series?.title.map { [$0] } ?? [],
            related: [],
            pages: pages,
            coverURL: (illust.image_urls.large ?? illust.image_urls.medium).flatMap(URL.init(string:)),
            posted: illust.create_date,
            parentId: nil,
            visible: nil,
            fileSize: nil,
            favoritedCount: illust.total_bookmarks.map(String.init),
            ratingAverage: nil,
            ratingCount: nil,
            comments: []
        )
    }

    /// A small in-memory cache of the full illust objects a listing call
    /// JUST returned (see fetchIdsBySearch) — keyed purely to avoid a
    /// redundant `/v2/illust/detail` round trip for the overwhelmingly
    /// common case (opening a card you just saw in a search/related/
    /// user-illusts list), same spirit as EHentaiProvider.tokenCache/
    /// SimplyHentaiProvider.SlugCache but holding the whole object instead
    /// of just a key, since pixiv's own listing responses are already
    /// complete detail objects with nothing left to fetch.
    fileprivate final class DetailCache: @unchecked Sendable {
        private var storage: [Int: PixivIllust] = [:]
        private let lock = NSLock()

        func store(_ illusts: [PixivIllust]) {
            lock.lock(); defer { lock.unlock() }
            for illust in illusts { storage[illust.id] = illust }
            // Simple cap — this is a convenience cache, not a source of
            // truth; drop the oldest half once it grows past a few
            // listing pages' worth rather than growing unbounded for a
            // long browsing session.
            if storage.count > 600 {
                storage = Dictionary(uniqueKeysWithValues: storage.suffix(300))
            }
        }

        func illust(for id: Int) -> PixivIllust? {
            lock.lock(); defer { lock.unlock() }
            return storage[id]
        }
    }
    fileprivate static let detailCache = DetailCache()
}
