import SwiftUI

/// Advanced search fields for Simply Hentai — its own search box + Series
/// title (a single line) + Tags/Parodies/Characters/Artists/Translators/
/// Language (each accumulates ITS OWN list of values) — these combine
/// together into one `/search/complex` request (see the
/// SimplyHentaiAdvancedQuery doc-comment in SimplyHentaiProvider.swift —
/// the `query=` + `filter[...]=` combination is confirmed by the user's
/// real HAR), but EXCLUSIVELY with respect to the screen's shared search
/// field — as soon as at least one of these is filled in, the shared field
/// stops participating for simplyHentai (see
/// ExternalSearchView.resolvedQuery).
struct SimplyHentaiAdvancedFieldsPicker: View {
    @Binding var query: SimplyHentaiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            searchField
            seriesTitleField
            field("Tags", values: $query.tags)
            field("Parodies", values: $query.parodies)
            field("Characters", values: $query.characters)
            field("Artists", values: $query.artists)
            field("Translators", values: $query.translators)
            field("Language", values: $query.language)
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Поиск").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField("Свободный текст…", text: $query.search)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// A single line (not a chip list like the others) — `filter
    /// [series_title][0]=...` showed up in the HAR with EXACTLY one value,
    /// not several at once, unlike Tags/Parodies/....
    private var seriesTitleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Series title").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField("Название серии…", text: $query.seriesTitle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func field(_ title: String, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            AdvancedFieldInput(values: values)
        }
    }
}

/// Input field for one category — text + an add button, below it (while
/// ≥2 characters are typed) a dropdown suggestion list from the REAL
/// `/v3/search/autocomplete?q=` endpoint (confirmed by HAR with a live
/// array of suggestions) — unlike imhentai/hentaipill, nothing needs to be
/// built up locally here, the site itself hands back ready-made options.
/// Suggestions are NOT split by field type (the site doesn't accept a
/// namespace/type parameter on this endpoint, see the fetchAutocomplete
/// doc-comment) — the very same list is shown for both Tags and Artists;
/// that's not ideal, but it honestly reflects what the API actually does.
/// Tapping a suggestion adds the value and collapses the list, same as
/// adding normally. Below that — already-added values as chips
/// (CollapsibleChips, the same trick as in ImhentaiAdvancedFieldsPicker).
private struct AdvancedFieldInput: View {
    @Binding var values: [String]
    @State private var draft = ""
    @State private var suggestions: [ExternalTagSuggestion] = []

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespaces) }

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
        // Debounce of 350ms — the same trick as ExternalSearchView.query,
        // otherwise every letter would fire off a separate network request.
        // .task(id:) cancels the previous attempt on its own on new input.
        .task(id: draft) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await updateSuggestions()
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, entry in
                Button {
                    pick(entry)
                } label: {
                    Text(entry.name)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func updateSuggestions() async {
        let trimmed = trimmedDraft
        guard trimmed.count >= 2 else {
            suggestions = []
            return
        }
        let provider = ExternalSiteRegistry.provider(for: .simplyHentai)
        guard let results = try? await provider.fetchAutocomplete(query: trimmed, namespace: nil) else {
            suggestions = []
            return
        }
        guard !Task.isCancelled, trimmedDraft == trimmed else { return }
        suggestions = Array(results.prefix(8))
    }

    private func pick(_ entry: ExternalTagSuggestion) {
        if !values.contains(entry.name) { values.append(entry.name) }
        draft = ""
        suggestions = []
    }

    private func add() {
        guard !trimmedDraft.isEmpty, !values.contains(trimmedDraft) else { return }
        values.append(trimmedDraft)
        draft = ""
        suggestions = []
    }
}

#Preview {
    SimplyHentaiAdvancedFieldsPicker(query: .constant(SimplyHentaiAdvancedQuery(tags: ["Bondage", "Ahegao"])))
        .padding(16)
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
