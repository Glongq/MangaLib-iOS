import SwiftUI

/// Advanced search fields for ImHentai — its own search box + Tags/Parodies/
/// Artists/Characters/Groups (see /advsearch/ on the actual site, a
/// screenshot the user shared on 08/31) — EACH field accumulates ITS OWN
/// list of values (you can add several tags, several characters, etc. at
/// once), unlike the regular search box (one box, one string of text).
/// Values are assembled in ImhentaiAdvancedQuery.clauses() — see its
/// doc-comment in ImhentaiProvider.swift regarding exactly what's confirmed
/// by HAR and what isn't (only `tag` has been confirmed live).
struct ImhentaiAdvancedFieldsPicker: View {
    @Binding var query: ImhentaiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            field("Tags", kind: .tags, values: $query.tags)
            field("Parodies", kind: .series, values: $query.parodies)
            field("Artists", kind: .artists, values: $query.artists)
            field("Characters", kind: .characters, values: $query.characters)
            field("Groups", kind: .groups, values: $query.groups)
        }
    }

    /// IMHentai's own search box (per a direct request on 08/31) —
    /// SEPARATE from Tags and from the screen's shared top search field
    /// (which for imhentai no longer participates in the query at all, see
    /// the ImhentaiAdvancedQuery.searchText doc-comment /
    /// ExternalSearchView.resolvedQuery).
    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Поиск").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField("Свободный текст…", text: $query.searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func field(_ title: String, kind: ExternalTagKind, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            AdvancedFieldInput(kind: kind, values: values)
        }
    }
}

/// A local table of IMHentai's alphabetical index (fetchTagIndex — already
/// confirmed by HAR, see ImhentaiProvider) for suggestions while typing a
/// tag (see AdvancedFieldInput below) — per a direct request (08/31),
/// suggestions are matched as a SUBSTRING against the WHOLE table (typing
/// "anal" will also surface "Double Anal", as in the real site's
/// screenshot), not only within the bucket for its own first letter as it
/// used to. Since there's no confirmed separate autocomplete endpoint on
/// the site (ImhentaiProvider.fetchAutocomplete is honestly empty), the
/// table is built up OURSELVES — by sequentially walking every letter
/// bucket (a...z + "num") via the already-confirmed fetchTagIndex, once per
/// install (cached to disk, see cacheURL — read from there on the next app
/// launch, no network touched again). The walk runs in the background with
/// a small pause between letters (see loadFullIndex) — the site sits behind
/// Cloudflare, and extra parallelism/bursts are more of a captcha/ban risk
/// than a benefit.
@MainActor
private final class ImhentaiTagSuggestionCache: ObservableObject {
    static let shared = ImhentaiTagSuggestionCache()

    private static let allKinds: [ExternalTagKind] = [.tags, .series, .artists, .characters, .groups]
    /// "0" — signals the "num" bucket (see ImhentaiProvider.fetchTagIndex —
    /// letter.isNumber), the digit itself has no meaning.
    // `Swift.Character`, NOT bare `Character` — the module has its own
    // `Character` type (the title's character model, see MangaModels.swift),
    // which shadows the standard single-letter type (the same gotcha as in
    // ExternalSiteProvider.fetchTagIndex — see its doc-comment).
    private static let letters: [Swift.Character] = {
        var result: [Swift.Character] = Array("abcdefghijklmnopqrstuvwxyz")
        result.append("0")
        return result
    }()

    @Published private var fullIndex: [ExternalTagKind: [ExternalTagEntry]] = [:]
    private var loadingTasks: [ExternalTagKind: Task<Void, Never>] = [:]

    private init() {
        for kind in Self.allKinds {
            if let cached = Self.loadFromDisk(kind: kind) {
                fullIndex[kind] = cached
            }
        }
    }

    /// The current local table state for kind — may be incomplete if the
    /// walk is still in progress (see ensureLoading); AdvancedFieldInput
    /// reads this via @ObservedObject, so the suggestion list grows on its
    /// own as the walk proceeds, with no manual filter restart needed.
    func entries(kind: ExternalTagKind) -> [ExternalTagEntry] {
        fullIndex[kind] ?? []
    }

    func ensureLoading(kind: ExternalTagKind) {
        guard fullIndex[kind] == nil, loadingTasks[kind] == nil else { return }
        loadingTasks[kind] = Task { [weak self] in
            await self?.loadFullIndex(kind: kind)
        }
    }

