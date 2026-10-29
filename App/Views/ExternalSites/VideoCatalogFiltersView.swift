import SwiftUI

struct Rule34VideoFiltersView: View {
    @Binding var query: Rule34VideoQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rule34Video").font(.headline)
            entitySection(.tag, all: $query.allTags)
            entitySection(.category, all: $query.allCategories)
            entitySection(.artist, all: $query.allArtists)
            VStack(alignment: .leading, spacing: 8) {
                Text("Тип и источник").font(.subheadline)
                ForEach([("2109", "Straight"), ("192", "Gay"), ("15", "Futa"), ("4747", "Music"), ("1821", "Iwara")], id: \.0) { key, name in
                    Toggle(name, isOn: Binding(get: { query.types.contains(key) }, set: {
                        if $0 { query.types.insert(key) } else { query.types.remove(key) }
                    }))
                }
            }
            VideoSortChoices(value: $query.sort, options: [
                ("", "По умолчанию"), ("post_date", "Дата добавления"), ("video_viewed", "Просмотры за всё время"),
                ("video_viewed_month", "Просмотры за месяц"), ("video_viewed_week", "Просмотры за неделю"),
                ("video_viewed_today", "Просмотры за день"), ("rating", "Рейтинг"), ("duration", "Длительность"), ("pseudo_rand", "Случайно")
            ])
            VideoFilterMenu(title: "Дата добавления", value: $query.period, options: [
                ("", "За всё время"), ("1", "За сутки"), ("2", "За два дня"), ("3", "За неделю"),
                ("4", "За месяц"), ("5", "За три месяца"), ("6", "За год"), ("custom", "Выбрать даты")
            ])
            if query.period == "custom" {
                dateField("От", value: $query.dateFrom)
                dateField("До", value: $query.dateTo)
                if !query.dateFrom.isEmpty && !query.dateTo.isEmpty && query.dateFrom > query.dateTo {
                    Text("Дата «От» должна быть раньше даты «До».").font(.caption).foregroundStyle(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Длительность, минуты").font(.subheadline)
                HStack {
                    minuteField("От", seconds: $query.durationFrom)
                    minuteField("До", seconds: $query.durationTo)
                }
                HStack {
                    durationButton("< 1", from: "", to: "60")
                    durationButton("1–5", from: "60", to: "300")
                    durationButton("5–20", from: "300", to: "1200")
                    durationButton("> 20", from: "1200", to: "")
                    Button("Все") { query.durationFrom = ""; query.durationTo = "" }
                }.font(.caption).buttonStyle(.bordered)
            }
            VideoFilterMenu(title: "Качество", value: $query.quality, options: [("", "Любое"), ("1", "720p и выше"), ("2", "1080p и выше"), ("3", "4K")])
            VideoFilterMenu(title: "Загрузивший", value: $query.verification, options: [("", "Все"), ("1", "Подтверждённые"), ("2", "Неподтверждённые")])
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
    }

    private func entitySection(_ kind: Rule34VideoEntity.Kind, all: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title).font(.subheadline)
            Rule34VideoEntityInput(kind: kind, selected: $query.entities)
            if query.entities.filter({ $0.kind == kind && !$0.excluded }).count > 1 {
                Text("Совпадение выбранных: \(kind.title.lowercased())").font(.caption).foregroundStyle(Theme.textSecondary)
                Picker("Совпадение выбранных", selection: all) {
                    Text("Хотя бы один").tag(false)
                    Text("Все вместе").tag(true)
                }.pickerStyle(.segmented)
            }
        }
    }
    private func durationButton(_ title: String, from: String, to: String) -> some View {
        Button(title) { query.durationFrom = from; query.durationTo = to }
    }
    private func minuteField(_ title: String, seconds: Binding<String>) -> some View {
        TextField(title, text: Binding(get: {
            guard let value = Int(seconds.wrappedValue) else { return "" }; return String(value / 60)
        }, set: {
            seconds.wrappedValue = Int($0.filter(\.isNumber).prefix(7)).map { String($0 * 60) } ?? ""
        }))
        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
    }
    private func dateField(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { !value.wrappedValue.isEmpty }, set: {
                value.wrappedValue = $0 ? Self.dateString(Date()) : ""
            }))
            if !value.wrappedValue.isEmpty {
                DatePicker(title, selection: Binding(get: { Self.formatter.date(from: value.wrappedValue) ?? Date() }, set: {
                    value.wrappedValue = Self.dateString($0)
                }), displayedComponents: .date).labelsHidden()
            }
        }
    }
    private static var formatter: DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    private static func dateString(_ value: Date) -> String { formatter.string(from: value) }
}

