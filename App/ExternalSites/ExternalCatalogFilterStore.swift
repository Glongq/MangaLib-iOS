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
    /// То же самое, но для ImhentaiCategory (своя, непересекающаяся схема
    /// категорий — см. ImhentaiCategory.bit doc-comment) — отдельный набор,
    /// т.к. e-hentai и imhentai могут быть оба выбраны одновременно
    /// (см. combinedExcludedImhentaiCategories) и у каждого своё множество.
    @Published var excludedImhentaiCategories: [ExternalSite: Set<ImhentaiCategory>] = [:]
    /// Языки imhentai (см. ImhentaiLanguage.bit doc-comment) — тот же
    /// принцип, что и excludedImhentaiCategories, отдельное измерение
    /// фильтра, тот же общий bitmask-канал.
    @Published var excludedImhentaiLanguages: [ExternalSite: Set<ImhentaiLanguage>] = [:]
    /// Расширенные поля поиска (Tags/Parodies/Artists/Characters/Groups,
    /// см. ImhentaiAdvancedQuery/ImhentaiAdvancedFieldsPicker) — тот же
    /// принцип персистентности, что и у остального в этом файле.
    @Published var imhentaiAdvancedQueries: [ExternalSite: ImhentaiAdvancedQuery] = [:]
    /// Расширенные поля поиска Simply Hentai (Tags/Parodies/Characters/
    /// Artists/Translators/Language/Series title, см.
    /// SimplyHentaiAdvancedQuery/SimplyHentaiAdvancedFieldsPicker) — тот же
    /// принцип, что и у imhentaiAdvancedQueries.
    @Published var simplyHentaiAdvancedQueries: [ExternalSite: SimplyHentaiAdvancedQuery] = [:]
    /// Расширенные поля E-Hentai (Tags/Parodies/Characters/Artists/Groups +
    /// собственный search, см. EHentaiAdvancedQuery/EHentaiAdvancedFieldsPicker).
    @Published var ehentaiAdvancedQueries: [ExternalSite: EHentaiAdvancedQuery] = [:]
    /// Расширенное поле 3Hentai (Tags + собственный search, см.
    /// ThreeHentaiAdvancedQuery/ThreeHentaiAdvancedFieldsPicker).
    @Published var threeHentaiAdvancedQueries: [ExternalSite: ThreeHentaiAdvancedQuery] = [:]
    /// Выбор ОДНОГО измерения+значения HentaiPill (Tags/Parodies/
    /// Characters/Artists — сайт не умеет их комбинировать, см.
    /// HentaiPillAdvancedQuery/HentaiPillAdvancedFieldsPicker).
    @Published var hentaiPillAdvancedQueries: [ExternalSite: HentaiPillAdvancedQuery] = [:]

    /// Совместный каталог «Все сайты» (ExternalCombinedCatalogView) — своё
    /// отдельное состояние, не смешивается с одиночными.
    @Published var combinedQuery: String = ""
    @Published var combinedExcludedCategories: Set<EHentaiCategory> = []
    @Published var combinedExcludedImhentaiCategories: Set<ImhentaiCategory> = []
    @Published var combinedExcludedImhentaiLanguages: Set<ImhentaiLanguage> = []
    @Published var combinedImhentaiAdvancedQuery = ImhentaiAdvancedQuery()
    @Published var combinedSimplyHentaiAdvancedQuery = SimplyHentaiAdvancedQuery()
    @Published var combinedEHentaiAdvancedQuery = EHentaiAdvancedQuery()
    @Published var combinedThreeHentaiAdvancedQuery = ThreeHentaiAdvancedQuery()
    @Published var combinedHentaiPillAdvancedQuery = HentaiPillAdvancedQuery()
    /// Активный чип в листе «Фильтры» совместного каталога — какой раздел
    /// сейчас показан (см. ExternalCombinedCatalogView.filtersSheet). nil =
    /// «Все» (все секции разом, старое поведение). Персистентно — та же
    /// причина, что и у остального состояния в этом файле: лист
    /// пересоздаётся при каждом открытии, положение чипа не должно
    /// сбрасываться.
    @Published var combinedFiltersActiveSite: ExternalSite?

    private init() {}
}
