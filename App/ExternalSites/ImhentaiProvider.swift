import Foundation

/// Ошибки ImhentaiProvider — та же намеренно простая схема, что у
/// HitomiError/EHentaiError/ThreeHentaiError.
enum ImhentaiError: Error {
    case badResponse
}

/// Категории imhentai.com/imhentai.xxx (Manga/Doujinshi/Western/Image Set/
/// Artist CG/Game CG — кнопки на `/advsearch/`, подтверждено HAR: `<li
/// onclick="toggle_category('manga')"><input type="hidden" name="m" value="1"
/// />Manga</li>` и т.д.) — та же семантика, что у EHentaiCategory: тап
/// ВЫКЛЮЧАЕТ категорию из выдачи (по умолчанию все включены), поэтому и
/// здесь `excluded`-набор, не `included` (см. ImhentaiCategoryPicker).
///
/// `.bit` — СВОЙ диапазон битов (10...15), НЕ пересекающийся с
/// EHentaiCategory (0...9) — по прямому расчёту: `excludedCategoryBits:
/// Int` в протоколе ОБЩИЙ на весь запрос (см. ExternalCatalogGridView.
/// fetchPage — один и тот же bitmask уходит в fetchIdsBySearch КАЖДОГО
/// сайта в совместной выдаче, см. ExternalCombinedCatalogView), поэтому
/// если одновременно включены e-hentai И imhentai, один Int обязан нести
/// ОБА набора исключений сразу, не путаясь — непересекающиеся диапазоны
/// битов это гарантируют. Каждый провайдер сам маскирует входящий bitmask
/// под СВОИ известные биты (см. fetchIdsBySearch ниже) — чужие биты в том
/// же Int просто игнорируются, а не портят f_cats/m=&d=&...
enum ImhentaiCategory: CaseIterable, Identifiable {
    case manga, doujinshi, western, imageSet, artistCG, gameCG

    var id: Self { self }

    var bit: Int {
        switch self {
        case .manga: return 1 << 10
        case .doujinshi: return 1 << 11
        case .western: return 1 << 12
        case .imageSet: return 1 << 13
        case .artistCG: return 1 << 14
        case .gameCG: return 1 << 15
        }
    }

    /// Query-параметр на `/search/`/`/advsearch/` (подтверждено HAR —
    /// `?...&m=1&d=1&w=1&i=1&a=1&g=1&...`) — "1" включает категорию в
    /// выдачу, "0" исключает.
    var queryKey: String {
        switch self {
        case .manga: return "m"
        case .doujinshi: return "d"
        case .western: return "w"
        case .imageSet: return "i"
        case .artistCG: return "a"
        case .gameCG: return "g"
        }
    }

    var displayName: String {
        switch self {
        case .manga: return "Manga"
        case .doujinshi: return "Doujinshi"
        case .western: return "Western"
        case .imageSet: return "Image Set"
        case .artistCG: return "Artist CG"
        case .gameCG: return "Game CG"
        }
    }
}

/// Языки imhentai.com/imhentai.xxx (English/Japanese/Spanish/French/Korean/
/// German/Russian — флаги-чекбоксы на `/advsearch/`) — ПОДТВЕРЖДЕНО живым
/// HAR (31.08, третий заход): реальные последовательные запросы
/// `/advsearch/?...&en=1&jp=1&es=1&fr=1&kr=1&de=1&ru=1&key=...` →
/// `...&en=1&jp=1&es=0&fr=1&kr=1&de=0&ru=1&key=...` → ... — та же семантика
/// "1" включена/"0" исключена, тот же приём тапа-выключения, что и у
/// ImhentaiCategory (по умолчанию ВСЕ включены).
///
/// `.bit` — СВОЙ диапазон (16...22), НЕ пересекается ни с EHentaiCategory
/// (0...9), ни с ImhentaiCategory (10...15) — тот же общий Int
/// `excludedCategoryBits` безопасно несёт категории И языки одновременно
/// (см. doc-comment ImhentaiCategory.bit — тот же принцип, просто ещё одно
/// непересекающееся измерение в том же канале, без правки протокола
/// ExternalSiteProvider).
enum ImhentaiLanguage: CaseIterable, Identifiable {
    case english, japanese, spanish, french, korean, german, russian

    var id: Self { self }

