import Foundation

/// «Другие сайты» — сайты с ПРИНЦИПИАЛЬНО другим API, не входящие в
/// экосистему Lib.social (см. LibSite.swift — mangalib/slashlib/ranobelib/
/// hentailib, один REST/JSON API на двух хостах). По прямой просьбе новый
/// код почти не пересекается со старым сетевым слоем — см. весь этот файл
/// и остальные в App/ExternalSites/: ничего отсюда не импортируется в
/// MangaNetworkService.swift/LibSite.swift, и наоборот.
enum ExternalSite: String, CaseIterable, Identifiable {
    case hitomi
    case ehentai
    // Следующие сайты добавляются сюда по мере разбора их HAR (см. план).

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hitomi: return "Hitomi.la"
        case .ehentai: return "E-Hentai"
        }
    }
}

/// Возможности конкретного внешнего сайта — экраны спрашивают ЭТО (через
/// ExternalSiteProvider.capabilities), а не пытаются угадывать по типу
/// сайта: каждый провайдер честно объявляет, что реально умеет, остальное
/// экраны показывают как «Недоступно» (см. ExternalScreenContent).
///
/// У e-hentai.org, в отличие от hitomi.la, аккаунты и закладки/избранное
/// РЕАЛЬНО есть на самом сайте — но эта интеграция их не подключает (нет
/// логина), поэтому hasBookmarks и т.д. всё равно false здесь — это
/// "недоступно В ЭТОМ клиенте", а не "у сайта в принципе такого нет" (как
/// честно написано у hitomi). Если когда-нибудь добавится вход в аккаунт
/// e-hentai — это просто поменяется на true, без переделки остального.
struct ExternalSiteCapabilities {
    var hasCatalog: Bool
    var hasTagBrowser: Bool
    /// Свободный текстовый поиск (см. ExternalSiteProvider.fetchIdsBySearch)
    /// — у hitomi формально нет (упирается в неразобранный бинарный
    /// индекс), у e-hentai есть (обычный `?f_search=`). Каталог-экран
    /// (см. MangaCatalogView) выбирает алфавитный справочник ИЛИ поиск
    /// по этому флагу — если нет ни того, ни другого, каталог тоже
    /// «Недоступно», как остальные экраны без аналога.
    var hasSearch: Bool
    var hasBookmarks: Bool
    var hasHistory: Bool
    var hasNotifications: Bool
    var hasComments: Bool
}
