import SwiftUI

/// Each switch controls participation in discovery and combined search.
struct ExternalSitesSettingsView: View {
    @ObservedObject private var session = ExternalSiteSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var pixivAuth = PixivAuthStore.shared
    @ObservedObject private var rule34Auth = Rule34AuthStore.shared
    @ObservedObject private var rule34VideoAuth = Rule34VideoAuthStore.shared
    @State private var showPixivLogin = false
    @State private var showRule34Login = false
    @State private var showRule34VideoLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(ExternalContentKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 16)
                        sitesCard(kind)
                    }
                }
                Picker("Показывать", selection: $session.contentKind) {
                    ForEach(ExternalContentKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Тип содержимого каталога и ленты")
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Другие сайты")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .sheet(isPresented: $showPixivLogin) { PixivLoginView() }
        .sheet(isPresented: $showRule34Login) { Rule34LoginView() }
        .sheet(isPresented: $showRule34VideoLogin) { Rule34VideoLoginView() }
        .task { await rule34Auth.validateStoredSession() }
        .task { await rule34VideoAuth.validateStoredSession() }
    }

    private func sitesCard(_ kind: ExternalContentKind) -> some View {
        let sites = ExternalSite.allCases.filter { $0.contentKind == kind }
        return VStack(spacing: 0) {
            ForEach(Array(sites.enumerated()), id: \.element) { index, site in
                VStack(spacing: 0) {
                    Toggle(site.displayName, isOn: Binding(
                        get: { session.enabledSites.contains(site) },
                        set: { session.setEnabled($0, for: site) }
                    ))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    if site == .pixiv { pixivLoginRow }
                    if site == .rule34 { rule34LoginRow }
                    if site == .rule34Video { rule34VideoLoginRow }
                }
                if index < sites.count - 1 {
                    Divider().overlay(Theme.separator).padding(.horizontal, 16)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var pixivLoginRow: some View {
        HStack {
            if pixivAuth.isLoggedIn {
                Text(pixivAuth.username.map { "Вход выполнен: \($0)" } ?? "Вход выполнен")
                Spacer()
                Button("Выйти", role: .destructive) { pixivAuth.logout() }
            } else {
                Text("Требуется вход в аккаунт Pixiv")
                Spacer()
                Button("Войти") { showPixivLogin = true }
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var rule34LoginRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if rule34Auth.isLoggedIn {
                    Text(rule34Auth.username.map { "Вход выполнен: \($0)" } ?? "Вход выполнен")
                    if rule34Auth.isRefreshing { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button("Выйти", role: .destructive) { rule34Auth.logout() }
                } else {
                    Text("Аккаунт Rule34")
                    Spacer()
                    Button("Войти") { showRule34Login = true }
                }
            }
            if let error = rule34Auth.validationError {
                Text(error).foregroundStyle(Theme.textSecondary)
                Button("Проверить вход") { Task { await rule34Auth.validateStoredSession() } }
                    .disabled(rule34Auth.isRefreshing)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var rule34VideoLoginRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if rule34VideoAuth.isLoggedIn {
                    Text("Вход выполнен")
                    if rule34VideoAuth.isRefreshing { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button("Выйти", role: .destructive) { rule34VideoAuth.logout() }
                } else {
                    Text("Аккаунт Rule34Video")
                    Spacer()
                    Button("Войти") { showRule34VideoLogin = true }
                }
            }
            if let error = rule34VideoAuth.validationError {
                Text(error)
                Button("Проверить вход") { Task { await rule34VideoAuth.validateStoredSession() } }
                    .disabled(rule34VideoAuth.isRefreshing)
            }
        }
        .font(.footnote).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}