    var bit: Int {
        switch self {
        case .english: return 1 << 16
        case .japanese: return 1 << 17
        case .spanish: return 1 << 18
        case .french: return 1 << 19
        case .korean: return 1 << 20
        case .german: return 1 << 21
        case .russian: return 1 << 22
        }
    }

    /// Query-параметр — подтверждено HAR (en/jp/es/fr/kr/de/ru).
    var queryKey: String {
        switch self {
        case .english: return "en"
        case .japanese: return "jp"
        case .spanish: return "es"
        case .french: return "fr"
        case .korean: return "kr"
        case .german: return "de"
        case .russian: return "ru"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "Japanese"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .korean: return "Korean"
        case .german: return "German"
        case .russian: return "Russian"
        }
    }

    /// Флаг-эмодзи — чисто для узнаваемости в ImhentaiLanguagePicker, не
    /// подтверждено HAR (это иконки самого сайта — свои PNG, не эмодзи).
    var flag: String {
        switch self {
        case .english: return "🇬🇧"
        case .japanese: return "🇯🇵"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .korean: return "🇰🇷"
        case .german: return "🇩🇪"
        case .russian: return "🇷🇺"
        }
    }
}

/// Расширенные поля поиска — Tags/Parodies/Artists/Characters/Groups (см.
/// `/advsearch/`, скриншот пользователя 31.08: "Tags (1/16632)"/"Parodies
/// (0/5014)"/... — отдельное поле на КАЖДУЮ категорию, не общая строка
/// поиска, каждое может копить НЕСКОЛЬКО значений сразу — счётчик рядом с
/// заголовком считает уже добавленные). Собирается в спец-синтаксис
/// `+kind:"значение"` (см. ImhentaiProvider.fetchIdsBySearch doc-comment —
/// живым HAR ПОДТВЕРЖДЁН только `tag` — `+tag:"anal"`, ровно то, что
/// собирает сама страница `/advsearch/` в скрытое поле `key`; `parody`/
/// `artist`/`character`/`group` — по симметрии с реальными URL-сегментами
/// карточки одного значения, `/parody/{slug}/`/`/artist/{slug}/`/
/// `/character/{slug}/`/`/group/{slug}/` (см. ImhentaiProvider.
/// tagBasePath) — тот же принцип, что и у `tag`/`/tag/{slug}/`, но НЕ
/// подтверждено отдельным HAR именно для этих четырёх. Комбинация
/// НЕСКОЛЬКИХ значений (несколько тегов сразу, тег+пародия одновременно) —
/// тоже не подтверждена отдельно (в HAR встретился только ОДИН активный
/// тег), собирается по аналогии — несколько `+kind:"..."` через пробел,
/// как в большинстве подобных мини-языков поиска.
struct ImhentaiAdvancedQuery {
    /// Собственная строка поиска IMHentai — по прямой просьбе (31.08)
    /// ОТДЕЛЬНАЯ от общего верхнего поля поиска ExternalSearchView: обычный
    /// текст, набранный "как для других сайтов", у imhentai надёжно не
    /// находит ничего (см. doc-comment fetchIdsBySearch — `/search/` и
    /// `/advsearch/` два РАЗНЫХ парсера одного и того же `key=`). Поэтому
    /// на экране ОДНОГО сайта (ExternalSearchView.composedQuery/
    /// displayTitle) imhentai вообще не смотрит на общее поле — только на
    /// это, живёт в тех же «Фильтрах», что и Tags/Parodies/...
    /// ВАЖНО: в совместном каталоге "Все сайты" (ExternalCombinedCatalogView)
    /// это поле пока НЕ подключено — там один общий `key=` уходит сразу во
    /// все включённые сайты (см. её composedQuery), и imhentai там всё ещё
    /// получает общий текст вместе с остальными; тронуть это отдельно не
    /// просили, threshold другой (пришлось бы городить свой запрос на
    /// сайт вместо одного общего).
    var searchText: String = ""
    var tags: [String] = []
    var parodies: [String] = []
    var artists: [String] = []
    var characters: [String] = []
    var groups: [String] = []

    var isEmpty: Bool {
        searchText.isEmpty && tags.isEmpty && parodies.isEmpty && artists.isEmpty && characters.isEmpty && groups.isEmpty
    }

