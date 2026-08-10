import Foundation

// MARK: - Sort

/// Варианты сортировки каталога.
enum SortOption: String, CaseIterable, Identifiable {
    case relevance
    case popularity
    case rating
    case fresh
    case name
    case chapters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance:  return "По релевантности"
        case .popularity: return "По популярности"
        case .rating:     return "По рейтингу"
        case .fresh:      return "По новизне"
        case .name:       return "По названию"
        case .chapters:   return "По числу глав"
        }
    }

    var systemImage: String {
        switch self {
        case .relevance:  return "sparkles"
        case .popularity: return "flame"
        case .rating:     return "star"
        case .fresh:      return "clock"
        case .name:       return "textformat.abc"
        case .chapters:   return "books.vertical"
        }
    }

    /// Значение параметра `sort_by` для API (nil = сортировка по умолчанию).
    var apiSortBy: String? {
        switch self {
        case .relevance:  return nil
        case .popularity: return "views"
        case .rating:     return "rate_avg"
        case .fresh:      return "last_chapter_at"
        case .name:       return "name"
        case .chapters:   return "chap_count"
        }
    }
}

// MARK: - Filter option

/// Пункт фильтра: отображаемое имя + id для API.
struct FilterOption: Identifiable, Hashable {
    let id: Int
    let title: String
}

// MARK: - Tri-state selection

/// Три состояния фильтра-элемента.
enum TriState {
    case neutral   // не участвует
    case include   // должен присутствовать
    case exclude   // должен отсутствовать
}

/// Хранилище трёхпозиционного выбора (жанры/теги): включённые и исключённые id.
struct TriStateSelection: Equatable {
    var included: Set<Int> = []
    var excluded: Set<Int> = []

    func state(of id: Int) -> TriState {
        if included.contains(id) { return .include }
        if excluded.contains(id) { return .exclude }
        return .neutral
    }

    /// Циклический переход: нейтрально → включить → исключить → нейтрально.
    mutating func cycle(_ id: Int) {
        switch state(of: id) {
        case .neutral:
            included.insert(id)
        case .include:
            included.remove(id)
            excluded.insert(id)
        case .exclude:
            excluded.remove(id)
        }
    }

    var count: Int { included.count + excluded.count }

    mutating func clear() {
        included.removeAll()
        excluded.removeAll()
    }
}

// MARK: - Filter state

/// Состояние всех фильтров каталога.
struct MangaFilter: Equatable {
    // Числовые диапазоны (пусто = не задано).
    var chaptersFrom = ""
    var chaptersTo = ""
    var yearFrom = ""
    var yearTo = ""
    var ratingFrom = ""
    var ratingTo = ""
    var votesFrom = ""
    var votesTo = ""

    // Трёхпозиционные секции (вкл / исключить / нейтрально) — везде, где есть чекбоксы.
    var genres = TriStateSelection()
    var tags = TriStateSelection()
    var genresStrict = false
    var tagsStrict = false

    var ageRatings = TriStateSelection()
    var types = TriStateSelection()
    var formats = TriStateSelection()
    var titleStatuses = TriStateSelection()
    var translationStatuses = TriStateSelection()
    var other = TriStateSelection()
    var myLists = TriStateSelection()

    /// Число активных фильтров (для бейджа).
    var activeCount: Int {
        var n = 0
        let ranges = [chaptersFrom, chaptersTo, yearFrom, yearTo, ratingFrom, ratingTo, votesFrom, votesTo]
        n += ranges.filter { !$0.isEmpty }.count
        n += genres.count + tags.count
        n += ageRatings.count + types.count + formats.count
        n += titleStatuses.count + translationStatuses.count + other.count + myLists.count
        return n
    }

    mutating func reset() { self = MangaFilter() }
}

// MARK: - Option catalogs (fallback)

/// Резервные справочники значений (пока не загружены реальные из /api/constants).
/// id жанров — настоящие серверные (site_id = 1); остальные — по известным значениям.
enum FilterCatalog {
    static let ageRatings: [FilterOption] = [
        .init(id: 4, title: "18+"),
        .init(id: 3, title: "16+"),
        .init(id: 2, title: "12+"),
        .init(id: 1, title: "6+")
    ]

    static let types: [FilterOption] = [
        .init(id: 1, title: "Манга"),
        .init(id: 5, title: "Манхва"),
        .init(id: 6, title: "Маньхуа"),
        .init(id: 4, title: "OEL-манга"),
        .init(id: 8, title: "Руманга"),
        .init(id: 9, title: "Комикс")
    ]

    static let formats: [FilterOption] = [
        .init(id: 1, title: "4-кома (Ёнкома)"),
        .init(id: 2, title: "Сборник"),
        .init(id: 3, title: "Додзинси"),
        .init(id: 4, title: "В цвете"),
        .init(id: 5, title: "Сингл"),
        .init(id: 6, title: "Веб"),
        .init(id: 7, title: "Вебтун")
    ]

    static let titleStatuses: [FilterOption] = [
        .init(id: 1, title: "Онгоинг"),
        .init(id: 2, title: "Завершён"),
        .init(id: 3, title: "Анонс"),
        .init(id: 4, title: "Приостановлен"),
        .init(id: 5, title: "Выпуск прекращён")
    ]

    static let translationStatuses: [FilterOption] = [
        .init(id: 1, title: "Продолжается"),
        .init(id: 2, title: "Завершён"),
        .init(id: 3, title: "Заморожен"),
        .init(id: 4, title: "Заброшен")
    ]

    static let other: [FilterOption] = [
        .init(id: 1, title: "Нет перевода уже 2 месяца"),
        .init(id: 2, title: "Издательский контент"),
        .init(id: 3, title: "Можно приобрести")
    ]

