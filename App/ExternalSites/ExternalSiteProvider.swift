import Foundation

/// Раздел алфавитного справочника (см. hitomi.la nav: tags/series/artists/
/// characters) — используется ExternalTagBrowserView. Не у каждого сайта
/// вообще есть такой справочник — см. ExternalSiteCapabilities.hasTagBrowser
/// (у e-hentai, например, его нет, см. EHentaiProvider).
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

/// Неймспейс тега/сущности для выдачи списка тайтлов (fetchIdsByTag) —
/// ОБЩЕЕ понятие, не завязанное на конкретный сайт: каждый провайдер сам
/// решает, во что превратить конкретный случай в СВОЙ URL/параметр (см.
/// HitomiProvider/EHentaiProvider — маппинг разный, поэтому здесь
/// намеренно нет .rawValue, привязанного к чьей-то одной схеме URL).
enum ExternalTagNamespace {
    case tag, female, male, character, artist, group, series
}

/// Один тег в карточке тайтла (ExternalGalleryDetail.tags) — female/male
/// одновременно false для нейтральных тегов (не привязанных к полу).
struct ExternalGalleryTag: Hashable {
    let name: String
    let female: Bool
    let male: Bool
}

/// Одна страница тайтла. `key` — идентификатор конкретно ЭТОЙ картинки:
/// у hitomi это настоящий хэш файла (используется в формуле gg.js, см.
/// HitomiProvider.pageImageURL), у e-hentai — imgkey (нужен, чтобы получить
/// временную, ограниченную по времени ссылку на H@H-узел, см.
/// EHentaiProvider.pageImageURL — там she ссылку нельзя посчитать заранее,
/// только живым запросом). `width`/`height` — 0, если реальный размер
/// заранее не известен (у e-hentai он выясняется только при открытии
/// конкретной страницы — до тех пор просто нет данных).
struct ExternalGalleryPage: Hashable {
    let index: Int
    let key: String
    let width: Int
    let height: Int
}

/// Полные метаданные тайтла (см. HitomiProvider/EHentaiProvider.
/// fetchGalleryDetail) — и для карточки, и для построения списка страниц
/// чтения. `coverURL` — ГОТОВАЯ ссылка на обложку/превью, которую строит
/// сам провайдер (у hitomi — по формуле шардирования хэша, у e-hentai —
/// просто уже готовая ссылка прямо из HTML) — раньше это была отдельная
/// функция протокола (thumbnailURL(hash:)), но формула оказалась
/// hitomi-специфичной (e-hentai её не использует вообще), поэтому теперь
/// каждый провайдер решает сам, откуда взять обложку, и просто кладёт
/// готовый URL сюда.
struct ExternalGalleryDetail: Identifiable {
    let id: Int
    /// Какой конкретно сайт выдал этот тайтл — нужно для совместного
    /// каталога/выдачи (см. ExternalCombinedCatalogView, ExternalCatalogItem)
    /// и для подписи в карточке (ExternalGalleryDetailView), где тайтл мог
    /// прийти как с активного одиночного сайта, так и (в совместном режиме)
    /// с любого из нескольких включённых сразу.
    let site: ExternalSite
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
    let coverURL: URL?
}

/// Общий протокол одного внешнего сайта — реализуется отдельным типом на
/// каждый сайт (см. HitomiProvider/EHentaiProvider). Ничего общего с
/// MangaNetworkService — собственная сессия/парсинг/модели у каждого
/// провайдера свои.
protocol ExternalSiteProvider {
    var site: ExternalSite { get }
    var capabilities: ExternalSiteCapabilities { get }

    /// Алфавитный список (буква A-Z/123) — см. ExternalTagBrowserView.
    /// Реализация обязана существовать (протокол этого требует), но если
    /// у сайта такого справочника нет (capabilities.hasTagBrowser == false)
    /// — просто возвращает [] и никогда не вызывается настоящим UI (тот
    /// сам проверяет capabilities раньше, чем показать экран).
    func fetchTagIndex(kind: ExternalTagKind, letter: Character) async throws -> [ExternalTagEntry]

    /// Автокомплит при наборе текста в поиске. Как и fetchTagIndex — можно
    /// честно вернуть [], если у сайта такого эндпоинта нет/не подтверждён.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion]

    /// ID тайтлов по одному тегу/серии/персонажу/группе/автору, постранично.
    /// `cursor` — НЕПРОЗРАЧНЫЙ токен страницы (не число!) — у hitomi это
    /// байтовый offset в виде строки, у e-hentai — id последнего тайтла
    /// текущей страницы (реальная схема пагинации сайта, `&next=...`) —
    /// поэтому не единообразный "offset: Int", а просто "то, что вернул
    /// прошлый вызов". nil — первая страница. `nextCursor == nil` в ответе
    /// — тайтлов больше нет.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Свободный текстовый поиск (см. ExternalSiteCapabilities.hasSearch) —
    /// у hitomi формально нет (см. HitomiProvider — честная пустая
    /// заглушка), у e-hentai — обычный `?f_search=` по всему сайту.
    /// Та же опаque-cursor пагинация, что и у fetchIdsByTag.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Полные метаданные тайтла — для карточки и для чтения.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail

    /// URL полноразмерной страницы для чтения. У hitomi — чистая формула
    /// (gg.js), без сети, просто обёрнута в async ради общего протокола; у
    /// e-hentai — РЕАЛЬНЫЙ сетевой запрос каждый раз (ссылка на H@H-узел
    /// временная, с истекающим keystamp — её нельзя посчитать заранее и
    /// нельзя закэшировать надолго).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL
}

/// Простой статический реестр провайдеров — без DI-магии, её в проекте
/// нигде нет (см. план).
enum ExternalSiteRegistry {
    static let providers: [ExternalSite: any ExternalSiteProvider] = [
        .hitomi: HitomiProvider(),
        .ehentai: EHentaiProvider()
    ]

    static func provider(for site: ExternalSite) -> any ExternalSiteProvider {
        providers[site] ?? HitomiProvider()
    }
}
