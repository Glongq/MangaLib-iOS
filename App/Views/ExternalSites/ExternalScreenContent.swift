import SwiftUI

/// Общий «недоступно на внешнем сайте» экран — используется в начале
/// `body` затронутых экранов (Закладки/Читают/Новое, см. план Часть 3),
/// ДОБАВОЧНОЙ веткой перед их обычным содержимым:
/// ```swift
/// var body: some View {
///     if let ext = ExternalSiteSession.shared.activeExternalSite {
///         ExternalScreenContent(site: ext, featureTitle: "Закладки")
///     } else {
///         existingBodyAsBefore
///     }
/// }
/// ```
/// У hitomi.la (и вообще у сайтов такого рода) нет аккаунтов — значит не
/// может быть ни закладок, ни истории, ни уведомлений, ни комментариев в
/// принципе, не "пока не реализовано" — текст это прямо объясняет, а не
/// притворяется обычной пустой заглушкой.
struct ExternalScreenContent: View {
    /// nil — совместный режим («Все сайты», см. ExternalSiteSession.
    /// combinedModeActive): формулировка не привязывается к одному
    /// конкретному сайту, потому что их сразу несколько.
    let site: ExternalSite?
    let featureTitle: String

    private var siteLabel: String { site?.displayName ?? "подключённых сайтов" }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            StateView(
                icon: "xmark.circle",
                title: site.map { "Недоступно на \($0.displayName)" } ?? "Недоступно на подключённых сайтах",
                description: "«\(featureTitle)» — часть аккаунта MangaLib, а у \(siteLabel) нет аккаунтов.",
                fillScreen: true
            )
        }
    }
}