    static let myLists: [FilterOption] = [
        .init(id: 1, title: "Читаю"),
        .init(id: 2, title: "В планах"),
        .init(id: 3, title: "Брошено"),
        .init(id: 4, title: "Прочитано"),
        .init(id: 5, title: "Любимые")
    ]

    /// Жанры с реальными серверными id (site_id = 1), по алфавиту.
    static let genres: [FilterOption] = [
        .init(id: 32, title: "Арт"),
        .init(id: 91, title: "Безумие"),
        .init(id: 34, title: "Боевик"),
        .init(id: 35, title: "Боевые искусства"),
        .init(id: 36, title: "Вампиры"),
        .init(id: 89, title: "Военное"),
        .init(id: 37, title: "Гарем"),
        .init(id: 38, title: "Гендерная интрига"),
        .init(id: 39, title: "Героическое фэнтези"),
        .init(id: 81, title: "Демоны"),
        .init(id: 40, title: "Детектив"),
        .init(id: 41, title: "Дзёсэй"),
        .init(id: 43, title: "Драма"),
        .init(id: 44, title: "Игра"),
        .init(id: 79, title: "Исекай"),
        .init(id: 45, title: "История"),
        .init(id: 46, title: "Киберпанк"),
        .init(id: 76, title: "Кодомо"),
        .init(id: 47, title: "Комедия"),
        .init(id: 83, title: "Космос"),
        .init(id: 85, title: "Магия"),
        .init(id: 48, title: "Махо-сёдзё"),
        .init(id: 90, title: "Машины"),
        .init(id: 49, title: "Меха"),
        .init(id: 50, title: "Мистика"),
        .init(id: 80, title: "Музыка"),
        .init(id: 51, title: "Научная фантастика"),
        .init(id: 77, title: "Омегаверс"),
        .init(id: 86, title: "Пародия"),
        .init(id: 52, title: "Повседневность"),
        .init(id: 82, title: "Полиция"),
        .init(id: 53, title: "Постапокалиптика"),
        .init(id: 54, title: "Приключения"),
        .init(id: 55, title: "Психология"),
        .init(id: 56, title: "Романтика"),
        .init(id: 57, title: "Самурайский боевик"),
        .init(id: 58, title: "Сверхъестественное"),
        .init(id: 59, title: "Сёдзё"),
        .init(id: 61, title: "Сёнэн"),
        .init(id: 63, title: "Спорт"),
        .init(id: 87, title: "Супер сила"),
        .init(id: 64, title: "Сэйнэн"),
        .init(id: 65, title: "Трагедия"),
        .init(id: 66, title: "Триллер"),
        .init(id: 67, title: "Ужасы"),
        .init(id: 68, title: "Фантастика"),
        .init(id: 69, title: "Фэнтези"),
        .init(id: 70, title: "Школа"),
        .init(id: 71, title: "Эротика"),
        .init(id: 72, title: "Этти")
    ]

    /// Теги (fallback: имена из ТЗ, id синтетические — реальные подтягиваются из /api/constants).
    static let tags: [FilterOption] = [
        "Азартные игры", "Алхимия", "Амнезия / Потеря памяти", "Ангелы", "Антигерой",
        "Антиутопия", "Апокалипсис", "Армия", "Артефакты", "Боги", "Бои на мечах",
        "Борьба за власть", "Брат и сестра", "Будущее", "Ведьма", "Вестерн", "Видеоигры",
        "Викторианская эпоха", "Виртуальная реальность", "Владыка демонов", "Военные",
        "Война", "Волшебники / маги", "Волшебные существа", "Воспоминания из другого мира",
        "Выживание", "Гайдверс", "ГГ - Мэри Сью", "ГГ женщина", "ГГ имба", "ГГ мужчина",
        "ГГ не ояш", "ГГ не человек", "Геймеры", "Гильдии", "Глупый ГГ", "Гоблины",
        "Горничные", "Градостроение", "Гуро", "Гяру", "Демоны", "Драконы", "Дружба",
        "Жестокий мир", "Животные компаньоны", "Завоевание мира", "Запугивание",
        "Зверолюди", "Злые духи", "Зомби", "Игровые элементы", "Империи", "Исторические",
        "Камера", "Квесты", "Космос", "Кулинария", "Культивирование", "ЛГБТ",
        "Легендарное оружие", "Литрес", "Лоли", "Магическая академия", "Магия", "Мафия",
        "Медицина", "Месть", "Монстродевушки", "Монстры", "Мурим", "Навыки / способности",
        "Наёмники", "Насилие / жестокость", "Нежить", "Ниндзя", "Обмен телами",
        "Обратный Гарем", "Огнестрельное оружие", "Офисные Работники", "Пародия", "Пираты",
        "Подземелья", "Политика", "Полиция", "Полностью CGI", "Полноцветный",
        "Преступники / Криминал", "Призраки / Духи", "Путешествие во времени", "Рабы",
        "Разумные расы", "Ранги силы", "Регрессия", "Реинкарнация", "Роботы", "Рыцари",
        "Самураи", "Сгенерировано ИИ", "Система", "Скрытие личности", "Современность",
        "Спасение мира", "Спортивное тело", "Средневековье", "Стимпанк", "Супергерои",
        "Традиционные игры", "Умный ГГ", "Учитель", "Фермерство", "Философия",
        "Фэнтези мир", "Хикикомори", "Холодное оружие", "Шантаж", "Шоу-бизнес", "Эльфы",
        "Якудза", "Яндере", "Япония"
    ].enumerated().map { FilterOption(id: $0.offset + 1, title: $0.element) }
}
