import Foundation

/// Мостик «меню → каталог»: когда в меню «Тайтлы» выбирают тип (Манга/Манхва/…),
/// сюда кладётся его id (см. FilterCatalog.types), а RootView переключает вкладку
/// на «Каталог». MangaCatalogView.onAppear считывает и сбрасывает это значение,
/// применяя фильтр по типу. Каталог при переключении вкладок пересоздаётся, так
/// что общее значение здесь — простейший способ донести выбор до нового экрана.
@MainActor
final class CatalogNavigator: ObservableObject {
    static let shared = CatalogNavigator()
    private init() {}

    /// id типа тайтла для фильтра при следующем показе каталога (nil — ничего).
    var pendingTypeId: Int?

    /// Готовый фильтр для применения при следующем показе каталога (напр. по
    /// жанру/тегу из карточки тайтла). Считывается и сбрасывается в
    /// MangaCatalogView.onAppear.
    var pendingFilter: MangaFilter?

    /// Сигнал «переключись на вкладку Каталог» — RootView наблюдает и меняет
    /// вкладку. UUID, чтобы каждый запрос был новым событием.
    @Published var switchRequest: UUID?

    /// Папка, которую надо выбрать при следующем показе Закладок (nil — «Все»).
    var pendingBookmarksFolder: String?
    /// Сигнал «переключись на вкладку Закладки» (из профиля «Списки тайтлов»).
    @Published var openBookmarksRequest: UUID?

    /// Открыть Закладки на конкретной папке (по умолчанию «Читаю»).
    func openBookmarks(folderId: String?) {
        pendingBookmarksFolder = folderId
        openBookmarksRequest = UUID()
    }

    /// Открыть каталог с готовым фильтром (жанр/тег из карточки).
    func openCatalog(filter: MangaFilter) {
        pendingFilter = filter
        pendingTypeId = nil
        switchRequest = UUID()
    }

    /// Фильтр по одному жанру.
    static func genreFilter(id: Int) -> MangaFilter {
        var f = MangaFilter()
        f.genres.included = [id]
        return f
    }

    /// Фильтр по одному тегу.
    static func tagFilter(id: Int) -> MangaFilter {
        var f = MangaFilter()
        f.tags.included = [id]
        return f
    }
}
