import SwiftUI
import UIKit

/// Sheet настроек комментариев (открывается кнопкой "Настройки" над полем
/// ввода, см. MangaDetailView.commentsHeader):
///   - "Отключить комментарии в читалке" — ПОКА ЗАГЛУШКА (см. поле ниже) —
///     переключатель есть и сохраняется, но реально ни на что не влияет,
///     т.к. комментариев в самой читалке в этом раунде ещё нет.
///   - "Сворачивать вложенные комментарии с уровня N" — слайдер 1...10, над
///     ним живая подпись "с N ур." (обновляется по ходу перетаскивания),
///     плюс короткая вибрация на каждый шаг (см. .onChange ниже).
struct CommentSettingsSheet: View {
    @Binding var disabledInReader: Bool
    @Binding var disabledOnCard: Bool
    @Binding var collapseFromLevel: Double
    /// Палитра читалки — задаётся ТОЛЬКО когда шит открыт из читалки (см.
    /// ChapterCommentsSheet, тема читалки независима от темы приложения). nil
    /// (по умолчанию — так открывает MangaDetailView, "карточка тайтла") —
    /// используем настоящую тему приложения (Theme.xxx, см. background/
    /// foreground/... ниже), которая правильно учитывает OLED. Раньше здесь
    /// был жёстко зашит ReaderPalette(isLight: false) даже для карточки
    /// тайтла — фон не был чёрным на OLED, потому что ReaderPalette всегда
    /// берёт ФИКСИРОВАННУЮ Theme.Dark, а не настоящую Theme.background.
    var palette: ReaderPalette? = nil

    @Environment(\.dismiss) private var dismiss
    /// Нужен только для реактивности (пересчёт body при смене темы/OLED) и
    /// для .preferredColorScheme в ветке без ReaderPalette — см. комментарий
    /// у palette выше и у ThemeManager.
    @ObservedObject private var themeManager = ThemeManager.shared

    private let levelRange: ClosedRange<Double> = 1...10
    /// Один и тот же генератор на весь sheet — .prepare() держит "прогретым",
    /// чтобы вибрация срабатывала сразу без задержки на каждом шаге слайдера.
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var background: Color { palette?.background ?? Theme.background }
    private var foreground: Color { palette?.foreground ?? Theme.textPrimary }
    private var secondary: Color { palette?.secondary ?? Theme.textSecondary }
    private var surface: Color { palette?.surface ?? Theme.surfaceElevated }
    private var separator: Color { palette?.separator ?? Theme.separator }

    var body: some View {
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    // Две опции работают сообща из обоих мест (читалка и карточка).
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $disabledInReader) {
                            Text("Отключить комментарии в читалке")
                                .foregroundStyle(foreground)
                        }
                        .tint(Theme.accent)

                        Divider().overlay(separator)

                        Toggle(isOn: $disabledOnCard) {
                            Text("Отключить комментарии на карточке тайтла")
                                .foregroundStyle(foreground)
                        }
                        .tint(Theme.accent)
                    }
                    .padding(14)
                    .background(surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Сворачивать вложенные комментарии с уровня")
                            .foregroundStyle(foreground)

                        // Живая подпись над слайдером — меняется сразу по
                        // ходу перетаскивания (не только по отпусканию),
                        // как явно попросили.
                        Text("с \(Int(collapseFromLevel)) ур.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)

                        Slider(value: $collapseFromLevel, in: levelRange, step: 1)
                            .tint(Theme.accent)
                            // Короткая вибрация РОВНО РАЗ на каждый шаг —
                            // step:1 у Slider выше уже гарантирует, что
                            // collapseFromLevel меняется только целыми
                            // шагами, поэтому одного .onChange достаточно
                            // (никакой доп. защиты от "дребезга" не нужно).
                            .onChange(of: collapseFromLevel) { _, _ in
                                haptic.impactOccurred()
                            }
                            .onAppear { haptic.prepare() }

                        HStack {
                            Text("1").font(.caption2).foregroundStyle(secondary)
                            Spacer()
                            Text("10 (максимум)").font(.caption2).foregroundStyle(secondary)
                        }
                    }
                    .padding(14)
                    .background(surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .navigationTitle("Настройки комментариев")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Крестик вместо текста "Готово" — тот же размер/цвет, что и
                // у CreditsSheet/TeamMembersSheet, по прямой просьбе выровнять.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .tint(Theme.accent)
        // Из читалки — навбар/заголовок/тумблеры светлеют вместе с темой
        // читалки (palette). С карточки тайтла (palette == nil) — тема
        // приложения (themeManager.isDarkTheme), тот же приём, что и у
        // остальных .sheet в приложении (см. AddToFolderSheet/BookmarksView).
        .preferredColorScheme(palette.map { $0.isLight ? .light : .dark } ?? (themeManager.isDarkTheme ? .dark : .light))
    }
}

#Preview {
    CommentSettingsSheet(disabledInReader: .constant(false), disabledOnCard: .constant(false), collapseFromLevel: .constant(3))
        .preferredColorScheme(.dark)
}
