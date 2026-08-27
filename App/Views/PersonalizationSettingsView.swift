import SwiftUI
import UIKit

/// "Персонализация" — набор пунктов персонализации приложения, каждый в
/// своей отдельной карточке-подложке (по прямой просьбе, вместо одной общей
/// секции, как в AppSettingsView). "Значок приложения"/"Стартовая
/// страница" — пока обычные переходы-заглушки (StubView), тот же приём, что
/// и у остальных ещё не реализованных пунктов настроек (см.
/// AppSettingsView.settingsRow). "Компактный вид нижнего меню"/"Изображения
/// в комментариях" — реальные, СОХРАНЯЮЩИЕСЯ тумблеры (@AppStorage), но пока
/// без применения к самому поведению приложения — тот же принцип "заглушка,
/// но не выдуманная", что уже используется в MangaDetailView
/// (commentsDisabledInReader/commentsDisabledOnCard). "Количество
/// отображаемого контента" — реальный параметр (см. CardsPerRow), который
/// теперь читают сетки Каталога и Закладок (режим "Плитка").
struct PersonalizationSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @AppStorage("personalization_compact_tab_bar") private var compactTabBar = false
    @AppStorage("personalization_censor_comment_images") private var censorCommentImages = false
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    card {
                        NavigationLink {
                            StubView(title: "Значок приложения")
                        } label: {
                            rowLabel(icon: "app", title: "Значок приложения")
                        }
                        .buttonStyle(.plain)
                    }

                    card {
                        NavigationLink {
                            StubView(title: "Стартовая страница")
                        } label: {
                            rowLabel(icon: "house", title: "Стартовая страница")
                        }
                        .buttonStyle(.plain)
                    }

                    card {
                        Toggle(isOn: $compactTabBar) {
                            Text("Компактный вид нижнего меню").foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }

                    card {
                        Toggle(isOn: $censorCommentImages) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Изображения в комментариях").foregroundStyle(Theme.textPrimary)
                                Text(censorCommentImages ? "Цензурировать" : "Показывать")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }

                    card {
                        Toggle(isOn: $themeManager.isDarkTheme) {
                            HStack(spacing: 10) {
                                darkThemeIcon
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Тёмная тема").foregroundStyle(Theme.textPrimary)
                                    Text("Выключи для белой темы. Не влияет на тему читалки — она настраивается отдельно.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)

                        Divider().overlay(Theme.separator).padding(.leading, 16)

                        // Отдельный, независимый тумблер — не альтернатива
                        // светлой/тёмной теме (та выше), а "ещё темнее" ПОВЕРХ
                        // уже тёмной: чистый чёрный фон вместо #0E0F13 и т.д.
                        // (см. Theme.OLED). На белой теме визуально ничего не
                        // меняет — выключен (disabled), пока тёмная тема выключена.
                        Toggle(isOn: $themeManager.isOLEDTheme) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("OLED-режим")
                                    .foregroundStyle(themeManager.isDarkTheme ? Theme.textPrimary : Theme.textSecondary)
                                Text("Делает тёмную тему ещё темнее — фон почти чистый чёрный.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.accent)
                        .disabled(!themeManager.isDarkTheme)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }

                    card {
                        cardsPerRowSection
                            .padding(16)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Персонализация")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Тёмная тема — декоративная иконка перехода светлый→тёмный

    /// Тёмно-серый квадратик → стрелка → чёрный квадратик — визуальный
    /// намёк на "светлая тема превращается в тёмную", по прямой просьбе.
    /// Обводка у чёрного квадрата — иначе на тёмном фоне карточки
    /// (Theme.surfaceElevated в тёмной теме почти такой же чёрный) он бы
    /// сливался с подложкой и не читался как отдельная фигура.
    private var darkThemeIcon: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(white: 0.42))
                .frame(width: 16, height: 16)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.separator, lineWidth: 1))
                .frame(width: 16, height: 16)
        }
    }

    // MARK: Количество карточек в ряд

    private var cardsPerRowSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Количество отображаемого контента в виде карточек")
                    .foregroundStyle(Theme.textPrimary)
                Text("Вы можете выбрать какое количество элементов отображать в одном ряду")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                ForEach(CardsPerRow.allCases) { option in
                    cardsPerRowChip(option)
                }
            }

            cardsPreview
        }
    }

    private func cardsPerRowChip(_ option: CardsPerRow) -> some View {
        let active = cardsPerRow == option
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { cardsPerRow = option }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.background : Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: Theme.pillControlHeight)
                .contentShape(Capsule())
                // Тот же рецепт активного/обычного стекла, что и у чипов
                // папок в Закладках (см. BookmarksView.categoryChip).
                .glassEffect(active ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Плавная (анимированная при смене выбора) визуализация — N карточек
    /// формата 2:3 в ряд. Ширина карточек считается от ширины экрана
    /// напрямую (без GeometryReader — высота тогда была бы обратной
    /// зависимостью от самой себя): 64 = те же горизонтальные отступы, что
    /// и у остальных карточек этого экрана (16 у ScrollView + 16 у card,
    /// с каждой стороны).
    private var cardsPreview: some View {
        let count = cardsPerRow.columns
        let spacing: CGFloat = 8
        let availableWidth = UIScreen.main.bounds.width - 64
        let totalSpacing = spacing * CGFloat(count - 1)
        let cardWidth = max(0, (availableWidth - totalSpacing) / CGFloat(count))
        return HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: cardWidth, height: cardWidth * 3 / 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: cardsPerRow)
    }

    // MARK: Общие помощники

    // Радиус — тот же, что и у карточек в разделе "Меню" (см.
    // SideMenuView.cardCornerRadius) — это эталон, под него выравниваем.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Та же вёрстка строки, что и у AppSettingsView.settingsRowLabel
    /// (иконка/текст/шеврон) — своя копия, та не видна за пределами файла.
    private func rowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack { PersonalizationSettingsView() }
        .preferredColorScheme(.dark)
}
