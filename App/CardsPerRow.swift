import Foundation

/// Сколько карточек в ряд показывать в сетках приложения — 2/3/4 или
/// "Авто" (по прямой просьбе вариант "1" убран). Настройка выбирается в
/// Персонализации (см. PersonalizationSettingsView.cardsPerRowSection) и
/// реально читается сетками Каталога (MangaCatalogView) и Закладок
/// (BookmarksView, режим "Плитка") — общий тип вынесен сюда, чтобы обе
/// сетки могли использовать один и тот же `@AppStorage`.
enum CardsPerRow: Int, CaseIterable, Identifiable {
    case two = 2, three = 3, four = 4, auto = 0

    var id: Int { rawValue }
    var label: String { self == .auto ? "Авто" : "\(rawValue)" }
    /// Реальное число колонок сетки — "Авто" сейчас всегда означает 3
    /// (адаптивный расчёт под ширину экрана/ориентацию не запрашивался).
    var columns: Int { self == .auto ? 3 : rawValue }
}
