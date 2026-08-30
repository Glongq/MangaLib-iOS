import Foundation

/// Персистентное (в памяти на время работы приложения — не UserDefaults,
/// не обязательно переживать перезапуск) состояние фильтров каталога
/// внешних сайтов — по прямой просьбе (30.08): "фильтры не должны
/// сбрасываться при уходе с вкладки". Раньше query/excludedCategories были
/// обычным `@State` на value-type View (ExternalSearchView/
/// ExternalCombinedCatalogView) — переключение вкладок Каталог → другая →
/// назад пересоздаёт эти вью, и весь ввод/выбранные категории терялись.
@MainActor
final class ExternalCatalogFilterStore: ObservableObject {
    static let shared = ExternalCatalogFilterStore()

    /// Одиночный сайт (ExternalSearchView) — ключ по ExternalSite, т.к. у
    /// разных сайтов разные текущие запросы/категории.
    @Published var queries: [ExternalSite: String] = [:]
    @Published var excludedCategories: [ExternalSite: Set<EHentaiCategory>] = [:]

    /// Совместный каталог «Все сайты» (ExternalCombinedCatalogView) — своё
    /// отдельное состояние, не смешивается с одиночными.
    @Published var combinedQuery: String = ""
    @Published var combinedExcludedCategories: Set<EHentaiCategory> = []

    private init() {}
}