private struct Rule34VideoEntityInput: View {
    let kind: Rule34VideoEntity.Kind
    @Binding var selected: [Rule34VideoEntity]
    @State private var text = ""
    @State private var suggestions: [Rule34VideoEntity] = []
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(selected.filter { $0.kind == kind }) { item in
                HStack {
                    Image(systemName: item.excluded ? "minus.circle" : "plus.circle").foregroundStyle(item.excluded ? .orange : Theme.accent)
                    Text(item.name)
                    Spacer()
                    Button { selected.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Удалить \(item.name)")
                }.font(.footnote)
            }
            TextField("Найти на сайте…", text: $text).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            if loading { ProgressView().controlSize(.small) }
            if failed { Text("Не удалось получить подсказки сайта.").font(.caption).foregroundStyle(Theme.textSecondary) }
            ForEach(suggestions.filter { candidate in !selected.contains(where: { $0.id == candidate.id }) }) { item in
                HStack {
                    Button { add(item, excluded: false) } label: {
                        HStack { Text(item.name).multilineTextAlignment(.leading); Spacer(); Text("\(item.count)").foregroundStyle(Theme.textSecondary); Image(systemName: "plus.circle") }
                            .contentShape(Rectangle())
                    }
                    Button { add(item, excluded: true) } label: { Image(systemName: "minus.circle").foregroundStyle(.orange).padding(.leading, 8) }
                        .accessibilityLabel("Исключить \(item.name)")
                }.font(.footnote).padding(.vertical, 3).buttonStyle(.plain)
            }
            if !text.isEmpty && !loading && !failed && suggestions.isEmpty {
                Text("Ничего не найдено").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .task(id: text) {
            suggestions = []; failed = false; loading = false
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation()
                loading = true
                let values = try await Rule34VideoProvider.suggestions(value, kind: kind)
                try Task.checkCancellation()
                suggestions = values; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true; loading = false
            }
        }
    }
    private func add(_ item: Rule34VideoEntity, excluded: Bool) {
        guard !selected.contains(where: { $0.id == item.id }) else { return }
        var value = item; value.excluded = excluded; selected.append(value)
        text = ""
    }
}

struct Rule34CatalogFiltersView: View {
    @Binding var query: Rule34CatalogQuery
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rule34").font(.headline)
            Rule34TagInput(included: $query.included, excluded: $query.excluded)
            if query.included.count > 1 {
                Text("Совпадение выбранных тегов").font(.caption).foregroundStyle(Theme.textSecondary)
                Picker("Совпадение тегов", selection: $query.matchAll) {
                    Text("Хотя бы один").tag(false); Text("Все вместе").tag(true)
                }.pickerStyle(.segmented)
            }
            VideoSortChoices(value: $query.sort, options: [
                ("", "Новые"), ("id:asc", "Старые"), ("score:desc", "Лучшие оценки"),
                ("updated:desc", "Недавно обновлённые"), ("random", "Случайно"), ("width:desc", "Ширина"), ("height:desc", "Высота")
            ])
            VideoFilterMenu(title: "Рейтинг контента", value: $query.rating, options: [("", "Любой"), ("safe", "Safe"), ("questionable", "Questionable"), ("explicit", "Explicit")])
            TextField("Загрузивший пользователь", text: $query.uploader).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack { number("Оценка от", value: $query.minScore); number("Ширина от, px", value: $query.minWidth); number("Высота от, px", value: $query.minHeight) }
        }.foregroundStyle(Theme.textPrimary).tint(Theme.accent)
    }
    private func number(_ title: String, value: Binding<String>) -> some View {
        TextField(title, text: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = String($0.filter(\.isNumber).prefix(7)) }))
            .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
    }
}

private struct Rule34TagInput: View {
    @Binding var included: [String]
    @Binding var excluded: [String]
    @State private var text = ""
    @State private var suggestions: [ExternalTagSuggestion] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(included + excluded, id: \.self) { tag in
                HStack {
                    Image(systemName: excluded.contains(tag) ? "minus.circle" : "plus.circle")
                    Text(tag); Spacer()
                    Button { included.removeAll { $0 == tag }; excluded.removeAll { $0 == tag } } label: { Image(systemName: "xmark.circle.fill") }
                }.font(.footnote)
            }
            TextField("Найти тег или автора…", text: $text).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let error { Text(error).font(.caption).foregroundStyle(Theme.textSecondary) }
            ForEach(suggestions.filter { !included.contains($0.name) && !excluded.contains($0.name) }, id: \.name) { item in
                HStack {
                    Button { included.append(item.name); text = "" } label: { HStack { Text(item.name); Spacer(); Image(systemName: "plus.circle") }.contentShape(Rectangle()) }
                    Button { excluded.append(item.name); text = "" } label: { Image(systemName: "minus.circle").foregroundStyle(.orange).padding(.leading, 8) }
                }.buttonStyle(.plain).font(.footnote).padding(.vertical, 3)
            }
        }.task(id: text) {
            suggestions = []; error = nil
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation()
                let result = try await Rule34Provider().fetchAutocomplete(query: text, namespace: nil)
                try Task.checkCancellation(); suggestions = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Не удалось получить подсказки сайта."
            }
        }
    }
}

private struct VideoFilterMenu: View {
    let title: String
    @Binding var value: String
    let options: [(String, String)]
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Picker(title, selection: $value) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden()
        }
    }
}

/// Sorting is one explicit choice, presented as separate rows rather than a combined label.
private struct VideoSortChoices: View {
    @Binding var value: String
    let options: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Сортировка").font(.subheadline).padding(.bottom, 8)
            ForEach(options, id: \.0) { key, title in
                Button { value = key } label: {
                    HStack {
                        Text(title).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: value == key ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(value == key ? Theme.accent : Theme.textSecondary)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(value == key ? .isSelected : [])
            }
        }
    }
}
