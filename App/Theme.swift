import SwiftUI

/// Палитра тёмной темы в стиле MangaLib.
enum Theme {
    /// Основной фон приложения.
    static let background = Color(red: 0.055, green: 0.058, blue: 0.075)      // #0E0F13
    /// Фон поверхностей (карточки, панели, бары).
    static let surface = Color(red: 0.098, green: 0.105, blue: 0.130)        // #191B21
    /// Фон приподнятых элементов (поля ввода, чипсы).
    static let surfaceElevated = Color(red: 0.145, green: 0.153, blue: 0.184) // #25272F
    /// Акцентный цвет (кнопки, активные иконки).
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.12)             // #FF8C1F (оранжевый)
    /// Основной текст.
    static let textPrimary = Color(red: 0.925, green: 0.933, blue: 0.949)    // #ECEEF2
    /// Второстепенный текст.
    static let textSecondary = Color(red: 0.596, green: 0.615, blue: 0.667)  // #989DAA
    /// Разделители/границы.
    static let separator = Color.white.opacity(0.08)
    /// Цвет скелетона загрузки.
    static let skeleton = Color.white.opacity(0.06)
    /// Единая высота "пилюль"-кнопок (Фильтры/Сортировка в Каталоге, чипы
    /// подкатегорий в Закладках) — общая константа, чтобы они были СТРОГО
    /// одинаковой высоты, независимо от разницы в шрифтах/паддингах между
    /// экранами.
    static let pillControlHeight: CGFloat = 44
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
