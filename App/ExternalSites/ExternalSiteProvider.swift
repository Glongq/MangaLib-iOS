import Foundation

/// Раздел алфавитного справочника (см. hitomi.la nav: tags/series/artists/
/// characters) — используется ExternalTagBrowserView. Не у каждого сайта
/// вообще есть такой справочник — см. ExternalSiteCapabilities.hasTagBrowser
/// (у e-hentai, например, его нет, см. EHentaiProvider).
/// `.groups` — добавлено вместе с 3hentai.net (у него `/groups` — полноценный
/// пункт nav-бара, `alle-groups-{буква}.html`-аналог, см.
/// ThreeHentaiProvider.fetchTagIndex); у hitomi такого справочника нет
/// (только 4 кита: tags/series/characters/artists, см.
/// HitomiProvider.fetchTagIndex — честно возвращает [] на .groups), у
/// e-hentai справочника нет вообще ни на что (hasTagBrowser == false).
enum ExternalTagKind: Hashable {
    case tags, series, characters, artists, groups
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
enum ExternalTagNamespace: Hashable {
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
/// `thumbnailURL` — статическая ссылка на МИНИАТЮРУ именно этой страницы
/// (не полноразмерная картинка) — у hitomi та же формула шардирования
/// хэша, что и у обложки (HitomiProvider.coverURL, применима к любой
/// странице, не только первой), у e-hentai — реальный CSS background-image
/// URL полосы миниатюр, подтверждён HAR прямо в разметке `/g/{id}/{token}/`
/// (`<div style="...url(https://.../{id}-{n}.webp)...">`). Используется в
/// превью-гриде карточки тайтла (см. ExternalGalleryDetailView, план ЧАСТЬ B.3).
struct ExternalGalleryPage: Hashable {
    let index: Int
    let key: String
    let width: Int
    let height: Int
    let thumbnailURL: URL?
    /// Смещение (в пикселях, ось X) тайла-миниатюры ЭТОЙ страницы внутри
    /// `thumbnailURL` — у e-hentai миниатюры отданы НЕ отдельной картинкой
    /// на страницу, а общим "спрайтом" на партию страниц (~20, размер
    /// одного ?p=N-довеска) + CSS `background-position` (подтверждено
    /// побайтово реальной разметкой: `style="width:200px;height:278px;
    /// background:transparent url(.../{id}-{n}.webp) -200px 0 no-repeat"` —
    /// одна и та же ссылка на N страниц подряд, различается только этот
    /// офсет, кратный ширине тайла). Без учёта офсета все страницы одной
    /// партии показывали бы один и тот же спрайт целиком — см.
    /// EHentaiProvider.parsePages/ExternalSpriteThumbnail. nil — у hitomi
    /// (там thumbnailURL уже указывает на отдельную картинку именно этой
    /// страницы, кроп не нужен).
    let thumbnailSpriteOffsetX: Int?
}

/// Один комментарий к тайтлу (см. ExternalGalleryDetail.comments) — сейчас
/// подтверждён HAR только у e-hentai (`<div id="cdiv">`, см. план ЧАСТЬ
/// B.5); у hitomi комментариев как концепции нет вообще (ни одного
/// comment-related запроса ни в одном HAR), там `comments` всегда `[]`.
struct ExternalComment: Identifiable, Hashable {
    let id: Int
    let author: String
    let postedAt: String
    let text: String
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
    /// Posted/Опубликовано — у hitomi `date` из galleries/{id}.js, у
    /// e-hentai строка из `gdt1"Posted:"`/`gdt2` — оба сайта её честно
    /// имеют, см. план ЧАСТЬ B.2.
    let posted: String?
    /// Ниже — метаданные, которых у hitomi физически НЕТ (не выдумываем,
    /// см. план ЧАСТЬ B.2) — заполняются только EHentaiProvider, у
    /// HitomiProvider всегда nil/[].
    let parentId: Int?
    let visible: String?
    let fileSize: String?
    let favoritedCount: String?
    let ratingAverage: Double?
    let ratingCount: Int?
    let comments: [ExternalComment]
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
    /// `Swift.Character`, не голое `Character` — этот модуль объявляет
    /// СВОЙ тип `Character` (см. MangaModels.swift — модель персонажа
    /// тайтла), который иначе затеняет стандартный однобуквенный тип и
    /// ломает компиляцию (не отлавливается локальным баланс-скобок-чеком,
    /// только реальным билдом — см. .github/workflows/ios.yml).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry]

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

