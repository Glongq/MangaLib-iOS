import SwiftUI
import WebKit

/// The real pixiv login page in a WKWebView — same reasoning as
/// LoginWebView.swift for the main site: a direct username/password POST
/// from the phone would run straight into pixiv's own bot/captcha
/// defenses, while the actual web page handles all of that itself. Unlike
/// LoginWebView (which reads a token out of localStorage once the SPA logs
/// in), pixiv's flow ends with the page trying to navigate to a custom URL
/// scheme — `pixiv://account/login?code=…` — that the OS can't open; a
/// WKNavigationDelegate can still intercept that ATTEMPT and read `code`
/// out of it before letting it fail (see PixivOAuth's doc-comment for the
/// full step-by-step).
struct PixivLoginWebView: UIViewRepresentable {
    let pkce: PixivPKCE
    /// Called once, as soon as the redirect to `pixiv://account/login` is
    /// intercepted.
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.customUserAgent = "PixivIOSApp/8.9.0 (iOS 27.0; iPhone16,2)"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: PixivOAuth.startLoginURL(pkce: pkce)))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCode: (String) -> Void
        private var didExtract = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !didExtract,
                  let url = navigationAction.request.url,
                  url.absoluteString.hasPrefix(PixivOAuth.redirectScheme),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                decisionHandler(.allow)
                return
            }
            didExtract = true
            decisionHandler(.cancel)
            onCode(code)
        }
    }
}

/// Login sheet — presented from ExternalSitesSettingsView's pixiv row.
/// Generates a fresh PKCE pair per attempt (see PixivPKCE.generate — never
/// reused across logins), exchanges the intercepted code the moment it
/// shows up, then dismisses itself.
struct PixivLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pkce = PixivPKCE.generate()
    @State private var isExchanging = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                PixivLoginWebView(pkce: pkce) { code in
                    exchange(code: code)
                }
                .ignoresSafeArea(edges: .bottom)

                if isExchanging {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Вход в Pixiv")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .alert("Не удалось войти", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Попробовать снова") { pkce = PixivPKCE.generate() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func exchange(code: String) {
        isExchanging = true
        Task {
            do {
                let result = try await PixivOAuth.exchangeCode(code, pkce: pkce)
                await MainActor.run {
                    PixivAuthStore.shared.login(result)
                    isExchanging = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isExchanging = false
                    errorMessage = "Обмен кода авторизации на токен не удался. Попробуйте войти ещё раз."
                }
            }
        }
    }
}

#Preview {
    PixivLoginView()
}
