import Foundation

/// Мостик «меню → каталог»: когда в меню «Тайтлы» выбирают тип (Манга/Манхва/…),
/// сюда кладётся его id (см. FilterCatalog.types), а RootView переключает вкладку
/// на «Каталог». MangaCatalogView.onAppear считывает и сбрасывает это значение,
/// применяя фильтр по типу. Каталог при переключении вкладок пересоздаётся, так
/// что общее значение здесь — простейший способ донести выбор до нового экрана.
@MainActor
final class CatalogNavigator {
    static let shared = CatalogNavigator()
    private init() {}

    /// id типа тайтла для фильтра при следующем показе каталога (nil — ничего).
    var pendingTypeId: Int?
}
