import SwiftUI
import Combine

/// Переключатель тёмной/белой темы приложения — настройка в AppSettingsView,
/// по умолчанию включена тёмная тема. НЕЗАВИСИМ от темы читалки (см.
/// MangaReaderView.readerTheme/readerIsLight и ChapterCommentsSheet/
/// CommentSettingsSheet.palette — у читалки своя, отдельная настройка,
/// эту менеджер не трогает).
///
/// Экраны подписываются на изменения через `@ObservedObject private var
/// themeManager = ThemeManager.shared` (сам объект нигде дальше не читается —
/// само наличие @ObservedObject-поля заставляет SwiftUI перевычислить body
/// экрана при переключении темы, а `Theme.xxx` внутри тела уже подхватит
/// свежее значение `Theme.isDark`).
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var isDarkTheme: Bool {
        didSet {
            Theme.isDark = isDarkTheme
            defaults.set(isDarkTheme, forKey: Keys.isDarkTheme)
        }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let isDarkTheme = "app_is_dark_theme"
    }

    private init() {
        if let stored = defaults.object(forKey: Keys.isDarkTheme) as? Bool {
            isDarkTheme = stored
        } else {
            isDarkTheme = true // по умолчанию тёмная тема
        }
        Theme.isDark = isDarkTheme
    }
}

/// Палитра приложения — тёмная (по умолчанию) и белая тема, переключаются
/// через ThemeManager.shared.isDarkTheme. Независима от палитры читалки.
enum Theme {
    /// Текущий режим — синхронизируется с ThemeManager.shared.isDarkTheme при
    /// каждом изменении настройки, а также при старте приложения.
    static var isDark: Bool = true

    /// Основной фон приложения.
    static var background: Color { isDark ? Dark.background : Light.background }
    /// Фон поверхностей (карточки, панели, бары).
    static var surface: Color { isDark ? Dark.surface : Light.surface }
    /// Фон приподнятых элементов (поля ввода, чипсы).
    static var surfaceElevated: Color { isDark ? Dark.surfaceElevated : Light.surfaceElevated }
    /// Акцентный цвет (кнопки, активные иконки) — один и тот же в обеих темах.
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.12)             // #FF8C1F (оранжевый)
    /// Основной текст.
    static var textPrimary: Color { isDark ? Dark.textPrimary : Light.textPrimary }
    /// Второстепенный текст.
    static var textSecondary: Color { isDark ? Dark.textSecondary : Light.textSecondary }
    /// Разделители/границы.
    static var separator: Color { isDark ? Dark.separator : Light.separator }
    /// Цвет скелетона загрузки.
    static var skeleton: Color { isDark ? Dark.skeleton : Light.skeleton }
    /// Единая высота "пилюль"-кнопок (Фильтры/Сортировка в Каталоге, чипы
    /// подкатегорий в Закладках) — общая константа, чтобы они были СТРОГО
    /// одинаковой высоты, независимо от разницы в шрифтах/паддингах между
    /// экранами.
    static let pillControlHeight: CGFloat = 44
    /// ЭТАЛОН обложки тайтла на будущее — соотношение сторон 2:3 (высота =
    /// ширина × 1.5) и радиус скругления 16, как в Каталоге/Новинках (см.
    /// MangaCardView.cover — там `frame(width:, height: (width*3/2).rounded())`
    /// + `RoundedRectangle(cornerRadius: 16)`). По просьбе зафиксировано
    /// здесь как справочная константа — реального рефакторинга ПОКА нет,
    /// сделаем отдельным проходом позже. Закладки/Новое уже приведены (см.
    /// BookmarksView.bookmarkCoverWidth/Height, NotificationsView.row).
    ///
    /// Инвентаризация мест с ДРУГИМ радиусом у обложки тайтла (снятая
    /// grep'ом по .clipShape(RoundedRectangle(cornerRadius:)) сразу после
    /// RemoteImage(url:) — возможно неполная, но как отправная точка):
    /// - CharacterView.swift:74 — 18
    /// - DownloadTitleSheet.swift:146, HistoryView.swift:178,
    ///   MangaDetailView.swift:325, MyCommentsView.swift:118 — 12
    /// - DownloadsView.swift:93, HomeView.swift:567 (collectionPreviewStack) — 8
    /// - HomeView.swift:438 (currentlyReadingRow), MangaDetailView.swift:845 — 14
    /// - HomeView.swift:617 (topActiveUserCard, аватарка — не обложка тайтла,
    ///   под этот эталон не подпадает) — 12
    /// Уже на эталоне (16): AccountInfoView:166, BookmarksView:324,
    /// HomeView:266/790, MangaDetailView:921/1073, NotificationsView:226.
    static let coverCornerRadius: CGFloat = 16
    static let coverAspectRatio: CGFloat = 1.5 // height / width

    /// Фиксированная тёмная палитра (в стиле MangaLib) — значения НЕ меняются
    /// в зависимости от Theme.isDark. Кроме самого Theme (когда isDark ==
    /// true), на неё напрямую опирается ReaderPalette в MangaReaderView —
    /// тёмная тема ЧИТАЛКИ должна оставаться неизменной, даже если
    /// пользователь переключит белую/чёрную тему приложения.
    enum Dark {
        static let background = Color(red: 0.055, green: 0.058, blue: 0.075)      // #0E0F13
        static let surface = Color(red: 0.098, green: 0.105, blue: 0.130)         // #191B21
        static let surfaceElevated = Color(red: 0.145, green: 0.153, blue: 0.184) // #25272F
        static let textPrimary = Color(red: 0.925, green: 0.933, blue: 0.949)     // #ECEEF2
        static let textSecondary = Color(red: 0.596, green: 0.615, blue: 0.667)   // #989DAA
        static let separator = Color.white.opacity(0.08)
        static let skeleton = Color.white.opacity(0.06)
    }

    /// Белая палитра.
    enum Light {
        static let background = Color(red: 0.961, green: 0.961, blue: 0.969)      // #F5F5F7
        static let surface = Color(red: 1.0, green: 1.0, blue: 1.0)               // #FFFFFF
        static let surfaceElevated = Color(red: 0.925, green: 0.925, blue: 0.937) // #ECECEF
        static let textPrimary = Color(red: 0.086, green: 0.090, blue: 0.110)     // #16171C
        static let textSecondary = Color(red: 0.431, green: 0.443, blue: 0.502)   // #6E7180
        static let separator = Color.black.opacity(0.08)
        static let skeleton = Color.black.opacity(0.06)
    }
}

extension AnyTransition {
    /// Тот же приём, что и скрытие интерфейса в читалке (см. MangaReaderView:
    /// .opacity + .blur(radius: 12) на easeInOut) — здесь применяется к
    /// элементам, которые ВХОДЯТ/ВЫХОДЯТ из дерева (шапки "Каталог"/
    /// "Закладки"/"Уведомления", панели Фильтры/Сортировка), а не просто
    /// переключают модификатор на уже присутствующей вьюхе, поэтому нужен
    /// настоящий AnyTransition, а не .blur() напрямую.
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(blur: 12, opacity: 0),
            identity: BlurFadeModifier(blur: 0, opacity: 1)
        )
    }
}

private struct BlurFadeModifier: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: blur).opacity(opacity)
    }
}
