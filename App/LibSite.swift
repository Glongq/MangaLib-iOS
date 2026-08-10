import Foundation

/// Один из "зеркальных" сайтов экосистемы Lib.social — общий аккаунт и API
/// (api.cdnlibs.org), просто разный контент по заголовку Site-Id. AnimeLib
/// сознательно не включён (по просьбе — это отдельная история, видео, а не
/// тексты/картинки).
///
/// Числа id подтверждены раньше (см. чат): 1=MangaLib, 2=RanobeLib,
/// 3=HentaiLib, 4=SlashLib. Домены — из README otaku-melons/mangalib
/// (модуль парсеров Melon, явно перечисляет источники и их сайты).
enum LibSite: Int, CaseIterable, Identifiable, Codable, Hashable {
    case mangalib = 1
    case slashlib = 2
    case ranobelib = 3
    case hentailib = 4

    var id: Int { rawValue }

    // ИСПРАВЛЕНО: реальное поведение site_id на бэкенде не совпадало с
    // изначальным (угаданным по README) распределением 1/2/3/4 —
    // пользователь проверил вживую и обнаружил, что выбор "SlashLib" в меню
    // реально отдавал контент HentaiLib, а выбор "HentaiLib" отдавал
    // RanobeLib. Сами числа site_id (и их привязка к реальным доменам)
    // работают отлично — поменялись только подписи/порядок кейсов, чтобы
    // имя в меню совпадало с реально приходящим контентом.
    var displayName: String {
        switch self {
        case .mangalib:  return "MangaLib"
        case .slashlib:  return "SlashLib"
        case .ranobelib: return "RanobeLib"
        case .hentailib: return "HentaiLib"
        }
    }

    var host: String {
        switch self {
        case .mangalib:  return "mangalib.me"
        case .slashlib:  return "slashlib.me"
        case .ranobelib: return "ranobelib.me"
        case .hentailib: return "hentailib.me"
        }
    }
}

/// Текущий активный сайт (определяет Site-Id для каталога/закладок/истории/
/// карточки тайтла — то есть ВСЁ, что привязано к конкретному серверу) плюс
/// отдельный, независимый набор сайтов для ПОИСКА (мультивыбор — поиск может
/// искать сразу по нескольким сайтам одновременно, вне зависимости от того,
/// какой сайт сейчас активен для закладок/истории).
///
/// ЧЕСТНО о степени уверенности: у экосистемы один общий аккаунт на все сайты
/// (см. README otaku-melons/mangalib: "Токен аккаунта SocialLib для доступа
/// к контенту с ограниченным доступом") — тот же Bearer-токен уже работает
/// везде, Site-Id лишь просит бэкенд показать контент другого сайта, так что
/// переключение НЕ должно требовать повторного логина. Но саму механику
/// закладок/истории на остальных трёх сайтах (кроме уже проверенного
/// MangaLib, id=1) мы никогда не гоняли вживую — путь запросов идентичен,
/// однако именно это не проверенный факт.
///
/// Не помечен @MainActor (как и AuthSession) — читается синхронно из
/// MangaNetworkService.defaultHeaders на любом потоке, без async/await.
final class SiteSession: ObservableObject {
    static let shared = SiteSession()

    @Published var activeSite: LibSite {
        didSet { persistActive() }
    }

    /// Мультивыбор сайтов для поиска — независим от activeSite. Пустой набор
    /// означает "искать только на активном сайте" (см. effectiveSearchSites).
    @Published var searchSites: Set<LibSite> {
        didSet { persistSearchSites() }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let active = "site_active"
        static let search = "site_search_set"
    }

    private init() {
        if let raw = defaults.object(forKey: Keys.active) as? Int, let site = LibSite(rawValue: raw) {
            activeSite = site
        } else {
            activeSite = .mangalib
        }
        if let raws = defaults.array(forKey: Keys.search) as? [Int] {
            searchSites = Set(raws.compactMap(LibSite.init(rawValue:)))
        } else {
            searchSites = []
        }
    }

    /// Реальный список сайтов для site_id[] при поиске/каталоге — активный
    /// сайт входит ВСЕГДА (даже если галочка внизу меню для него не стоит),
    /// плюс всё, что отдельно отмечено чекбоксами.
    var effectiveSearchSites: [LibSite] {
        var set = searchSites
        set.insert(activeSite)
        return LibSite.allCases.filter { set.contains($0) }
    }

    private func persistActive() {
        defaults.set(activeSite.rawValue, forKey: Keys.active)
    }

    private func persistSearchSites() {
        defaults.set(searchSites.map(\.rawValue), forKey: Keys.search)
    }
}
