import SwiftUI
import WebKit

struct Rule34VideoLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var attemptID = UUID()
    @State private var checkRequest = 0
    @State private var isValidating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Rule34VideoLoginWebView(checkRequest: checkRequest,
                    onValidating: { isValidating = $0 }, onSuccess: { dismiss() }, onError: { errorMessage = $0 })
                    .id(attemptID).ignoresSafeArea(edges: .bottom)
                if isValidating {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("Проверяем вход…").tint(.white).foregroundStyle(.white)
                }
            }
            .navigationTitle("Вход в Rule34Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Проверить вход") { checkRequest += 1 }.disabled(isValidating)
                }
            }
            .alert("Не удалось войти", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Попробовать снова") { attemptID = UUID() }
                Button("Отмена", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct Rule34VideoLoginWebView: UIViewRepresentable {
    let checkRequest: Int
    let onValidating: (Bool) -> Void
    let onSuccess: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onValidating: onValidating, onSuccess: onSuccess, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = Rule34VideoProvider.headers["User-Agent"]
        view.navigationDelegate = context.coordinator
        context.coordinator.checkRequest = checkRequest
        context.coordinator.start(view, cookies: Rule34VideoAuthStore.shared.browserCookies)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.checkRequest != checkRequest {
            context.coordinator.checkRequest = checkRequest
            context.coordinator.inspectSession(force: true)
        }
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.stop(uiView) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var checkRequest = 0
        private let onValidating: (Bool) -> Void
        private let onSuccess: () -> Void
        private let onError: (String) -> Void
        private weak var webView: WKWebView?
        private var preparationTask: Task<Void, Never>?
        private var validationTask: Task<Void, Never>?
        private var attemptedFingerprint: String?
        private var openedLogin = false
        private var completed = false
        private var pendingCheck = false
        private var pendingForcedCheck = false

        init(onValidating: @escaping (Bool) -> Void, onSuccess: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.onValidating = onValidating; self.onSuccess = onSuccess; self.onError = onError
        }
        func start(_ view: WKWebView, cookies: [HTTPCookie]) {
            webView = view
            let store = view.configuration.websiteDataStore.httpCookieStore
            store.add(self)
            preparationTask = Task {
                for cookie in cookies { await store.setCookie(cookie) }
                guard !Task.isCancelled else { return }
                // /login/ is only a fragment. The root document loads the site's
                // own AJAX form handler and CSRF logic before opening that form.
                view.load(URLRequest(url: Rule34VideoProvider.baseURL))
            }
        }
        func stop(_ view: WKWebView) {
            completed = true
            preparationTask?.cancel(); validationTask?.cancel()
            view.configuration.websiteDataStore.httpCookieStore.remove(self)
            view.navigationDelegate = nil; view.stopLoading(); webView = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspectSession()
            guard !completed, !openedLogin, webView.url?.host == "rule34video.com" else { return }
            // Activate the captured site's login link. Passwords and form bodies
            // are never inspected, rewritten or sent through a script message.
            webView.evaluateJavaScript("""
                (() => {
                    const link = document.querySelector('a#login[data-fancybox="ajax"]');
                    if (!link) return false;
                    link.click();
                    return true;
                })()
                """) { [weak self] value, _ in
                    guard let self, !self.completed else { return }
                    if value as? Bool == true { self.openedLogin = true }
                }
        }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { inspectSession() }

        func inspectSession(force: Bool = false) {
            guard !completed, let webView, webView.url?.host == "rule34video.com" else { return }
            guard validationTask == nil else {
                pendingCheck = true
                pendingForcedCheck = pendingForcedCheck || force
                return
            }
            validationTask = Task {
                defer {
                    validationTask = nil
                    let again = pendingCheck, forced = pendingForcedCheck
                    pendingCheck = false; pendingForcedCheck = false
                    if again && !completed { inspectSession(force: forced) }
                }
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let cookies = await store.allCookies()
                guard !Task.isCancelled, !completed else { return }
                guard Rule34VideoAuthStore.hasSessionCookies(cookies) else {
                    if force { onError(Rule34VideoAuthError.notLoggedIn.localizedDescription) }
                    return
                }
                let session = cookies.filter { ["PHPSESSID", "__Host-kt_member_v2"].contains($0.name) }.sorted { $0.name < $1.name }
                let fingerprint = HTTPCookie.requestHeaderFields(with: session)["Cookie"]
                guard force || fingerprint != attemptedFingerprint else { return }
                attemptedFingerprint = fingerprint
                // An anonymous PHP session exists before login. It must never
                // dismiss the sheet or display an error during automatic checks.
                if force { onValidating(true) }
                defer { if !completed { onValidating(false) } }
                do {
                    try await Rule34VideoAuthStore.shared.finishLogin(cookies: cookies)
                    guard !Task.isCancelled, !completed else { return }
                    completed = true; onValidating(false); onSuccess()
                } catch is CancellationError {
                    return
                } catch {
                    if force && !completed { onError(error.localizedDescription) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame != false {
                guard let url = navigationAction.request.url, url.scheme == "https", url.host?.lowercased() == "rule34video.com" else {
                    decisionHandler(.cancel); return
                }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !completed { onError("Страница входа была закрыта системой. Откройте её ещё раз.") }
        }
        private func report(_ error: Error) {
            guard !completed, (error as NSError).code != NSURLErrorCancelled else { return }
            onError(error.localizedDescription)
        }
    }
}
