import SwiftUI

/// Единый экран состояния — "нет сети", "список пуст", "войдите, чтобы...",
/// "профиль закрыт" и т.д. По прямой просьбе объединяет ~20 ранее разнобойных
/// мест (разные иконки/шрифты/кнопки повтора, где-то retry вообще не было) в
/// один вид: иконка (если есть) крупнее текста, заголовок по центру, под ним
/// необязательное описание, и акцентная кнопка-чип "Повторить", если передан
/// `retry`. Где иконка не нужна по смыслу — просто не передаём (`icon: nil`).
struct StateView: View {
    var icon: String? = nil
    var title: String
    var description: String? = nil
    var retry: (() -> Void)? = nil
    /// true — заполняет и центрирует по ВСЕМУ доступному пространству (весь
    /// экран/весь список пуст, тот же эффект, что раньше давал системный
    /// ContentUnavailableView). false (по умолчанию) — вписывается в
    /// фиксированную область НА странице (вкладка комментариев, секция
    /// "Нет тайтлов" внутри уже скроллящегося экрана и т.п.) — тогда высоту
    /// задаёт minHeight, как раньше задавал свой .frame(minHeight:) на
    /// каждом отдельном месте.
    var fillScreen: Bool = false
    var minHeight: CGFloat? = nil
    /// Цвета — по умолчанию Theme.* (тема приложения). Читалка использует
    /// СОБСТВЕННУЮ, независимую от темы приложения палитру (см.
    /// ReaderPalette — независимость намеренная, не путать/объединять с
    /// Theme), поэтому её экраны (ChapterCommentsSheet и т.п.) передают
    /// сюда свои foreground/secondary — тот же вид компонента, просто под
    /// палитру читалки, а не под Theme.
    var foreground: Color = Theme.textPrimary
    var secondary: Color = Theme.textSecondary
    var accent: Color = Theme.accent
    var accentForeground: Color = Theme.background

    var body: some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(secondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Text("Повторить")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentForeground)
                        .padding(.horizontal, 20)
                        .frame(height: Theme.pillControlHeight)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: fillScreen ? .infinity : nil)
    }
}

#Preview {
    VStack(spacing: 40) {
        StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: "Ошибка сервера (500).", retry: {})
        StateView(icon: "bookmark", title: "Пусто")
        StateView(title: "Войдите, чтобы оставить комментарий")
        StateView(icon: "lock.fill", title: "Профиль закрыт", description: "username")
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
