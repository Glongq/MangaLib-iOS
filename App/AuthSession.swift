import Foundation
import Combine

/// Сессия аккаунта MangaLib. Логин — через настоящую страницу входа сайта в
/// WKWebView (см. `LoginWebView.swift`): прямой POST логина/пароля с телефона
/// легко упирается в защиту от ботов, а через реальную веб-страницу сайт сам
/// обрабатывает вход. После успешного входа сайт кладёт bearer-токен в
/// localStorage страницы — мы читаем его оттуда и сохраняем в Keychain.
///
/// Дальше просто прикладываем `Authorization: Bearer <token>` ко всем запросам
/// (см. `MangaNetworkService.defaultHeaders`) — никакого отдельного параметра
/// "показать 18+" в API нет: видимость такого контента и глав целиком зависит
/// от аккаунта, к которому привязан токен.
final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var username: String?
    /// Аватар аккаунта — приходит с сервера (`/auth/me`), в localStorage при
    /// логине его нет вообще, поэтому подтягивается отдельным запросом.
    @Published private(set) var avatarURL: URL?
    /// Числовой id аккаунта (`CurrentUser.id`, из `/auth/me`) — нужен для
    /// настоящего эндпоинта "мои закладки" `GET /bookmarks?...&user_id=<id>`
    /// (см. MangaNetworkService.fetchBookmarksAccountList). В localStorage при
    /// логине его нет, поэтому, как и аватар, подтягивается через refreshProfile().
    @Published private(set) var userId: Int?

    /// Текущий bearer-токен (nil — гость). Читает `MangaNetworkService` на
    /// каждый запрос, чтобы прикладывать заголовок Authorization.
    private(set) var token: String?

    private let keychain = KeychainHelper(service: "com.glongq.MangaLib.auth")
    private let tokenKey = "access_token"
    private let usernameKey = "username"

    private init() {
        let savedToken = keychain.readString(tokenKey)
        token = savedToken
        username = keychain.readString(usernameKey)
        isLoggedIn = savedToken != nil

        // Если уже был вход раньше — подтягиваем актуальные ник/аватар при
        // каждом запуске приложения (на сайте они могли поменяться), а заодно
        // сразу подтягиваем закладки и историю чтения — чтобы то, что уже
        // прочитано на сайте, было видно в приложении сразу, а не только
        // после захода на вкладки Закладки/История.
        if savedToken != nil {
            refreshProfile()
            syncAccountData()
        }
    }

    /// Вызывается после того, как `LoginWebView` извлёк токен из localStorage
    /// страницы входа.
    func login(token: String, username: String?) {
        self.token = token
        self.username = username
        self.isLoggedIn = true
        keychain.save(token, for: tokenKey)
        if let username {
            keychain.save(username, for: usernameKey)
        }
        // В localStorage лежит только id/токен (а иногда и ник), аватара там
        // нет вообще — сразу подтягиваем полный профиль через /auth/me.
        refreshProfile()
        syncAccountData()
    }

    /// Подтягивает закладки и реальную историю чтения аккаунта сразу после
    /// входа/запуска — см. BookmarksStore.syncFromServer/syncHistoryFromServer.
    private func syncAccountData() {
        Task {
            await BookmarksStore.shared.syncFromServer()
            await BookmarksStore.shared.syncHistoryFromServer()
        }
    }

    /// Кэширует numeric id аккаунта, если он получен НЕ через refreshProfile()
    /// (см. MangaNetworkService.fetchBookmarksAccountList — там есть гонка:
    /// refreshProfile() и syncAccountData() запускаются как два ПАРАЛЛЕЛЬНЫХ
    /// Task при старте, и syncFromServer() иногда успевает дойти до реального
    /// запроса ДО того, как refreshProfile() успеет получить userId с сервера.
    /// Раньше это приводило к тому, что fetchBookmarksAccountList просто
    /// бросал ошибку и synchFromServer тихо ничего не делал — а поскольку
    /// BookmarksView.task выполняется один раз за всё время жизни вьюхи, эта
    /// единственная неудачная попытка означала, что закладки вообще никогда
    /// не подтягивались с серверными id за всю сессию приложения).
    @MainActor
    func cacheUserId(_ id: Int) {
        userId = id
    }

    func logout() {
        token = nil
        username = nil
        avatarURL = nil
        isLoggedIn = false
        keychain.delete(tokenKey)
        keychain.delete(usernameKey)
    }

    /// `GET /auth/me` → ник + аватар. Ошибки молча игнорируем (например,
    /// протухший токен) — профиль просто останется таким, каким был.
    private func refreshProfile() {
        Task { [weak self] in
            guard let self, let user = try? await MangaNetworkService.shared.fetchCurrentUser() else { return }
            await MainActor.run {
                self.username = user.username
                self.avatarURL = user.avatar?.url.flatMap { URL(string: $0) }
                self.userId = user.id
                self.keychain.save(user.username, for: self.usernameKey)
            }
        }
    }
}
