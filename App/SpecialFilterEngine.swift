import Foundation

/// Один результат «Спец фильтра» — тайтл + сколько из ВЫБРАННЫХ жанров/тегов
/// у него реально нашлось (может быть меньше общего числа выбранного — в
/// этом весь смысл, см. SpecialFilterStore).
struct SpecialFilterResult {
    let item: MangaItem
    let matchCount: Int
}

/// «Спец фильтр» — клиентская эмуляция ранжированного (soft) поиска по
/// жанрам/тегам, которого на сервере на практике нет (см. комментарий в
/// SpecialFilterStore и в MangaNetworkService.fetchCatalog про
/// tags_soft_search). Сервер отдаёт по genres[]/tags[] строго AND — все
/// переданные id должны совпасть. Чтобы получить "сначала максимум
/// совпадений, потом чуть меньше, но не пусто" — делаем несколько запросов с
/// убывающими подмножествами выбранных id: сперва весь набор целиком, затем
/// все варианты "минус один", затем "минус два" и так далее, помечая каждый
/// найденный тайтл САМЫМ БОЛЬШИМ числом совпадений, с которым он встретился.
/// Жёсткие исключения (excluded) в переборе не участвуют — они всегда идут
/// минус-фильтром в КАЖДЫЙ запрос, как и в обычном каталоге.
@MainActor
enum SpecialFilterEngine {

    /// Перебор подмножеств размера threshold растёт как C(n, threshold) —
    /// при большом n и низком threshold это может быть много запросов;
    /// ограничиваем общий бюджет и останавливаемся раньше, если результатов
    /// уже достаточно для одного экрана каталога с запасом на скролл.
    private static let maxRequests = 40
    private static let targetResultCount = 90

    static func search(service: MangaNetworkService, query: String, sort: SortOption, sortType: String,
                        baseFilter: MangaFilter, selection: SpecialFilterStore) async throws -> [SpecialFilterResult] {
        struct Choice: Hashable { let isGenre: Bool; let id: Int }
        let all = selection.genres.included.map { Choice(isGenre: true, id: $0) }
            + selection.tags.included.map { Choice(isGenre: false, id: $0) }
        // Защита от комбинаторного взрыва — UI (SpecialFilterSettingsView)
        // и так не даёт выбрать больше SpecialFilterStore.maxSelection, но
        // подстрахуемся и здесь на случай рассинхрона данных.
        let items = Array(all.prefix(SpecialFilterStore.maxSelection))
        guard !items.isEmpty else { return [] }

        var best: [Int: SpecialFilterResult] = [:]
        var requestsUsed = 0

        levels: for threshold in stride(from: items.count, through: 1, by: -1) {
            for subset in combinations(of: items, size: threshold) {
                try Task.checkCancellation()
                guard requestsUsed < maxRequests else { break levels }
                requestsUsed += 1

                var f = baseFilter
                f.genres = TriStateSelection(
                    included: Set(subset.filter(\.isGenre).map(\.id)),
                    excluded: selection.genres.excluded
                )
                f.tags = TriStateSelection(
                    included: Set(subset.filter { !$0.isGenre }.map(\.id)),
                    excluded: selection.tags.excluded
                )

                // Единичный сбой конкретного подмножества не должен ронять
                // весь спец-поиск — остальные подмножества и уровни всё
                // ещё могут дать результат.
                guard let page = try? await service.fetchCatalog(query: query, sort: sort, filter: f,
                                                                   page: 1, sortType: sortType) else { continue }
                for manga in page.items {
                    let existing = best[manga.id]?.matchCount ?? 0
                    if threshold > existing {
                        best[manga.id] = SpecialFilterResult(item: manga, matchCount: threshold)
                    }
                }
            }
            if best.count >= targetResultCount { break levels }
        }

        return best.values.sorted {
            $0.matchCount != $1.matchCount ? $0.matchCount > $1.matchCount : $0.item.id > $1.item.id
        }
    }

    /// Все подмножества `items` размера `size`, без повторов. Перебираем
    /// сверху вниз (threshold близко к items.count), поэтому на практике это
    /// далеко не полные 2^n — C(n,n)=1, C(n,n-1)=n, C(n,n-2)=n(n-1)/2 и т.д.
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
