import SwiftUI

/// Alphabetical index of tags/series/characters/artists for an external
/// site (see the plan, Part 4) — letters A-Z/123 at the top, a section
/// picker, a list of name + title count. Tapping a row navigates to the
/// catalog filtered by that value (see ExternalCatalogGridView, Part 6).
struct ExternalTagBrowserView: View {
    let site: ExternalSite

    @State private var kind: ExternalTagKind = .tags
    /// `Swift.Character`, not bare `Character` — see the doc-comment on
    /// ExternalSiteProvider.fetchTagIndex (our own `Character` type in
    /// MangaModels.swift shadows the standard single-letter type across
    /// the whole module).
    @State private var letter: Swift.Character = "a"
    @State private var entries: [ExternalTagEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    private static let letters: [Swift.Character] = ["#"] + Array("abcdefghijklmnopqrstuvwxyz")

    var body: some View {
        VStack(spacing: 0) {
            kindPicker
            letterPicker
            content
        }
        .navigationTitle("Список тегов")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .task(id: "\(kind)-\(letter)") { await load() }
    }

    /// "Groups" is shown only if the provider can actually return
    /// something for this section (3hentai.net and imhentai.xxx can, see
    /// ThreeHentaiProvider.fetchTagIndex / ImhentaiProvider.fetchTagIndex);
    /// hitomi/e-hentai have no such index (HitomiProvider.fetchTagIndex
    /// honestly returns [] for .groups, EHentaiProvider returns [] for
    /// any kind) — the segment is simply not shown, so it doesn't lead
    /// into a list that's guaranteed to be empty.
    private var showsGroups: Bool { site == .threeHentai || site == .imhentai }

    private var kindPicker: some View {
        Picker("", selection: $kind) {
            Text("Теги").tag(ExternalTagKind.tags)
            Text("Серии").tag(ExternalTagKind.series)
            Text("Персонажи").tag(ExternalTagKind.characters)
            Text("Художники").tag(ExternalTagKind.artists)
            if showsGroups {
                Text("Группы").tag(ExternalTagKind.groups)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var letterPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.letters, id: \.self) { char in
                    let active = char == letter
                    Button {
                        letter = char
                    } label: {
                        Text(char == "#" ? "123" : String(char).uppercased())
                            .font(.footnote.weight(active ? .semibold : .medium))
                            .foregroundStyle(active ? Theme.background : Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(active ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, entries.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await load() } }, fillScreen: true)
        } else if entries.isEmpty {
            StateView(icon: "tag", title: "Пусто на эту букву", fillScreen: true)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        NavigationLink {
                            // entry.slug, NOT entry.name — slug is what
                            // actually goes into the URL/nozomi (for gendered
                            // tags it carries a "female:"/"male:" prefix)
                            // that the site strips only for display (see
                            // entry.name/HitomiProvider.parseTagList and the
                            // plan, PART A.2) — this used to be entry.name,
                            // which made every gendered tag hit a nonexistent
                            // "bare" path and 404.
                            ExternalCatalogGridView(site: site, query: .tag(namespace: namespace(for: kind), value: entry.slug.removingPercentEncoding ?? entry.slug), title: entry.name)
                        } label: {
                            row(entry)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Theme.separator).padding(.leading, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func row(_ entry: ExternalTagEntry) -> some View {
        HStack {
            Text(entry.name)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(entry.count)")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func namespace(for kind: ExternalTagKind) -> ExternalTagNamespace {
        switch kind {
        case .tags: return .tag
        case .series: return .series
        case .characters: return .character
        case .artists: return .artist
        case .groups: return .group
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await provider.fetchTagIndex(kind: kind, letter: letter == "#" ? "1" : letter)
        } catch {
            entries = []
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        ExternalTagBrowserView(site: .hitomi)
    }
    .preferredColorScheme(.dark)
}
