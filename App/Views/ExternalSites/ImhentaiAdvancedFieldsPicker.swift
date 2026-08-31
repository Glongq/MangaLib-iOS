import SwiftUI

/// Расширенные поля поиска ImHentai — своя строка поиска + Tags/Parodies/
/// Artists/Characters/Groups (см. /advsearch/ на самом сайте, скриншот
/// пользователя 31.08) — КАЖДОЕ поле копит СВОЙ список значений (можно
/// добавить сразу несколько тегов, несколько персонажей и т.д.), в отличие
/// от обычной строки поиска (одна строка — один текст). Значения
/// собираются в ImhentaiAdvancedQuery.clauses() — см. её doc-comment в
/// ImhentaiProvider.swift насчёт того, что именно подтверждено HAR, а что
/// нет (только `tag` подтверждён живьём).
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

    /// Своя строка поиска IMHentai (по прямой просьбе 31.08) — ОТДЕЛЬНО от
    /// Tags и от общего верхнего поиска экрана (тот у imhentai больше не
    /// участвует в запросе вообще, см. ImhentaiAdvancedQuery.searchText
    /// doc-comment / ExternalSearchView.composedQuery).
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

/// Локальная таблица алфавитного справочника IMHentai (fetchTagIndex — уже
/// подтверждён HAR, см. ImhentaiProvider) для подсказок при наборе тега
/// (см. AdvancedFieldInput ниже) — по прямой просьбе (31.08) подсказки
/// ищут ПОДСТРОКОЙ по ВСЕЙ таблице (под "anal" всплывёт и "Double Anal",
/// как на скриншоте реального сайта), а не только в пределах бакета своей
/// первой буквы, как было раньше. Раз отдельного автокомплит-эндпоинта у
/// сайта не подтверждено (ImhentaiProvider.fetchAutocomplete честно
/// пуст), таблица собирается САМИ — последовательным обходом всех
/// буквенных бакетов (a...z + "num") через уже подтверждённый
/// fetchTagIndex, один раз на инсталляцию (кэш на диск, см. cacheURL —
/// при следующем запуске приложения читается оттуда, сеть не трогается
/// заново). Обход идёт в фоне с небольшой паузой между буквами (см.
/// loadFullIndex) — сайт за Cloudflare, лишний параллелизм/бёрст ближе к
/// риску капчи/бана, чем к пользе.
@MainActor
private final class ImhentaiTagSuggestionCache: ObservableObject {
    static let shared = ImhentaiTagSuggestionCache()

    private static let allKinds: [ExternalTagKind] = [.tags, .series, .artists, .characters, .groups]
    /// "0" — сигнал "num"-бакета (см. ImhentaiProvider.fetchTagIndex —
    /// letter.isNumber), сама цифра значения не имеет.
    private static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz") + ["0"]

    @Published private var fullIndex: [ExternalTagKind: [ExternalTagEntry]] = [:]
    private var loadingTasks: [ExternalTagKind: Task<Void, Never>] = [:]

    private init() {
        for kind in Self.allKinds {
            if let cached = Self.loadFromDisk(kind: kind) {
                fullIndex[kind] = cached
            }
        }
    }

    /// Текущее локальное состояние таблицы для kind — может быть неполным,
    /// если обход ещё идёт (см. ensureLoading); AdvancedFieldInput читает
    /// это через @ObservedObject, поэтому список подсказок сам дорастает
    /// по мере обхода, без ручного перезапуска фильтра.
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
            // Промежуточное сохранение — подсказки видят частично
            // собранную таблицу сразу, не ждут ВСЕ 27 бакетов разом
            // (один бакет — это уже пагинация до 20 страниц, см.
            // fetchTagIndex doc-comment насчёт "groups/a/ — 48 страниц").
            fullIndex[kind] = merged
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        Self.saveToDisk(kind: kind, entries: merged)
        loadingTasks[kind] = nil
    }

    // MARK: Диск-кэш — обход не повторяется при каждом перезапуске приложения.

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

/// Поле ввода одной категории — текст + кнопка добавления, под ним (пока
/// печатается ≥2 символов) выпадающий список подсказок из уже известного
/// справочника (см. ImhentaiTagSuggestionCache) — тап по подсказке
/// добавляет значение и сворачивает список, как и обычное добавление.
/// Ниже — уже добавленные значения чипами (CollapsibleChips, переиспользован
/// как есть — тап по чипу убирает значение, тот же приём, что и у
/// onTap-чипов в ExternalGalleryDetailView, просто здесь действие —
/// удаление, а не переход).
private struct AdvancedFieldInput: View {
    let kind: ExternalTagKind
    @Binding var values: [String]
    @State private var draft = ""
    /// @ObservedObject, не разовый снимок — пока обход таблицы идёт в
    /// фоне (см. ImhentaiTagSuggestionCache.loadFullIndex), suggestions
    /// ниже сам дорастает на каждое @Published-обновление, без ручного
    /// перезапуска фильтра.
    @ObservedObject private var cache = ImhentaiTagSuggestionCache.shared

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespaces) }

    /// Подсказки — подстрокой по ВСЕЙ локальной таблице kind (см.
    /// ImhentaiTagSuggestionCache doc-comment), топ-8 по количеству
    /// тайтлов. Пересчитывается на каждый re-render (draft меняется — или
    /// таблица подрастает в фоне), сама фильтрация нескольких тысяч
    /// записей в памяти мгновенная, отдельного debounce на неё не нужно.
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
        // Запускает (если ещё не запущен/загружен) полный обход таблицы
        // kind — как только реально начали печатать; idempotent, лишние
        // вызовы на каждую букву безвредны (см. ensureLoading guard).
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
