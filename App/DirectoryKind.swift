import Foundation

/// Один вариант сортировки списка каталожной сущности — сервер у каждого
/// вида принимает свой набор `sort_by` (см. DirectoryKind), общего enum не
/// делаем, чтобы не городить значения, каких конкретный вид не поддерживает.
struct DirectorySortOption: Identifiable, Hashable {
    let apiValue: String
    let title: String
    var id: String { apiValue }
}

/// Конфигурация одного вида "каталожной" сущности экосистемы — команды/
/// персонажи/люди/издательства: список (`GET {apiPath}`), деталь (`GET
/// {apiPath}/{slug}`), грид тайтлов (`GET /manga?target_id=&target_model=`),
/// подписка (`POST /favorites {source_type}`, если подтверждена) — везде
/// один и тот же паттерн, см. DirectoryEntity/DirectoryListView/
/// DirectoryDetailView. Франшиза сделана отдельно (Franchise/
/// FranchiseListView/FranchiseView) — своя, чуть другая форма (без
/// обложки), появилась раньше, трогать не стал.
struct DirectoryKind {
    let apiPath: String
    /// nil — подписка недоступна: реального перехвата `POST /favorites` с
    /// этим `source_type` нет. Список персонажа реально ПРИСЫЛАЕТ поле
    /// `subscription`, но ни разу не поймали, что toggle им действительно
    /// управляет — рисковать записью в реальный аккаунт наугад не стали (та
    /// же осторожность, что и в CharacterView).
    let sourceType: String?
    let title: String
    let placeholderIcon: String
    let targetModel: String
    let sortOptions: [DirectorySortOption]
    let defaultSort: DirectorySortOption

    // "По лайкам" (likes_count) — ПОДТВЕРЖДЕНО перехватом. Остальные три —
    // ПО АНАЛОГИИ с уже подтверждёнными sort_by у Персонажей/Людей/
    // Издательств ниже (subscribes_count/name/titles_count — те же самые
    // значения параметра, просто у команд отдельно такого перехвата не
    // было) — если сервер какое-то из них не примет, он его просто
    // проигнорирует (см. общий комментарий DirectoryKind выше про `q`).
    static let team = DirectoryKind(
        apiPath: "/teams", sourceType: nil, title: "Команды", placeholderIcon: "person.3.fill",
        targetModel: "team",
        sortOptions: [
            DirectorySortOption(apiValue: "likes_count", title: "По лайкам"),
            DirectorySortOption(apiValue: "titles_count", title: "По тайтлам"),
            DirectorySortOption(apiValue: "subscribes_count", title: "По подписчикам"),
            DirectorySortOption(apiValue: "name", title: "По названию")
        ],
        defaultSort: DirectorySortOption(apiValue: "likes_count", title: "По лайкам")
    )

    static let character = DirectoryKind(
        apiPath: "/character", sourceType: nil, title: "Персонажи", placeholderIcon: "face.smiling",
        targetModel: "character",
        sortOptions: [
            DirectorySortOption(apiValue: "subscribes_count", title: "По подписчикам"),
            DirectorySortOption(apiValue: "name", title: "По названию")
        ],
        defaultSort: DirectorySortOption(apiValue: "subscribes_count", title: "По подписчикам")
    )

    static let people = DirectoryKind(
        apiPath: "/people", sourceType: "people", title: "Люди", placeholderIcon: "person.crop.rectangle",
        targetModel: "people",
        sortOptions: [
            DirectorySortOption(apiValue: "subscribes_count", title: "По подписчикам"),
            DirectorySortOption(apiValue: "name", title: "По названию")
        ],
        defaultSort: DirectorySortOption(apiValue: "subscribes_count", title: "По подписчикам")
    )

    static let publisher = DirectoryKind(
        apiPath: "/publisher", sourceType: "publisher", title: "Издательства", placeholderIcon: "building.2",
        targetModel: "publisher",
        sortOptions: [
            DirectorySortOption(apiValue: "name", title: "По названию"),
            DirectorySortOption(apiValue: "titles_count", title: "По тайтлам")
        ],
        defaultSort: DirectorySortOption(apiValue: "titles_count", title: "По тайтлам")
    )
}