    /// То же самое, но с сортировкой (см. ExternalSiteCapabilities.
    /// hasSortOptions) — `sortKey` НЕПРОЗРАЧНЫЙ, специфичный для сайта
    /// (см. HitomiProvider.SortOption.rawValue) — тот же принцип, что и
    /// excludedCategoryBits у fetchIdsBySearch ниже (Int/String, а не общий
    /// enum, чтобы протокол не был завязан на тип одного сайта). nil/"" —
    /// сортировка по умолчанию. НАСТОЯЩИЙ protocol requirement по той же
    /// причине, что и остальные необязательные параметры ниже — иначе
    /// переопределение в HitomiProvider не подхватится через `any
    /// ExternalSiteProvider`. Реализация по умолчанию (см. extension ниже)
    /// просто игнорирует sortKey — так EHentaiProvider не обязан ничего
    /// знать про сортировку (у него capabilities.hasSortOptions == false).
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Свободный текстовый поиск (см. ExternalSiteCapabilities.hasSearch) —
    /// у hitomi формально нет (см. HitomiProvider — честная пустая
    /// заглушка), у e-hentai — обычный `?f_search=` по всему сайту.
    /// Та же опаque-cursor пагинация, что и у fetchIdsByTag.
    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// То же самое, но с фильтром по категориям (см.
    /// ExternalSiteCapabilities.hasCategoryFilter, EHentaiCategory) —
    /// `excludedCategoryBits` — bitmask ИСКЛЮЧАЕМЫХ категорий (0 — без
    /// ограничения). Настоящий protocol requirement (не просто метод
    /// расширения) — иначе переопределение в EHentaiProvider не подхватится
    /// при вызове через `any ExternalSiteProvider` (диспетчеризация методов
    /// расширения, не входящих в список требований протокола, статическая,
    /// не полиморфная). Реализация по умолчанию (см. extension ниже) просто
    /// игнорирует bitmask и уходит в обычный fetchIdsBySearch — так
    /// HitomiProvider не обязан ничего знать про категории.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// То же самое, но и с категориями, и с сортировкой сразу (см. sortKey
    /// у fetchIdsByTag выше) — НАСТОЯЩИЙ protocol requirement по той же
    /// причине.
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?)

    /// Курсор, соответствующий началу СТРАНИЦЫ `page` (1-based, по `limit`
    /// элементов на страницу) — для кнопки "Перейти на страницу" (см.
    /// ExternalSiteCapabilities.hasPageJump, ExternalCatalogGridView). У
    /// hitomi это ТОЧНЫЙ переход (offset — обычное число элементов, есть
    /// всегда), у e-hentai — ПРИБЛИЗИТЕЛЬНЫЙ (см. EHentaiProvider —
    /// `range=`, подтверждено HAR, но точная формула номер-страницы→range
    /// сайтом не документирована). `page <= 1` — nil (первая страница и
    /// так открывается без курсора). Синхронный — чистое вычисление, без
    /// сети, у обоих текущих провайдеров. Реализация по умолчанию (см.
    /// extension ниже) — nil всегда, для сайта без capabilities.
    /// hasPageJump; НАСТОЯЩИЙ protocol requirement по той же причине, что
    /// и fetchIdsBySearch(excludedCategoryBits:) выше — иначе переопределение
    /// не подхватится через `any ExternalSiteProvider`.
    func cursorForPage(_ page: Int, limit: Int) -> String?

    /// Полные метаданные тайтла — для карточки и для чтения.
    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail

    /// URL полноразмерной страницы для чтения. У hitomi — чистая формула
    /// (gg.js), без сети, просто обёрнута в async ради общего протокола; у
    /// e-hentai — РЕАЛЬНЫЙ сетевой запрос каждый раз (ссылка на H@H-узел
    /// временная, с истекающим keystamp — её нельзя посчитать заранее и
    /// нельзя закэшировать надолго).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL
}

extension ExternalSiteProvider {
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, cursor: cursor, limit: limit)
    }

    func cursorForPage(_ page: Int, limit: Int) -> String? { nil }
}

/// Простой статический реестр провайдеров — без DI-магии, её в проекте
/// нигде нет (см. план).
enum ExternalSiteRegistry {
    static let providers: [ExternalSite: any ExternalSiteProvider] = [
        .hitomi: HitomiProvider(),
        .ehentai: EHentaiProvider(),
        .threeHentai: ThreeHentaiProvider(),
        .imhentai: ImhentaiProvider(),
        .hentaiPill: HentaiPillProvider(),
        .simplyHentai: SimplyHentaiProvider()
    ]

    static func provider(for site: ExternalSite) -> any ExternalSiteProvider {
        providers[site] ?? HitomiProvider()
    }
}
