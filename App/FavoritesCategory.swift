import Foundation

/// 5 категорий вкладки "Избранное" (Меню → Профиль → Избранное) —
/// ПОДТВЕРЖДЕНО перехватом: `GET /favorites?user_id=&source_type=team|
/// people|character|franchise|publisher&page=&q=` (см.
/// MangaNetworkService.fetchFavorites). Порядок вкладок и "список vs
/// карточки" — по прямой просьбе: Команды/Франшизы/Издатели списком (тот же
/// стиль строки, что и в DirectoryListView/FranchiseListView), Люди/
/// Персонажи карточками (сеткой, как обложки тайтлов).
enum FavoritesCategory: String, CaseIterable, Identifiable {
    case team, people, character, franchise, publisher
    var id: String { rawValue }

    /// Значение параметра `source_type` — совпадает с rawValue у всех пяти,
    /// оставлено отдельным свойством для читаемости на месте использования.
    var sourceType: String { rawValue }

    var title: String {
        switch self {
        case .team:      return "Команды"
        case .people:    return "Люди"
        case .character: return "Персонажи"
        case .franchise: return "Франшизы"
        case .publisher: return "Издатели"
        }
    }

    var placeholderIcon: String {
        switch self {
        case .team:      return "person.3.fill"
        case .people:    return "person.crop.rectangle"
        case .character: return "face.smiling"
        case .franchise: return "sparkles"
        case .publisher: return "building.2"
        }
    }

    /// true — карточками (Люди/Персонажи), false — списком (Команды/
    /// Франшизы/Издатели).
    var isGrid: Bool { self == .people || self == .character }

    /// Куда ведёт тап по элементу — те же самые экраны, что и у обычных
    /// списков (DirectoryListView.row/FranchiseListView.row), в Избранном
    /// свой пункт назначения не заводим.
    var targetModel: String {
        switch self {
        case .team:      return "team"
        case .people:    return "people"
        case .character: return "character"
        case .franchise: return "franchise"
        case .publisher: return "publisher"
        }
    }
}
