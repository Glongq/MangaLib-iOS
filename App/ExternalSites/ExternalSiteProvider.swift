import Foundation

/// Раздел алфавитного справочника (см. hitomi.la nav: tags/series/artists/
/// characters) — используется ExternalTagBrowserView.
enum ExternalTagKind {
    case tags, series, characters, artists
}

/// Один пункт алфавитного списка (ExternalTagBrowserView) — имя + число
/// тайтлов + slug для дальнейшего запроса выдачи (см. fetchIdsByTag).
struct ExternalTagEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let slug: String
}

/// Один пункт автокомплита поиска (см. HitomiProvider.fetchAutocomplete) —
/// category — как есть от сервера ("tag"/"series"/"character"/"group"/
/// "artist"/"language"/"female"/"male"/"type").
struct ExternalTagSuggestion: Hashable {
    let name: String
    let count: Int
    let category: String
}

/// Неймспейс тега/сущности для выдачи списка тайтлов (fetchIdsByTag) — те
/// же разделы, что различает сам hitomi.la в URL (`/tag/...`, `/female/...`,
/// `/n/series/...` и т.д.).
enum ExternalTagNamespace: String {
    case tag, female, male, character, artist, group
    case series = "n/series"
}

/// Один тег в карточке тайтла (ExternalGalleryDetail.tags) — female/male
/// одновременно false для нейтральных тегов (не привязанных к полу).
struct ExternalGalleryTag: Hashable {
    let name: String
    let female: Bool
    let male: Bool
}

/// Одна страница тайтла — берём "hash" для сборки URL (см.
/// ExternalSiteProvider.thumbnailURL/pageImageURL).
struct ExternalGalleryPage: Hashable {
    let hash: String
    let width: Int
    let height: Int
}

/// Полные метаданные тайтла (см. HitomiProvider.fetchGalleryDetail) — и для
/// карточки, и для построения URL страниц чтения.
struct ExternalGalleryDetail: Identifiable {
    let id: Int
    let title: String
    let type: String
    let language: String?
    let tags: [ExternalGalleryTag]
    let artists: [String]
    let groups: [String]
    let characters: [String]
    let series: [String]
    let related: [Int]
    let pages: [ExternalGalleryPage]
}

/// Общий протокол одного внешнего сайта — реализуется отдельным типом на
/// каждый сайт (см. HitomiProvider). Ничего общего с MangaNetworkService —
/// собственная сессия/парсинг/модели у каждого провайдера свои.
protocol ExternalSiteProvider {
    var site: ExternalSite { get }
    var capabilities: ExternalSiteCapabilities { get }

    /// Алфавитный список (буква A-Z/123) — см. ExternalTagBrowserView.
    func fetchTagIndex(kind: ExternalTagKind, letter: Character) async throws -> [ExternalTagEntry]

    /// Автокомплит при наборе текста в поиске.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion]

    /// ID тайтлов по одному тегу/серии/персонажу/группе/автору, постранично
    /// (offset/limit в элементах, не байтах — реализация сама переводит в
    /// Range-заголовок). total — общее число тайтлов по этому значению.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, offset: Int, limit: Int) async throws -> (ids: [Int], total: Int)

    /// Полные метаданные тайтла — для карточки и для чтения.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail

    /// URL превью для сетки каталога (простое шардирование по хэшу).
    func thumbnailURL(hash: String) -> URL

    /// URL полноразмерной страницы для чтения (формула gg.js).
    func pageImageURL(hash: String) -> URL
}

/// Простой статический реестр провайдеров — без DI-магии, её в проекте
/// нигде нет (см. план).
enum ExternalSiteRegistry {
    static let providers: [ExternalSite: any ExternalSiteProvider] = [
        .hitomi: HitomiProvider()
    ]

    static func provider(for site: ExternalSite) -> any ExternalSiteProvider {
        providers[site] ?? HitomiProvider()
    }
}
