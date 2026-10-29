import SwiftUI
import WebKit

/// Uses the real website form, including any challenge it displays. Passwords
/// stay inside WebKit and are never extracted or submitted by app code.
struct Rule34LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var attemptID = UUID()
    @State private var isValidating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Rule34LoginWebView(
                    onValidating: { isValidating = $0 },
                    onSuccess: { dismiss() },
                    onError: { errorMessage = $0 }
                )
                .id(attemptID)
                .ignoresSafeArea(edges: .bottom)
                if isValidating {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("Проверяем вход…").tint(.white).foregroundStyle(.white)
                }
            }
            .navigationTitle("Вход в Rule34")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .alert("Не удалось войти", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Попробовать снова") { attemptID = UUID() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct Rule34LoginWebView: UIViewRepresentable {
    let onValidating: (Bool) -> Void
    let onSuccess: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onValidating: onValidating, onSuccess: onSuccess, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A temporary website store prevents sharing a session with other
        // providers. Only the confirmed cookies are kept in Keychain.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Rule34Provider.mediaHeaders["User-Agent"]
        webView.navigationDelegate = context.coordinator
        context.coordinator.start(webView, cookies: Rule34AuthStore.shared.browserCookies)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop(uiView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let onValidating: (Bool) -> Void
        private let onSuccess: () -> Void
        private let onError: (String) -> Void
        private weak var webView: WKWebView?
        private var preparationTask: Task<Void, Never>?
        private var validationTask: Task<Void, Never>?
        private var attemptedCredentials: String?
        private var completed = false

        init(onValidating: @escaping (Bool) -> Void, onSuccess: @escaping () -> Void,
             onError: @escaping (String) -> Void) {
            self.onValidating = onValidating
            self.onSuccess = onSuccess
            self.onError = onError
        }

        func start(_ webView: WKWebView, cookies: [HTTPCookie]) {
            self.webView = webView
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.add(self)
            preparationTask = Task {
                for cookie in cookies { await store.setCookie(cookie) }
                guard !Task.isCancelled else { return }
                webView.load(URLRequest(url: Rule34Provider.loginURL))
            }
        }

        func stop(_ webView: WKWebView) {
            completed = true
            preparationTask?.cancel()
            validationTask?.cancel()
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            webView.navigationDelegate = nil
            webView.stopLoading()
            self.webView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspectSession()
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            inspectSession()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Challenge subframes remain website-controlled. The account sheet
            // itself never navigates to an unrelated top-level site or scheme.
            if navigationAction.targetFrame?.isMainFrame != false {
                guard let url = navigationAction.request.url, url.scheme == "https",
                      url.host?.lowercased() == "rule34.xxx" else {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportNavigationError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportNavigationError(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !completed { onError("Страница входа была закрыта системой. Откройте её ещё раз.") }
        }

        private func reportNavigationError(_ error: Error) {
            guard !completed, (error as NSError).code != NSURLErrorCancelled else { return }
            onError(error.localizedDescription)
        }

        private func inspectSession() {
            guard !completed, validationTask == nil, let webView,
                  webView.url?.host?.lowercased() == "rule34.xxx" else { return }
            validationTask = Task {
                defer { validationTask = nil }
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard !Task.isCancelled, !completed,
                      Rule34AuthStore.credentialUserID(cookies) != nil else { return }
                let credentials = cookies.filter { ["user_id", "pass_hash"].contains($0.name) }
                    .sorted { $0.name < $1.name }
                let fingerprint = HTTPCookie.requestHeaderFields(with: credentials)["Cookie"]
                guard attemptedCredentials != fingerprint else { return }
                attemptedCredentials = fingerprint
                onValidating(true)
                defer { if !completed { onValidating(false) } }
                do {
                    try await Rule34AuthStore.shared.finishLogin(cookies: cookies)
                    guard !Task.isCancelled, !completed else { return }
                    completed = true
                    onValidating(false)
                    onSuccess()
                } catch is CancellationError {
                    return
                } catch {
                    if !completed { onError(error.localizedDescription) }
                }
            }
        }
    }
}
