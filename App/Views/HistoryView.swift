import SwiftUI

/// Account reading history, fetched incrementally and deduplicated by title.
struct HistoryView: View {
    /// Embedded navigation reuses the menu stack and its native back button.
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var externalSites = ExternalSiteSession.shared
    @ObservedObject private var siteSession = SiteSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var query = ""

    /// Raw server pages are deduplicated only for presentation.
    @State private var rawEntries: [HistoryEntry] = []
    @State private var historyPage = 1
    @State private var hasMoreHistory = true
    /// Initial loading is separate from pagination so existing rows remain visible.
    @State private var isLoadingHistory = false
    @State private var isLoadingMoreHistory = false

    /// Native searchable state supports dismissing the keyboard on the first tap.
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch

    /// Keep the newest chapter event per title and filter the account-wide response to the active site.
    private var deduped: [HistoryEntry] {
        var seen = Set<Int>()
        return rawEntries.filter { entry in
            guard entry.media.site == nil || entry.media.site == siteSession.activeSite.rawValue else { return false }
            guard !seen.contains(entry.media.id) else { return false }
            seen.insert(entry.media.id)
            return true
        }
    }

    private var results: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deduped }
        return deduped.filter { $0.media.displayTitle.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        if externalSites.isExternalModeActive {
            ExternalHistoryView(embedded: embedded)
        } else {
            accountHistory
        }
    }

    private var accountHistory: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .tint(Theme.accent)
        .task { await resetAndLoad() }
    }

    // MARK: Pagination

    /// Reset the local page buffer for initial loading and pull-to-refresh.
    private func resetAndLoad() async {
        guard AuthSession.shared.isLoggedIn else { return }
        rawEntries = []
        historyPage = 1
        hasMoreHistory = true
        isLoadingHistory = true
        await loadMorePages()
        isLoadingHistory = false
    }

    /// Request another page when the visible list is within five rows of its end.
    private func loadMoreIfNeeded(current entry: HistoryEntry) async {
        guard let idx = results.firstIndex(where: { $0.id == entry.id }) else { return }
        guard idx >= results.count - 5 else { return }
        await loadMorePages()
    }

    /// Continue through duplicate-only batches until a new visible row arrives or the local request budget is reached.
    private func loadMorePages() async {
        guard !isLoadingMoreHistory, hasMoreHistory else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }
        let countBefore = results.count
        var safety = 0
        while hasMoreHistory, results.count <= countBefore, safety < 20 {
            guard let batch = try? await MangaNetworkService.shared.fetchHistory(page: historyPage), !batch.isEmpty else {
                hasMoreHistory = false
                break
            }
            rawEntries.append(contentsOf: batch)
            historyPage += 1
            safety += 1
        }
    }

    private var content: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            list
        }
        // Match the native navigation used by Settings and Downloads.
        .navigationTitle("История")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Поиск по названию")
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationDestination(for: HistoryEntry.self) { entry in
            MangaDetailView(slug: entry.media.apiSlug, fallbackTitle: entry.media.displayTitle,
                             coverURL: entry.media.cover?.bestURL, item: entry.media)
        }
        .background { if embedded { InteractivePopGesture() } }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if isLoadingHistory && results.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.isEmpty && !AuthSession.shared.isLoggedIn {
            // Distinguish a signed-out account from an empty reading history.
            StateView(icon: "person.crop.circle.badge.exclamationmark", title: "Войдите в аккаунт", description: "Чтобы видеть историю чтения.", fillScreen: true)
        } else if results.isEmpty {
            StateView(
                icon: "clock.arrow.circlepath",
                title: query.isEmpty ? "Пока пусто" : "Ничего не найдено",
                description: query.isEmpty ? "Здесь появятся тайтлы, которые вы уже начали читать." : "Попробуйте другой запрос.",
                fillScreen: true
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(results) { entry in
                        SearchDismissibleNavigationLink(value: entry, isSearching: isSearching, dismiss: { dismissSearch() }) { row(entry) }
                            .buttonStyle(.plain)
                            .onAppear { Task { await loadMoreIfNeeded(current: entry) } }
                    }
                }
                .padding(12)

                if isLoadingMoreHistory {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await resetAndLoad() }
            .dismissKeyboardOnFirstTap(active: isSearching) { dismissSearch() }
        }
    }

    /// Match bookmark row dimensions, typography and cover alignment.
    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: entry.media.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: BookmarksView.bookmarkCoverWidth, height: BookmarksView.bookmarkCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.media.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text("Том \(entry.item.volume), Глава \(entry.item.number)")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                Text(Self.dateFormatter.string(from: entry.viewAt))
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.trailing, 12)
        .frame(height: BookmarksView.bookmarkCoverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, HH:mm"
        return f
    }()
}

#Preview {
    HistoryView().preferredColorScheme(.dark)
}