    /// Значения — как есть, БЕЗ слагификации (не URL-путь, а значение
    /// внутри строки `key=` в кавычках — на скриншоте пользователя чип
    /// показывает человекочитаемое "Tag: Anal", не "anal-female"/slug).
    func clauses() -> [String] {
        func kind(_ name: String, _ values: [String]) -> [String] {
            values.map { "+\(name):\"\($0)\"" }
        }
        return kind("tag", tags) + kind("parody", parodies) + kind("artist", artists) + kind("character", characters) + kind("group", groups)
    }
}

/// Клиент imhentai.xxx — СВОЯ, полностью отдельная реализация. Все URL/
/// форматы ниже подтверждены реальным HAR (31.08, три захода — каталог/
/// поиск, затем карточка тайтла + читалка живьём с телефона пользователя)
/// и перепроверены живым curl перед коммитом.
///
/// ВАЖНО (см. отчёт пользователю) — сайт за Cloudflare: часть путей
/// (`/gallery/`, `/view/`, `/groups/`, `/artist/`, `/tags/`, `/advsearch/`,
/// сама `/`) в песочнице этой сессии отвечали 403 "Just a moment..." без
/// `cf_clearance`-куки (та выдаётся только после прохождения JS-проверки
/// в настоящем браузере — `URLSession` её пройти не может). С реального
/// устройства пользователя (см. HAR 31.08, поздний заход) те же пути
/// отдавали 200 без единой заминки — но это браузерный трафик (JS
/// исполняется), не то же самое, что чистый `URLSession`-клиент даже с
/// той же сети/IP: Cloudflare различает их и по TLS/HTTP-фингерпринту, не
/// только по репутации IP. Возможно, что именно ЭТА зона Cloudflare
/// достаточно мягкая (JS-испытание проходит незаметно для любого клиента
/// с правдоподобным TLS-почерком) — но гарантии нет, пока не проверено
/// живьём из самого приложения.
struct ImhentaiProvider: ExternalSiteProvider {
    let site: ExternalSite = .imhentai
    let capabilities = ExternalSiteCapabilities(
        hasCatalog: true,
        // Алфавитный справочник — tags/parodies/artists/characters/groups,
        // все 5 через ОДНУ и ту же схему `/{раздел}/{буква}/` (подтверждено
        // HAR только для groups — остальные четыре по симметрии разметки
        // nav-бара, не проверены индивидуально).
        hasTagBrowser: true,
        // Настоящий полнотекстовый поиск (`/search/?key=`), подтверждено
        // HAR (200, реальные карточки в ответе).
        hasSearch: true,
        // Manga/Doujinshi/Western/Image Set/Artist CG/Game CG — все 6
        // подтверждены HAR (`/advsearch/`), см. ImhentaiCategory.
        hasCategoryFilter: true,
        // Номер страницы — обычный query-параметр `?page=N`, точный переход
        // (подтверждено HAR — пагинация `/search/`/`/groups/{буква}/`).
        hasPageJump: true,
        // Latest/Popular/Downloaded/Top Rated (`lt`/`pp`/`dl`/`tr`,
        // подтверждено HAR `/advsearch/`) — переиспользует общий UI/словарь
        // HitomiProvider.SortOption (см. её маппинг ниже и тот же приём у
        // ThreeHentaiProvider — единственный сегодня источник вариантов на
        // экран сортировки, свой список сюда не заводим).
        hasSortOptions: true,
        // Аккаунт/избранное/загрузки на самом сайте РЕАЛЬНО есть (кнопки
        // Favourite/Download на карточке, подтверждено HAR), но эта
        // интеграция без входа — тот же принцип, что у EHentaiProvider/
        // ThreeHentaiProvider.
        hasBookmarks: false,
        hasHistory: false,
        hasNotifications: false,
        // Эндпоинт `POST /inc/comments.php` реально существует
        // (подтверждено HAR — 200 на обеих проверенных карточках), но
        // ответ был `empty` на всех проверенных тайтлах (ни у одного не
        // было ни одного комментария) — ни формат тела запроса, ни формат
        // ответа С РЕАЛЬНЫМИ комментариями не подтверждены, честно false,
        // не выдумываем.
        hasComments: false
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://imhentai.xxx/"
        ]
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://imhentai.xxx"

    // MARK: Алфавитный справочник (Tags/Parodies/Artists/Characters/Groups)

    private static func letterIndexPath(for kind: ExternalTagKind) -> String {
        switch kind {
        case .tags: return "tags"
        case .series: return "parodies"
        case .characters: return "characters"
        case .artists: return "artists"
        case .groups: return "groups"
        }
    }

