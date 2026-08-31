import SwiftUI

/// Расширенные поля поиска Simply Hentai — Series title (одна строка) +
/// Tags/Parodies/Characters/Artists/Translators/Language (каждое копит
/// СВОЙ список значений) — все вместе combинируются с общим полем поиска
/// экрана в одном запросе `/search/complex` (см. SimplyHentaiAdvancedQuery
/// doc-comment в SimplyHentaiProvider.swift — комбинация `query=`+
/// `filter[...]=` подтверждена реальным HAR пользователя).
struct SimplyHentaiAdvancedFieldsPicker: View {
    @Binding var query: SimplyHentaiAdvancedQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            seriesTitleField
            field("Tags", values: $query.tags)
            field("Parodies", values: $query.parodies)
            field("Characters", values: $query.characters)
            field("Artists", values: $query.artists)
            field("Translators", values: $query.translators)
            field("Language", values: $query.language)
        }
    }

    /// Одиночная строка (не список чипов, как остальные) — `filter
    /// [series_title][0]=...` в HAR встретился РОВНО одним значением, не
    /// несколькими сразу, в отличие от Tags/Parodies/....
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

/// Поле ввода одной категории — текст + кнопка добавления, под ним (пока
/// печатается ≥2 символов) выпадающий список подсказок из РЕАЛЬНОГО
/// эндпоинта `/v3/search/autocomplete?q=` (подтверждён HAR живым массивом
/// подсказок) — в отличие от imhentai/hentaipill, здесь не нужно ничего
/// достраивать локально, сайт сам отдаёт готовые варианты. Подсказки НЕ
/// разделены по типу поля (сайт не принимает namespace/type-параметр на
/// этом эндпоинте, см. doc-comment fetchAutocomplete) — один и тот же
/// список показывается что для Tags, что для Artists; это не идеально, но
/// честно отражает то, что реально умеет API. Тап по подсказке добавляет
/// значение и сворачивает список, как и обычное добавление. Ниже — уже
/// добавленные значения чипами (CollapsibleChips, тот же приём, что у
/// ImhentaiAdvancedFieldsPicker).
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
        // Debounce 350мс — тот же приём, что у ExternalSearchView.query,
        // иначе каждая буква била бы отдельным сетевым запросом. .task(id:)
        // сам отменяет предыдущую попытку при новом вводе.
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
