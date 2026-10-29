import SwiftUI

/// The existing History entry point, backed by local reading and recommendation facts.
struct ExternalHistoryView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch
    @ObservedObject private var history = ExternalHistoryStore.shared
    @ObservedObject private var recommendations = ExternalRecommendationStore.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("external_history_only_liked") private var onlyLiked = false
    @State private var query = ""

    private func likeDate(_ entry: ExternalHistoryEntry) -> Date? {
        guard let feedback = recommendations.profile.feedback[entry.id], feedback.vote == .like else { return nil }
        return feedback.likedAt ?? feedback.updatedAt
    }

    private var results: [ExternalHistoryEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = history.entries.filter {
            (!onlyLiked || likeDate($0) != nil)
                && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
        guard onlyLiked else { return filtered }
        return filtered.sorted {
            let left = likeDate($0) ?? .distantPast
            let right = likeDate($1) ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .tint(Theme.accent)
        .task {
            history.importLegacyFeedback(recommendations.profile, bookmarks: ExternalBookmarksStore.shared.bookmarks)
        }
        .onDisappear { history.flush() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Button { onlyLiked.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: onlyLiked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(onlyLiked ? Theme.accent : Theme.textSecondary)
                    Text("Только лайкнутые").foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityValue(onlyLiked ? "Включено" : "Выключено")
            .accessibilityAddTraits(onlyLiked ? .isSelected : [])
            list
        }
        .background(Theme.background.ignoresSafeArea())
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
        .navigationDestination(for: ExternalHistoryEntry.self) { entry in
            ExternalHistoryDestination(entry: entry)
        }
        .background { if embedded { InteractivePopGesture() } }
    }

    @ViewBuilder
    private var list: some View {
        if results.isEmpty {
            StateView(
                icon: onlyLiked ? "heart" : "clock.arrow.circlepath",
                title: query.isEmpty ? (onlyLiked ? "Нет лайкнутых тайтлов" : "Пока пусто") : "Ничего не найдено",
                description: query.isEmpty
                    ? (onlyLiked ? "Здесь появятся тайтлы, которым вы поставили лайк в «Читают»." : "Здесь появятся тайтлы из читалки и раздела «Читают».")
                    : "Попробуйте другой запрос.",
                fillScreen: true
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(results) { entry in
                        SearchDismissibleNavigationLink(value: entry, isSearching: isSearching, dismiss: { dismissSearch() }) {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
            .dismissKeyboardOnFirstTap(active: isSearching) { dismissSearch() }
        }
    }

    private func row(_ entry: ExternalHistoryEntry) -> some View {
        HStack(spacing: 12) {
            ExternalImage(url: entry.coverURL.flatMap(URL.init(string:))) { SkeletonBox() }
                .scaledToFill()
                .frame(width: BookmarksView.bookmarkCoverWidth, height: BookmarksView.bookmarkCoverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(positionLabel(entry))
                    .font(.caption2).foregroundStyle(Theme.accent)
                Text(Self.dateFormatter.string(from: onlyLiked ? (likeDate(entry) ?? entry.lastViewedAt) : entry.lastViewedAt))
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if likeDate(entry) != nil {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
                    .accessibilityLabel("Лайкнутый тайтл")
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.trailing, 12)
        .frame(height: BookmarksView.bookmarkCoverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func positionLabel(_ entry: ExternalHistoryEntry) -> String {
        if let page = entry.page { return "\(entry.site.displayName) · Стр. \(page) из \(entry.pageCount)" }
        if entry.pageCount > 0 { return "\(entry.site.displayName) · \(entry.pageCount) стр." }
        return entry.site.displayName
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter
    }()
}

/// Legacy recommendation records have no URL tokens. Recover one through the provider's title search.
private struct ExternalHistoryDestination: View {
    let entry: ExternalHistoryEntry
    @State private var detail: ExternalGalleryDetail?
    @State private var resolveKey: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let detail {
                ExternalGalleryDetailView(site: entry.site, id: entry.galleryID, preloaded: detail,
                                          resolveKey: resolveKey, resumeFromHistory: true)
            } else if failed {
                StateView(icon: "wifi.exclamationmark", title: "Не удалось открыть тайтл",
                          description: "Проверьте соединение или найдите тайтл в каталоге.",
                          retry: { Task { await load() } }, fillScreen: true)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await load() }
        .onDisappear { ExternalHistoryStore.shared.flush() }
    }

    private func load() async {
        failed = false
        let provider = ExternalSiteRegistry.provider(for: entry.site)
        let savedKey = entry.resolveKey ?? ExternalBookmarksStore.shared.bookmarks.first(where: { $0.id == entry.id })?.resolveKey
        if let savedKey { await provider.primeResolveKey(savedKey, for: entry.galleryID) }
        do {
            let fetched: ExternalGalleryDetail
            do {
                fetched = try await provider.fetchGalleryDetail(id: entry.galleryID)
            } catch EHentaiError.missingToken, SimplyHentaiError.unknownSlug {
                guard !Task.isCancelled else { return }
                _ = try await provider.fetchIdsBySearch(query: entry.title, cursor: nil, limit: 24)
                guard !Task.isCancelled else { return }
                fetched = try await provider.fetchGalleryDetail(id: entry.galleryID)
            }
            let key = await provider.resolveKey(for: entry.galleryID)
            guard !Task.isCancelled else { return }
            resolveKey = key ?? savedKey
            detail = fetched
            ExternalHistoryStore.shared.updateMetadata(fetched, resolveKey: resolveKey)
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