    /// Единственное число того же раздела — часть URL карточки одного
    /// конкретного значения (`/tag/{slug}/`, не `/tags/{slug}/`,
    /// подтверждено HAR на живой карточке тайтла: href="/tag/lolicon/").
    private static func singularSegment(for basePath: String) -> String {
        switch basePath {
        case "tags": return "tag"
        case "parodies": return "parody"
        case "characters": return "character"
        case "artists": return "artist"
        case "groups": return "group"
        default: return basePath
        }
    }

    /// "num" — отдельный бакет цифр/символов (подтверждено HAR:
    /// `/groups/num/`), тот же сигнал (`letter.isNumber`), что уже шлёт
    /// ExternalTagBrowserView вместо "#" (см. HitomiProvider/
    /// ThreeHentaiProvider.fetchTagIndex — тот же приём).
    func fetchTagIndex(kind: ExternalTagKind, letter: Swift.Character) async throws -> [ExternalTagEntry] {
        let basePath = Self.letterIndexPath(for: kind)
        let singular = Self.singularSegment(for: basePath)
        let letterSlug = letter.isNumber ? "num" : String(letter).lowercased()
        var result: [ExternalTagEntry] = []
        var seenSlugs = Set<String>()
        // Занятые буквы реально паджинируются (`?page=2`, подтверждено HAR
        // на /groups/a/ — 48 страниц) — тянем все страницы подряд, тот же
        // приём и потолок, что у ThreeHentaiProvider.fetchTagIndex.
        var page = 1
        while page <= 20 {
            var urlString = "\(Self.baseURL)/\(basePath)/\(letterSlug)/"
            if page > 1 { urlString += "?page=\(page)" }
            guard let url = URL(string: urlString) else { break }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch {
                break
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { break }
            let entries = Self.parseLetterIndexList(html: html, singularSegment: singular)
            var addedAny = false
            for entry in entries where !seenSlugs.contains(entry.slug) {
                seenSlugs.insert(entry.slug)
                result.append(entry)
                addedAny = true
            }
            guard addedAny, Self.hasNextPage(html: html) else { break }
            page += 1
        }
        return result
    }

    /// `<a class="tag_btn ..." href="/{singular}/{slug}/"><h3 class=
    /// "list_tag">{name}[ <span class='split_tag'>...</span>]</h3>
    /// <span class="badge">{count}</span>...` — подтверждено HAR
    /// (/groups/a/). `.dotMatchesLineSeparators` — h3-содержимое может
    /// переноситься на opcional вложенный `<span>` (split_tag/альтернативное
    /// имя) до закрывающего `</h3>`, вырезается через stripInnerTags так
    /// же, как e-hentai-комментарии у EHentaiProvider.
    private static func parseLetterIndexList(html: String, singularSegment: String) -> [ExternalTagEntry] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="/\#(NSRegularExpression.escapedPattern(for: singularSegment))/([^"]+)/"><h3[^>]*>(.*?)</h3>\s*<span class="badge">(\d+)</span>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [ExternalTagEntry] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 4,
                  let slugRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let countRange = Range(match.range(at: 3), in: html),
                  let count = Int(html[countRange]) else { return }
            let slug = String(html[slugRange])
            let name = decodeHTMLEntities(stripInnerTags(String(html[nameRange]))).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ExternalTagEntry(id: slug, name: name, count: count, slug: slug))
        }
        return result
    }

    private static func hasNextPage(html: String) -> Bool {
        html.range(of: #"href='[^']*page=\d+[^']*'>Next"#, options: .regularExpression) != nil
    }

    /// Автокомплит не подтверждён HAR — ни одного AJAX-запроса под поля
    /// "search tags..."/"search parodies..." на `/advsearch/` не поймано
    /// (возможно чисто клиентская фильтрация уже загруженного списка, не
    /// сетевой автокомплит) — честно пусто, тот же принцип, что у
    /// EHentaiProvider/ThreeHentaiProvider.
    func fetchAutocomplete(query: String, namespace: String?) async throws -> [ExternalTagSuggestion] {
        []
    }

    // MARK: Сортировка

    /// Переиспользует словарь hitomi (см. её doc-comment у ThreeHentaiProvider
    /// — тот же приём: общий UI сортировки в ExternalCatalogGridView сегодня
    /// жёстко завязан на HitomiProvider.SortOption). У imhentai 4 РЕАЛЬНЫХ
    /// режима — Latest/Popular/Downloaded/Top Rated (`lt`/`pp`/`dl`/`tr`,
    /// подтверждено HAR `/advsearch/`), не времяоконные периоды, поэтому
    /// соответствие не идеальное: `.dateAdded` → без параметров (сайт и так
    /// сортирует по дате по умолчанию), `.popularToday` → `pp`,
    /// `.popularWeek` → `dl` (ближайшая по смыслу метрика вовлечённости),
    /// `.popularMonth`/`.popularYear` → `tr` (оба, третьей отдельной
    /// метрики физически нет).
    private static func sortQueryParams(for sortKey: String?) -> [String] {
        guard let option = sortKey.flatMap(HitomiProvider.SortOption.init(rawValue:)) else { return [] }
        let active: String
        switch option {
        case .dateAdded: return []
        case .popularToday: active = "pp"
        case .popularWeek: active = "dl"
        case .popularMonth, .popularYear: active = "tr"
        }
        return ["lt", "pp", "dl", "tr"].map { "\($0)=\($0 == active ? 1 : 0)" }
    }

    // MARK: Список тайтлов по тегу/серии/автору/группе

    private static func tagBasePath(for namespace: ExternalTagNamespace) -> String {
        switch namespace {
        case .tag, .female, .male: return "tag"
        case .series: return "parody"
        case .character: return "character"
        case .artist: return "artist"
        case .group: return "group"
        }
    }

    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsByTag(namespace: namespace, value: value, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// `value` — slug (из ExternalTagBrowserView/entry.slug — реальный,
    /// или чистое отображаемое имя из чипа карточки тайтла, см.
    /// ExternalGalleryDetailView) — слагифицируется так же, как у
    /// ThreeHentaiProvider (см. её slugify doc-comment — та же формула:
    /// нижний регистр + любая последовательность не-буквенно-цифровых
    /// символов схлопывается в один дефис), идемпотентно на уже готовых
    /// slug'ах.
    func fetchIdsByTag(namespace: ExternalTagNamespace, value: String, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let basePath = Self.tagBasePath(for: namespace)
        let slug = Self.slugify(value)
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        var params = Self.sortQueryParams(for: sortKey)
        let page = Int(cursor ?? "1") ?? 1
        if page > 1 { params.append("page=\(page)") }
        var urlString = "\(Self.baseURL)/\(basePath)/\(encodedSlug)/"
        if !params.isEmpty { urlString += "?" + params.joined(separator: "&") }
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Слагификация — 1-в-1 ThreeHentaiProvider.slugify (та же реальная
    /// схема сайта: нижний регистр, последовательность не-буквенно-
    /// цифровых символов → один дефис), подтверждено HAR: "seven of seven"
    /// → "seven-of-seven", "akumu no takuhaibin" → "akumu-no-takuhaibin".
    private static func slugify(_ text: String) -> String {
        var slug = ""
        var lastWasSeparator = true
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    func cursorForPage(_ page: Int, limit: Int) -> String? {
        guard page > 1 else { return nil }
        return String(page)
    }

    // MARK: Поиск

    func fetchIdsBySearch(query: String, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: 0, sortKey: nil, cursor: cursor, limit: limit)
    }

    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        try await fetchIdsBySearch(query: query, excludedCategoryBits: excludedCategoryBits, sortKey: nil, cursor: cursor, limit: limit)
    }

    /// Строго алфавитно-цифровой набор для percent-encoding значения `key=`
    /// — НЕ `.urlQueryAllowed` (тот RFC3986-набор оставляет `+`/`:` как
    /// есть, не экранирует), а вручную суженный: `+`/`:`/`"` в
    /// ImhentaiAdvancedQuery.clauses() ОБЯЗАНЫ уйти percent-encoded (иначе
    /// сырой "+" PHP на стороне сервера раскодирует как пробел — та же
    /// семантика application/x-www-form-urlencoded, что и у $_GET, — и
    /// спецсинтаксис "+tag:..." развалится на пробел+"tag:..."). Реальный
    /// браузер (см. HAR, 31.08) кодирует ИМЕННО так — `%2Btag%3A%22anal%22`,
    /// то есть буквально JS-эквивалент `encodeURIComponent`, не
    /// RFC3986-safe набор.
    private static let searchValueAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    /// `/search/?key=...` — подтверждено HAR (200, реальные карточки) для
    /// ОБЫЧНОГО текста. Специальный синтаксис `+tag:"..."`/`+parody:"..."`/
    /// ... (см. ImhentaiAdvancedQuery — Tags/Parodies/Artists/Characters/
    /// Groups на `/advsearch/`, скриншот пользователя 31.08) `/search/` НЕ
    /// понимает — перепроверено живым curl: `key=+tag:"anal"` через
    /// `/search/` даёт "(0) results found" (буквально ищет как ТЕКСТ), тот
    /// же запрос через `/advsearch/` в реальном HAR дал "(219,197) results
    /// found" — эти два эндпоинта РАЗНО парсят один и тот же `key=`.
    /// `/advsearch/` из песочницы этой сессии за Cloudflare (403, тот же
    /// джва-челлендж, что у `/gallery/`/`/view/`) — маршрутизация ниже
    /// (`usesAdvancedSyntax`) подтверждена только КОСВЕННО (реальным HAR +
    /// логикой "два разных парсера"), сам финальный запрос с реального
    /// устройства НЕ перепроверен — как и остальные HTML-страницы этого
    /// сайта, см. doc-comment типа.
    /// Категории/языки — только СВОИ биты (см. ImhentaiCategory/
    /// ImhentaiLanguage.bit doc-comment — непересекающиеся диапазоны с
    /// EHentaiCategory, маскируем на входе, чужие биты в том же Int просто
    /// игнорируются).
    func fetchIdsBySearch(query: String, excludedCategoryBits: Int, sortKey: String?, cursor: String?, limit: Int) async throws -> (ids: [Int], nextCursor: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: Self.searchValueAllowedCharacters) ?? trimmed
        var params = ["key=\(encodedQuery)"]

        let ownCategoryMask = ImhentaiCategory.allCases.reduce(0) { $0 | $1.bit }
        let ownExcludedCategoryBits = excludedCategoryBits & ownCategoryMask
        if ownExcludedCategoryBits != 0 {
            for category in ImhentaiCategory.allCases {
                let included = (ownExcludedCategoryBits & category.bit) == 0
                params.append("\(category.queryKey)=\(included ? 1 : 0)")
            }
        }

        // Языки — тот же принцип, что и категории выше, просто своё
        // непересекающееся подмножество битов того же Int (см.
        // ImhentaiLanguage.bit doc-comment).
        let ownLanguageMask = ImhentaiLanguage.allCases.reduce(0) { $0 | $1.bit }
        let ownExcludedLanguageBits = excludedCategoryBits & ownLanguageMask
        if ownExcludedLanguageBits != 0 {
            for language in ImhentaiLanguage.allCases {
                let included = (ownExcludedLanguageBits & language.bit) == 0
                params.append("\(language.queryKey)=\(included ? 1 : 0)")
            }
        }

        params.append(contentsOf: Self.sortQueryParams(for: sortKey))

        let page = Int(cursor ?? "1") ?? 1
        if page > 1 { params.append("page=\(page)") }

        // `+tag:"..."`/`+parody:"..."`/`+artist:"..."`/`+character:"..."`/
        // `+group:"..."` — ЕДИНСТВЕННЫЙ источник этой конструкции в
        // приложении, см. ImhentaiAdvancedQuery.clauses() — обычный
        // свободный текст никогда так не выглядит, ложных срабатываний не
        // бывает. `apply=Search` — присутствует во ВСЕХ подтверждённых HAR
        // запросах на `/advsearch/`, добавляется только тут же, вместе со
        // сменой пути (см. doc-comment функции выше).
        let usesAdvancedSyntax = trimmed.range(of: #"\+(tag|parody|artist|character|group):"#, options: .regularExpression) != nil
        let path = usesAdvancedSyntax ? "advsearch" : "search"
        if usesAdvancedSyntax { params.append("apply=Search") }

        let urlString = "\(Self.baseURL)/\(path)/?" + params.joined(separator: "&")
        return try await fetchGalleryList(urlString: urlString, currentPage: page)
    }

    /// Общий разбор страницы выдачи (поиск/категория/тег — везде одна и та
    /// же разметка `<div class="thumbnail"><a href="/gallery/{id}/">...`).
    private func fetchGalleryList(urlString: String, currentPage: Int) async throws -> (ids: [Int], nextCursor: String?) {
        guard let url = URL(string: urlString) else { throw ImhentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ImhentaiError.badResponse
        }
        let ids = Self.parseGalleryIds(html: html)
        let nextCursor = Self.hasNextPage(html: html) ? String(currentPage + 1) : nil
        return (ids, nextCursor)
    }

    private static func parseGalleryIds(html: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"href="/gallery/(\d+)/""#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [Int] = []
        var seen = Set<Int>()
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: html),
                  let id = Int(html[idRange]), !seen.contains(id) else { return }
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    // MARK: Карточка тайтла

    func fetchGalleryDetail(id: Int) async throws -> ExternalGalleryDetail {
        guard let url = URL(string: "\(Self.baseURL)/gallery/\(id)/") else { throw ImhentaiError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw ImhentaiError.badResponse
        }
        return Self.parseDetail(html: html, id: id)
    }

    /// Заголовок раздела (Parodies:/Characters:/Tags:/.../Category:) НЕ
    /// разбирается по тексту — маршрутизация по ПЕРВОМУ сегменту href
    /// (parody/character/tag/artist/group/language/category), тот же приём,
    /// что у ThreeHentaiProvider.parseDetail — устойчиво к локализации.
    private static func parseDetail(html: String, id: Int) -> ExternalGalleryDetail {
        let title = firstMatch(in: html, pattern: #"<h1>([^<]*)</h1>"#).map(decodeHTMLEntities) ?? "Untitled"
        let posted = firstMatch(in: html, pattern: #"class="posted">Posted: ([^<]+)</li>"#)
        let favoritedCount = firstMatch(in: html, pattern: #"Favourite \((\d+)\)"#)

        var type = ""
        var series: [String] = []
        var characters: [String] = []
        var artists: [String] = []
        var groups: [String] = []
        var languageParts: [String] = []
        var tags: [ExternalGalleryTag] = []

        // `<a class='tag[...]' href='/{раздел}/{slug}/'>{имя}[<span
        // class='split_tag'>...</span>]<span class='badge'>{count}</span>`
        // — одинарные кавычки, БЕЗ h3-обёртки (в отличие от letter-index
        // страниц, см. parseLetterIndexList) — подтверждено HAR на живой
        // карточке тайтла.
        if let regex = try? NSRegularExpression(
            pattern: #"<a class='tag[^']*' href='/([a-z]+)/([^']+)/'>([^<]+)"#
        ) {
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, match.numberOfRanges == 4,
                      let sectionRange = Range(match.range(at: 1), in: html),
                      let slugRange = Range(match.range(at: 2), in: html),
                      let nameRange = Range(match.range(at: 3), in: html) else { return }
                let section = String(html[sectionRange])
                let slug = String(html[slugRange])
                let name = decodeHTMLEntities(String(html[nameRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                switch section {
                case "category":
                    if type.isEmpty { type = name }
                case "parody": series.append(name)
                case "character": characters.append(name)
                case "artist": artists.append(name)
                case "group": groups.append(name)
                case "language": languageParts.append(name)
                case "tag":
                    // Пола-намеспейса в разметке imhentai не встретилось
                    // (в отличие от hitomi) — нейтральный тег, female/male
                    // оба false, честно не выдумываем гендерный сплит.
                    tags.append(ExternalGalleryTag(name: name, female: false, male: false))
                default: break
                }
                _ = slug // slug самих чипов не нужен — переход по чипу
                // слагифицирует имя заново (см. ImhentaiProvider.slugify),
                // тот же приём, что у ThreeHentaiProvider.
            }
        }

        // Картинки — из скрытых полей load_server/load_dir/load_id/
        // load_pages (подтверждено HAR на ДВУХ независимых тайтлах, живым
        // curl НЕ перепроверялось — сайт за Cloudflare, см. doc-comment
        // типа). Формула ПОДТВЕРЖДЕНА реальным `/view/{id}/1/`:
        // `https://m{server}.imhentai.xxx/{dir}/{id}/{page}.webp`.
        let loadServer = firstMatch(in: html, pattern: #"name="load_server"[^>]*value="([^"]*)""#)
        let loadDir = firstMatch(in: html, pattern: #"name="load_dir"[^>]*value="([^"]*)""#)
        let loadId = firstMatch(in: html, pattern: #"name="load_id"[^>]*value="([^"]*)""#)
        let loadPages = firstMatch(in: html, pattern: #"name="load_pages"[^>]*value="([^"]*)""#).flatMap(Int.init) ?? 0

        var pages: [ExternalGalleryPage] = []
        var coverURL: URL?
        if let server = loadServer, let dir = loadDir, let galleryFolder = loadId, loadPages > 0 {
            let storageKey = "m\(server).imhentai.xxx/\(dir)/\(galleryFolder)"
            // thumbnailURL — отдельная лёгкая миниатюра "{N}t.jpg", ТЕПЕРЬ
            // подтверждена живым HAR (31.08, второй заход — реальные
            // запросы на /view/{id}/{page}/): `https://m11.imhentai.xxx/
            // 032/{galleryFolder}/6t.jpg` и `.../5t.jpg`, оба 200
            // image/jpeg. Прошлый "фикс" (переиспользование полноразмерной
            // ссылки на .webp вместо неё) был перестраховкой без
            // подтверждения — теперь не нужен, откатываем на настоящую
            // миниатюру.
            //
            // ВАЖНО — перепроверено живым curl: сам CDN картинок
            // (m11.imhentai.xxx) НЕ прикрыт Cloudflare вообще (200 без
            // единой cf_clearance-куки, хотя HAR-запрос браузера её и
            // нёс — просто по инерции с основного домена, не потому что
            // требуется). Cloudflare-джва-челлендж стоит ТОЛЬКО на
            // HTML-страницах (`/gallery/`, `/view/`, `/`, `/search/`
            // изредка) — сама выдача картинок (обложка/миниатюры/страницы
            // чтения) от него не зависит, значит после того как HTML
            // карточки успешно получен (с реального устройства — сайт его
            // отдаёт нормально, см. doc-comment типа), дальнейшая загрузка
            // ЛЮБЫХ картинок пройдёт без проблем.
            pages = (1...loadPages).map { n in
                ExternalGalleryPage(
                    index: n, key: storageKey, width: 0, height: 0,
                    thumbnailURL: URL(string: "https://\(storageKey)/\(n)t.jpg"),
                    thumbnailSpriteOffsetX: nil
                )
            }
            // `thumb.jpg` — подтверждено живым curl (31.08) на реальной
            // странице /search/?key=... (не заблокирована Cloudflare, в
            // отличие от /gallery/) — `<img src="https://m11.imhentai.xxx/
            // 032/{id}/thumb.jpg">` на карточках в сетке каталога.
            coverURL = URL(string: "https://\(storageKey)/thumb.jpg")
        }

        return ExternalGalleryDetail(
            id: id,
            site: .imhentai,
            title: title,
            type: type,
            language: languageParts.isEmpty ? nil : languageParts.joined(separator: ", "),
            tags: tags,
            artists: artists,
            groups: groups,
            characters: characters,
            series: series,
            // Похожих тайтлов ("Related") на карточке imhentai не
            // встретилось ни на одной из проверенных страниц — честно
            // пусто, как у e-hentai/3hentai.
            related: [],
            pages: pages,
            coverURL: coverURL,
            posted: posted,
            // e-hentai-специфичные поля (Parent/Visible/File Size/Rating)
            // у imhentai не подтверждены — честно nil, не выдумываем.
            // Favourite-счётчик кладём в favoritedCount — ближайший
            // подходящий по смыслу существующий слот.
            parentId: nil, visible: nil, fileSize: nil, favoritedCount: favoritedCount,
            ratingAverage: nil, ratingCount: nil, comments: []
        )
    }

    // MARK: URL картинок

    /// Чистая формула (host+dir+id уже в `page.key`, см. parseDetail) —
    /// без сети, как у hitomi/3hentai (в отличие от e-hentai — там реальный
    /// запрос на каждую страницу), просто обёрнута в async ради общего
    /// протокола. Подтверждено живым HAR (`/view/{id}/1/` →
    /// `<img id="gimg" src="https://m11.imhentai.xxx/032/{id}/1.webp">`).
    func pageImageURL(galleryId: Int, page: ExternalGalleryPage) async throws -> URL {
        guard let url = URL(string: "https://\(page.key)/\(page.index).webp") else {
            throw ImhentaiError.badResponse
        }
        return url
    }

    // MARK: Утилиты

    private static func firstMatch(in html: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges == 2,
              let matchRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[matchRange])
    }

    /// Вырезает вложенные HTML-теги (например `<span class='split_tag'>
    /// ...</span>` внутри h3 на letter-index страницах) — тот же приём,
    /// что у ThreeHentaiProvider.stripInnerTags.
    private static func stripInnerTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
