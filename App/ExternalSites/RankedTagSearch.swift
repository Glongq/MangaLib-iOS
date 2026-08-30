import Foundation

/// Общий ранжированный поиск по нескольким тегам внешнего сайта (см. план,
/// Часть 5) — ТА ЖЕ ИДЕЯ алгоритма, что у App/SpecialFilterEngine.swift
/// (перебор подмножеств выбранных тегов от большего к меньшему, ранжирование
/// по числу совпадений), но ПРОДУБЛИРОВАНА здесь целиком, по прямому
/// решению — не трогаем/не переиспользуем SpecialFilterEngine.swift.
///
/// Отличие от LibSite-версии: там подмножество проверяется ОДНИМ сетевым
/// запросом (сервер сам умеет AND по genres[]/tags[]). У hitomi.la такого
/// запроса нет — вместо этого каждый ВЫБРАННЫЙ тег запрашивается ОТДЕЛЬНО
/// (один .nozomi-запрос на тег, не на подмножество), а совпадение по
/// подмножеству считается ПЕРЕСЕЧЕНИЕМ уже полученных множеств ID —
/// локально, без лишних сетевых запросов.
@MainActor
enum RankedTagSearch {
    struct Choice: Hashable {
        let namespace: ExternalTagNamespace
        let value: String
    }

    struct Result {
        let id: Int
        let matchCount: Int
    }

    /// Не больше 6 выбранных тегов сразу — иначе полный перебор подмножеств
    /// (2^n - 1) взрывается (см. тот же лимит и ту же причину в
    /// SpecialFilterEngine.maxItems).
    static let maxItems = 6
    private static let targetResultCount = 90
    /// Сколько ID тянуть на КАЖДЫЙ отдельный тег перед пересечением — у
    /// hitomi популярные теги (например "japanese") могут насчитывать
    /// сотни тысяч тайтлов; тянуть их все ради пересечения нецелесообразно
    /// (трафик/время). Пересечение считается в пределах первых
    /// perTagLimit ID каждого тега — ИЗВЕСТНОЕ упрощение (может пропустить
    /// совпадения за пределами этого окна), нормально для MVP.
    private static let perTagLimit = 400

    static func search(provider: any ExternalSiteProvider, choices: [Choice]) async -> [Result] {
        let items = Array(choices.prefix(maxItems))
        guard !items.isEmpty else { return [] }

        var idSets: [Choice: Set<Int>] = [:]
        for choice in items {
            guard let (ids, _) = try? await provider.fetchIdsByTag(
                namespace: choice.namespace, value: choice.value, offset: 0, limit: perTagLimit
            ) else { continue }
            idSets[choice] = Set(ids)
        }
        guard !idSets.isEmpty else { return [] }

        var best: [Int: Int] = [:]
        levels: for threshold in stride(from: items.count, through: 1, by: -1) {
            for subset in combinations(of: items, size: threshold) {
                let sets = subset.compactMap { idSets[$0] }
                guard sets.count == subset.count, let first = sets.first else { continue }
                let intersection = sets.dropFirst().reduce(first) { $0.intersection($1) }
                for id in intersection where threshold > (best[id] ?? 0) {
                    best[id] = threshold
                }
            }
            if best.count >= targetResultCount { break levels }
        }

        return best
            .map { Result(id: $0.key, matchCount: $0.value) }
            .sorted { $0.matchCount != $1.matchCount ? $0.matchCount > $1.matchCount : $0.id > $1.id }
    }

    /// Копия SpecialFilterEngine.combinations — все подмножества `items`
    /// размера `size`, без повторов.
    private static func combinations<T>(of items: [T], size: Int) -> [[T]] {
        guard size > 0, size <= items.count else { return [] }
        guard size < items.count else { return [items] }
        var result: [[T]] = []
        func pick(_ start: Int, _ current: [T]) {
            if current.count == size { result.append(current); return }
            let remaining = size - current.count
            guard items.count - start >= remaining else { return }
            pick(start + 1, current + [items[start]])
            pick(start + 1, current)
        }
        pick(0, [])
        return result
    }
}
