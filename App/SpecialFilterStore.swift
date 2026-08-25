import Foundation

/// «Спец фильтр» — просто персистентный флаг уровня приложения (как
/// ThemeManager/SiteSession), НЕ отдельный выбор жанров/тегов: сам выбор
/// по-прежнему делается там же, где и всегда — в обычной шторке "Фильтры"
/// каталога (MangaFilter.genres/tags). Этот флаг только переключает, КАК
/// каталог трактует уже выбранные там жанры/теги — см. CatalogViewModel и
/// SpecialFilterEngine:
/// - выключен (по умолчанию) — как раньше, строгое совпадение ВСЕХ сразу
///   (это то, что реально шлёт сервер по genres[]/tags[]);
/// - включён — клиент сам ищет "сначала максимум совпадений, потом чуть
///   меньше", не требуя попадания абсолютно всех выбранных пунктов сразу
///   (сервер такого сам не умеет, см. подробности в SpecialFilterEngine).
@MainActor
final class SpecialFilterStore: ObservableObject {

    static let shared = SpecialFilterStore()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    private static let key = "specialFilter.enabled.v2"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
    }
}
