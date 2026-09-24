import SwiftUI
import UIKit

/// "Персонализация" — набор пунктов персонализации приложения, каждый в
/// своей отдельной карточке-подложке (по прямой просьбе, вместо одной общей
/// секции, как в AppSettingsView). Порядок пунктов — тоже по прямой просьбе
/// (скриншот-пример), "Главная страница" специально в самом низу.
/// "Значок приложения"/"Стартовая страница" — пока обычные переходы-заглушки
/// (StubView), тот же приём, что и у остальных ещё не реализованных пунктов
/// настроек (см. AppSettingsView.settingsRow). "Компактный вид нижнего
/// меню"/"Цензурировать изображения в комментариях" — реальные,
/// СОХРАНЯЮЩИЕСЯ тумблеры (@AppStorage), но пока без применения к самому
/// поведению приложения — тот же принцип "заглушка, но не выдуманная", что
/// уже используется в MangaDetailView (commentsDisabledInReader/
/// commentsDisabledOnCard). "Тёмная тема"/"OLED-режим" — каждый в СВОЕЙ
/// подложке, подпись под ней (не внутри строки тумблера) — эталон "Резервная
/// копия в iCloud" в системных Настройках iOS. "Количество отображаемого
/// контента" — реальный параметр (см. CardsPerRow), который теперь читают
/// сетки Каталога и Закладок (режим "Плитка"). "Главная страница"
/// (homeSectionsCard) — порядок (drag) и видимость (чекбокс) разделов
/// вкладки «Читают», реально применяется там же (см. HomeSectionsStore/
/// HomeView.content).
struct PersonalizationSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    /// Порядок/видимость разделов главной — см. homeSectionsCard.
    @ObservedObject private var sectionsStore = HomeSectionsStore.shared

    @AppStorage("personalization_compact_tab_bar") private var compactTabBar = false
    @AppStorage("personalization_censor_comment_images") private var censorCommentImages = false
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                // Порядок — по прямой просьбе (скриншот-пример):
                // Значок → Стартовая → Компактное меню → Цензура
                // комментариев → Тёмная тема → OLED → Кол-во карточек →
                // Главная страница (порядок разделов) в самом низу.
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
                            Text("Цензурировать изображения в комментариях").foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }

                    // Тёмная тема и OLED — теперь ДВЕ РАЗНЫЕ подложки (было
                    // одна общая с разделителем), подпись — под подложкой,
                    // не внутри строки тумблера, эталон — "Резервная копия в
                    // iCloud" в системных Настройках iOS (по прямой просьбе,
                    // со скриншотом).
                    VStack(alignment: .leading, spacing: 8) {
                        card {
                            Toggle(isOn: $themeManager.isDarkTheme) {
                                HStack(spacing: 10) {
                                    Text("Тёмная тема").foregroundStyle(Theme.textPrimary)
                                    darkThemeIcon
                                }
                            }
                            .tint(Theme.accent)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                        Text("Выключи для белой темы. Не влияет на тему читалки — она настраивается отдельно.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                    }

                    // Отдельный, независимый тумблер — не альтернатива
                    // светлой/тёмной теме (та выше), а "ещё темнее" ПОВЕРХ
                    // уже тёмной: чистый чёрный фон вместо #0E0F13 и т.д.
                    // (см. Theme.OLED). На белой теме визуально ничего не
                    // меняет — выключен (disabled), пока тёмная тема выключена.
                    VStack(alignment: .leading, spacing: 8) {
                        card {
                            Toggle(isOn: $themeManager.isOLEDTheme) {
                                HStack(spacing: 6) {
                                    Text("OLED-режим")
                                        .foregroundStyle(themeManager.isDarkTheme ? Theme.textPrimary : Theme.textSecondary)
                                    // Квадратик справа от названия — по
                                    // прямой просьбе, тот же чёрный квадрат,
                                    // что и в darkThemeIcon.
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.black)
                                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.separator, lineWidth: 1))
                                        .frame(width: 16, height: 16)
                                }
                            }
                            .tint(Theme.accent)
                            .disabled(!themeManager.isDarkTheme)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                        Text("Делает тёмную тему ещё темнее — фон почти чистый чёрный.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                    }

                    card {
                        cardsPerRowSection
                            .padding(16)
                    }

                    card { homeSectionsCard }

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

    // MARK: Главная страница — порядок/видимость разделов

    /// Заголовок + "Сбросить" сверху, ниже — перетаскиваемый список разделов
    /// с чекбоксом видимости слева у каждого (см. homeSectionRow). Реально
    /// применяется на вкладке «Читают» (см. HomeView.content/HomeSectionsStore).
    private var homeSectionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Главная страница")
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Button("Сбросить") { sectionsStore.resetToDefaults() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            homeSectionsList
        }
    }

    private static let homeSectionRowHeight: CGFloat = 52

    /// Кто сейчас тянут (по ручке) и текущее вертикальное смещение — только
    /// Y, .draggable/.dropDestination убраны: та версия позволяла тянуть
    /// строку свободно в любую сторону, включая горизонталь ("типа скролл
    /// влево вправо можно двигать" — с точки зрения пользователя строка
    /// "гуляла" туда-обратно). Кастомный DragGesture ниже читает только
    /// value.translation.height.
    @State private var draggedKind: HomeSectionKind?
    @State private var dragOffsetY: CGFloat = 0

    /// Обычный VStack, БЕЗ List — раньше здесь стоял List (+ .scrollDisabled
    /// + editMode.constant(.active)) для перетаскивания строк, но он всё
    /// равно остаётся отдельным UIScrollView (UITableView) ПОД капотом даже
    /// с выключенным своим скроллом — вложенный внутрь ВНЕШНЕГО ScrollView
    /// экрана Персонализации, он перехватывал/задерживал жест скролла
    /// внешнего ScrollView именно в области этого блока (по прямой просьбе:
    /// "скролл не зафиксирован в разделе персонализация" — в остальных
    /// разделах настроек такого List нет, скролл вёл себя нормально).
    /// Перетаскивание — кастомный DragGesture (см. dragHandleGesture),
    /// навешанный ТОЛЬКО на иконку-ручку в homeSectionRow, а не на всю
    /// строку: иначе любой тач по строке конфликтовал бы со скроллом
    /// внешнего ScrollView вместо перетаскивания.
    private var homeSectionsList: some View {
        VStack(spacing: 0) {
            ForEach(sectionsStore.order) { kind in
                homeSectionRow(kind)
                    .zIndex(draggedKind == kind ? 1 : 0)
                    .offset(y: draggedKind == kind ? dragOffsetY : 0)
            }
        }
        .padding(.bottom, 8)
    }

    /// Читает только translation.height (никогда .width) — строго
    /// вертикальное перетаскивание. По ходу драга сразу переставляет раздел
    /// в sectionsStore, как только смещение "перевешивает" за половину
    /// высоты соседней строки, и тут же гасит уже учтённую часть смещения —
    /// чтобы после перестановки строка не "прыгала", а продолжала плавно
    /// следовать за пальцем.
    private func dragHandleGesture(for kind: HomeSectionKind) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                draggedKind = kind
                dragOffsetY = value.translation.height

                guard let from = sectionsStore.order.firstIndex(of: kind) else { return }
                let shift = Int((dragOffsetY / Self.homeSectionRowHeight).rounded())
                guard shift != 0 else { return }
                let to = min(max(from + shift, 0), sectionsStore.order.count - 1)
                guard to != from else { return }

                sectionsStore.moveSections(fromOffsets: IndexSet(integer: from),
                                            toOffset: to > from ? to + 1 : to)
                dragOffsetY -= CGFloat(to - from) * Self.homeSectionRowHeight
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    draggedKind = nil
                    dragOffsetY = 0
                }
            }
    }

    /// Скруглённый чекбокс слева (заливка акцентом, если раздел включён) —
    /// по прямой просьбе, вместо системного Toggle-переключателя. Ручка
    /// перетаскивания справа — теперь единственное место, за которое реально
    /// тянут (см. dragHandleGesture); остальная часть строки свободна для
    /// скролла внешнего ScrollView.
    private func homeSectionRow(_ kind: HomeSectionKind) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sectionsStore.toggleVisibility(kind)
                }
            } label: {
                let visible = sectionsStore.isVisible(kind)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(visible ? Theme.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.separator, lineWidth: visible ? 0 : 1.5)
                    )
                    .overlay {
                        if visible {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.background)
                        }
                    }
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            Text(kind.title)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Image(systemName: "line.3.horizontal")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(dragHandleGesture(for: kind))
        }
        .padding(.horizontal, 16)
        .frame(height: Self.homeSectionRowHeight)
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

    /// Без стекла (по прямой просьбе) — обычная сплошная заливка, каждый
    /// чип растягивается на равную долю ширины (см. cardsPerRowSection —
    /// вся строка чипов теперь той же ширины, что и остальной контент
    /// карточки, а не компактные чипы с пустым местом справа).
    private func cardsPerRowChip(_ option: CardsPerRow) -> some View {
        let active = cardsPerRow == option
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { cardsPerRow = option }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.background : Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: Theme.pillControlHeight)
                .background(active ? Theme.accent : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Ключ для .animation(value:) ниже — раньше туда шёл только cardsPerRow,
    /// поэтому смена тёмная/светлая (или OLED) не запускала перерисовку
    /// ЭТОГО конкретного блока: сами карточки просто не перекрашивались,
    /// пока не тронешь 2/3/4/Авто (минибаг, по прямой просьбе).
    private struct CardsPreviewKey: Equatable {
        let cardsPerRow: CardsPerRow
        let isDark: Bool
        let isOLED: Bool
    }

    /// Пол высоты области превью — заметно больше прежних 90pt, по прямой
    /// просьбе "сделай больше высоту блока". Реальная высота (см. ниже,
    /// считается от 2-колоночного случая) на типичных экранах и так больше
    /// этого числа — это именно СТРАХОВОЧНЫЙ минимум на узких устройствах.
    private static let cardsPreviewMinHeight: CGFloat = 130

    /// Карточки заполняют ширину блока целиком (ширина каждой = доступная
    /// ширина / count) — раньше был фиксированный размер у самих карточек,
    /// из-за чего при смене 2/3/4/Авто лишние карточки просто ПРОПАДАЛИ/
    /// ПОЯВЛЯЛИСЬ рывком (менялось количество одинаковых прямоугольников, а
    /// не их размер) — по прямой просьбе "не так что просто пропадает
    /// появляется картинка карточки", теперь все карточки плавно
    /// сужаются/расширяются при переключении.
    ///
    /// Высота КОНТЕЙНЕРА при этом всё равно фиксированная (иначе вернулся бы
    /// прошлый баг "блок прыгает по высоте при переключении") — берётся по
    /// самому широкому случаю (2 колонки, при котором карточки выше всего
    /// при сохранении 2:3), не по текущему count. У 3/4 карточки короче
    /// этого максимума — по прямой просьбе "вмещалось РАВНО" центрированы по
    /// вертикали (не прижаты к верху с пустым местом снизу, а симметрично
    /// вписаны в блок при любом 2/3/4/Авто).
    private var cardsPreview: some View {
        let count = cardsPerRow.columns
        let spacing: CGFloat = 8
        let availableWidth = UIScreen.main.bounds.width - 64
        let cardWidth = max(0, (availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
        let cardHeight = (cardWidth * 3 / 2).rounded()
        let maxCardWidth = max(0, (availableWidth - spacing) / 2) // count = 2, самый широкий случай
        let containerHeight = max((maxCardWidth * 3 / 2).rounded(), Self.cardsPreviewMinHeight)
        return HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: cardWidth, height: cardHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: containerHeight, alignment: .center)
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: CardsPreviewKey(cardsPerRow: cardsPerRow, isDark: themeManager.isDarkTheme, isOLED: themeManager.isOLEDTheme))
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