    private func loadFullIndex(kind: ExternalTagKind) async {
        var seen = Set<String>()
        var merged: [ExternalTagEntry] = []
        let provider = ExternalSiteRegistry.provider(for: .imhentai)
        for letter in Self.letters {
            guard let page = try? await provider.fetchTagIndex(kind: kind, letter: letter) else { continue }
            for entry in page where !seen.contains(entry.slug) {
                seen.insert(entry.slug)
                merged.append(entry)
            }
            // Intermediate save — suggestions see the partially-built
            // table right away, they don't wait for ALL 27 buckets at once
            // (one bucket alone can already paginate up to 20 pages, see
            // the fetchTagIndex doc-comment about "groups/a/ — 48 pages").
            fullIndex[kind] = merged
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        Self.saveToDisk(kind: kind, entries: merged)
        loadingTasks[kind] = nil
    }

    // MARK: Disk cache — the walk doesn't repeat on every app relaunch.

    private struct StoredEntry: Codable {
        let id: String
        let name: String
        let count: Int
        let slug: String
    }

    private static func cacheURL(kind: ExternalTagKind) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("imhentai_tagindex_\(kind).json")
    }

    private static func loadFromDisk(kind: ExternalTagKind) -> [ExternalTagEntry]? {
        guard let url = cacheURL(kind: kind),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredEntry].self, from: data) else { return nil }
        return stored.map { ExternalTagEntry(id: $0.id, name: $0.name, count: $0.count, slug: $0.slug) }
    }

    private static func saveToDisk(kind: ExternalTagKind, entries: [ExternalTagEntry]) {
        guard let url = cacheURL(kind: kind) else { return }
        let stored = entries.map { StoredEntry(id: $0.id, name: $0.name, count: $0.count, slug: $0.slug) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Input field for one category — text + an add button, below it (while
/// ≥2 characters are typed) a dropdown suggestion list from the already-
/// known index (see ImhentaiTagSuggestionCache) — tapping a suggestion adds
/// the value and collapses the list, same as adding normally. Below that —
/// already-added values as chips (CollapsibleChips, reused as-is — tapping
/// a chip removes the value, the same trick as the onTap chips in
/// ExternalGalleryDetailView, just with a removal action here instead of
/// navigation).
private struct AdvancedFieldInput: View {
    let kind: ExternalTagKind
    @Binding var values: [String]
    @State private var draft = ""
    /// @ObservedObject, not a one-off snapshot — while the table walk runs
    /// in the background (see ImhentaiTagSuggestionCache.loadFullIndex),
    /// suggestions below grows on its own with every @Published update,
    /// with no manual filter restart needed.
    @ObservedObject private var cache = ImhentaiTagSuggestionCache.shared

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespaces) }

    /// Suggestions — substring-matched against the WHOLE local table for
    /// kind (see the ImhentaiTagSuggestionCache doc-comment), top 8 by
    /// title count. Recomputed on every re-render (draft changes — or the
    /// table grows in the background); filtering several thousand
    /// in-memory records itself is instant, no separate debounce is needed
    /// for it.
    private var suggestions: [ExternalTagEntry] {
        let trimmed = trimmedDraft
        guard trimmed.count >= 2 else { return [] }
        let lower = trimmed.lowercased()
        return Array(
            cache.entries(kind: kind)
                .filter { $0.name.lowercased().contains(lower) }
                .sorted { $0.count > $1.count }
                .prefix(8)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Добавить…", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(trimmedDraft.isEmpty ? Theme.textSecondary.opacity(0.4) : Theme.accent)
                }
                .disabled(trimmedDraft.isEmpty)
            }
            if !suggestions.isEmpty {
                suggestionList
            }
            if !values.isEmpty {
                CollapsibleChips(items: values.map { value in
                    .init(text: value, onTap: { values.removeAll { $0 == value } })
                })
            }
        }
        // Kicks off (if not already running/loaded) the full walk of the
        // table for kind — as soon as typing actually begins; idempotent,
        // extra calls per letter are harmless (see the ensureLoading guard).
        .onChange(of: draft) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespaces).count >= 2 {
                cache.ensureLoading(kind: kind)
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                Button {
                    pick(entry)
                } label: {
                    HStack {
                        Text(entry.name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Text("\(entry.count)").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    Divider().overlay(Theme.separator)
                }
            }
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pick(_ entry: ExternalTagEntry) {
        if !values.contains(entry.name) { values.append(entry.name) }
        draft = ""
    }

    private func add() {
        guard !trimmedDraft.isEmpty, !values.contains(trimmedDraft) else { return }
        values.append(trimmedDraft)
        draft = ""
    }
}

#Preview {
    ImhentaiAdvancedFieldsPicker(query: .constant(ImhentaiAdvancedQuery(tags: ["Anal", "Big breasts"])))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
