import SwiftUI
import WebKit

/// Настоящая страница входа mangalib.me в WKWebView. Так делают все известные
/// неофициальные клиенты (Kotatsu, Tachiyomi/Mihon-расширение, Melon) — прямой
/// POST логина/пароля с телефона на API легко упирается в защиту сайта от
/// ботов, а реальная веб-страница входа обрабатывает это сама (в т.ч. любую
/// капчу). После успешного входа сайт кладёт токен в localStorage страницы
/// (ключ `auth`, внутри `token.access_token`) — читаем его оттуда.
struct LoginWebView: UIViewRepresentable {
    /// Вызывается один раз, как только токен найден в localStorage.
    var onToken: (String, String?) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // Тот же User-Agent, что и у обычных API-запросов — сайт должен
        // отдать мобильную (Safari-подобную) версию страницы входа.
        webView.customUserAgent = MangaNetworkService.userAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = URL(string: "https://mangalib.me/ru/front/auth") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onToken: (String, String?) -> Void
        private var didExtract = false
        private var pollTimer: Timer?
        weak var webView: WKWebView?

        init(onToken: @escaping (String, String?) -> Void) {
            self.onToken = onToken
            super.init()
            // Подстраховка: если сайт — SPA и кладёт токен в localStorage
            // без полноценной навигации (просто XHR-логин), didFinish ниже
            // может не сработать повторно. Поэтому дополнительно поллим.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self, let webView = self.webView else { return }
                self.checkForToken(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForToken(in: webView)
        }

        private func checkForToken(in webView: WKWebView) {
            guard !didExtract else { return }
            webView.evaluateJavaScript("window.localStorage.getItem('auth')") { [weak self] result, _ in
                guard let self, !self.didExtract,
                      let raw = result as? String,
                      let data = raw.data(using: .utf8) else { return }

                struct AuthPayload: Decodable {
                    struct TokenBox: Decodable { let access_token: String }
                    struct AuthBox: Decodable { let username: String? }
                    let token: TokenBox
                    let auth: AuthBox?
                }

                guard let payload = try? JSONDecoder().decode(AuthPayload.self, from: data) else { return }
                self.didExtract = true
                self.pollTimer?.invalidate()
                self.onToken(payload.token.access_token, payload.auth?.username)
            }
        }

        deinit {
            pollTimer?.invalidate()
        }
    }
}

/// Экран входа — шапка с закрытием + сама веб-страница логина. Презентуется
/// отдельным sheet'ом из RootView.swift (маршрутизация по title "Войти").
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWebView { token, username in
                AuthSession.shared.login(token: token, username: username)
                DispatchQueue.main.async { dismiss() }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Вход в MangaLib")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    LoginView()
}
