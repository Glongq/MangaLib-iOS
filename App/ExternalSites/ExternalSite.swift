import Foundation

/// «Другие сайты» — сайты с ПРИНЦИПИАЛЬНО другим API, не входящие в
/// экосистему Lib.social (см. LibSite.swift — mangalib/slashlib/ranobelib/
/// hentailib, один REST/JSON API на двух хостах). По прямой просьбе новый
/// код почти не пересекается со старым сетевым слоем — см. весь этот файл
/// и остальные в App/ExternalSites/: ничего отсюда не импортируется в
/// MangaNetworkService.swift/LibSite.swift, и наоборот.
enum ExternalSite: String, CaseIterable, Identifiable {
    case hitomi
    // Следующие сайты добавляются сюда по мере разбора их HAR (см. план).

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hitomi: return "Hitomi.la"
        }
    }
}

/// Возможности конкретного внешнего сайта — экраны спрашивают ЭТО (через
/// ExternalSiteProvider.capabilities), а не пытаются угадывать по типу
/// сайта: каждый провайдер честно объявляет, что реально умеет, остальное
/// экраны показывают как «Недоступно» (см. ExternalScreenContent).
struct ExternalSiteCapabilities {
    var hasCatalog: Bool
    var hasTagBrowser: Bool
    /// У hitomi.la (и вообще у сайтов такого рода) нет аккаунтов — значит
    /// не может быть ни закладок, ни истории чтения, ни уведомлений, ни
    /// комментариев в принципе, не только "пока не реализовано".
    var hasBookmarks: Bool
    var hasHistory: Bool
    var hasNotifications: Bool
    var hasComments: Bool
}
