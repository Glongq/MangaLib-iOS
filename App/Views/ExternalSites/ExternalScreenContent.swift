import SwiftUI

/// A shared "unavailable on an external site" screen — used at the start
/// of the `body` of affected screens (Bookmarks/Reading/New, see the plan,
/// Part 3), as an ADDITIONAL branch ahead of their normal content:
/// ```swift
/// var body: some View {
///     if let ext = ExternalSiteSession.shared.activeExternalSite {
///         ExternalScreenContent(site: ext, featureTitle: "Закладки")
///     } else {
///         existingBodyAsBefore
///     }
/// }
/// ```
/// hitomi.la (and sites of this kind in general) has no accounts — meaning
/// there can be no bookmarks, no history, no notifications, no comments in
/// principle, this is not "not implemented yet" — the text says so
/// explicitly, rather than pretending to be an ordinary empty placeholder.
struct ExternalScreenContent: View {
    /// nil — combined mode ("All sites", see ExternalSiteSession.
    /// combinedModeActive): the wording isn't tied to one specific site,
    /// since several apply at once.
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
