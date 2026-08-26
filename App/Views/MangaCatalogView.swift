import SwiftUI

/// Экран «Каталог»: строка поиска, кнопки Фильтры/Сортировка и сетка карточек.
struct MangaCatalogView: View {

    @StateObject private var viewModel = CatalogViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showFilters = false
    /// Путь навигации — нужен, чтобы при тапе по жанру/тегу в уже открытой
    /// карточке вернуться к корню каталога (см. onReceive switchRequest).
    @State private var navPath = NavigationPath()

    // Схлопывание Фильтры/Сортировка при скролле вниз (вверх — хоть чуть-чуть
    // — возвращается). Поиск и заголовок теперь родной .searchable()/
    // .navigationTitle (см. body) — как в Персонажи/Франшизы/Пользователи —
    // их системная анимация/сворачивание этой логики не касается.
    @State private var headerCollapsed = false
    @State private var lastScrollOffset: CGFloat = 0
    // Пока идёт анимация схлопывания, само изменение высоты шапки на мгновение
    // сдвигает contentOffset ScrollView — не реальный скролл, но без этой
    // защиты обработчик видел его как "скрollнули вверх" и тут же откатывал
    // назад, из-за чего заголовок дёргался. См. тот же фикс в BookmarksView.
    @State private var isHeaderAnimating = false

    // Сетка: ровно 3 колонки одинаковой ширины — строгое выравнивание карточек.
    // Ширину меряем один раз через GeometryReader (см. grid) и кормим ЕЮ ЖЕ
    // и GridItem(.fixed), и саму MangaCardView — см. комментарий у
    // MangaCardView.width про то, почему раньше .flexible()+.aspectRatio
    // иногда расходились на пиксель ("поплывшие" обложки).
    private let gridColumnsCount = 3
    private let gridSpacing: CGFloat = 12
    private let gridHorizontalPadding: CGFloat = 12

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Theme.background.ignoresSafeArea()

                content
            }
            // .large подтверждённо раздувал отступ сверху (известный баг
            // связки TabView + .large на iOS 26) — по факту тестирования
            // на устройстве нужное компактное положение (заголовок+поиск
            // высоко, поиск НИКОГДА не прячется) — это ровно то, что даёт
            // .inline. Блюр на скролле (scrollEdgeEffectStyle) — системный
            // эффект под любой navigationBarTitleDisplayMode, от .large не
            // зависит, должен остаться. displayMode: .always у
            // .searchable — явно держит поле поиска видимым постоянно, не
            // даёт ему схлопнуться/спрятаться при скролле.
            .navigationTitle("Каталог")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск по названию")
            .navigationDestination(for: MangaItem.self) { item in
                MangaDetailView(
                    slug: item.apiSlug,
                    fallbackTitle: item.displayTitle,
                    coverURL: item.cover?.bestURL,
                    item: item
                )
            }
            .sheet(isPresented: $showFilters) {
                FilterView(initial: viewModel.filter) { newFilter in
                    viewModel.apply(filter: newFilter)
                }
            }
            // Фильтры/Сортировка — снизу, над главной панелью. ВНУТРИ
            // NavigationStack (на корневом контенте), а не снаружи него: раньше
            // висели снаружи, чтобы обойти баг совместного расчёта с ВНЕШНИМ
            // инсетом самодельного BottomBar из старого RootView — но с тех
            // пор RootView стал настоящим системным TabView, и та причина
            // отпала. А снаружи NavigationStack эта панель оставалась на
            // экране ПОВЕРХ любого пуша (карточки тайтла и т.д.), потому что
            // технически была соседом стека, а не частью его корневого
            // экрана — отсюда баг "Фильтры/Сортировка не пропадают на
            // карточке тайтла". Прячутся при скролле вниз (см. headerCollapsed/
            // onScrollGeometryChange у content ниже).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !headerCollapsed {
                    controlsBar
                        // 16→20 — выравнено по главной панели (BottomBar тоже
                        // использует padding.horizontal 20), та же ширина и края.
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                        .transition(.blurFade)
                }
            }
        }
        .tint(Theme.accent)
        .onAppear {
            // Пришли из карточки (жанр/тег — готовый фильтр) или из меню «Тайтлы»
            // (тип) — применяем фильтром; иначе обычная первичная загрузка.
            if applyPendingFilter(popToRoot: false) {
                // применили готовый фильтр (жанр/тег)
            } else if let typeId = CatalogNavigator.shared.pendingTypeId {
                CatalogNavigator.shared.pendingTypeId = nil
                ConstantsStore.shared.loadIfNeeded()
                var f = MangaFilter()
                f.types.included = [typeId]
                viewModel.apply(filter: f)
            } else {
                viewModel.loadInitialIfNeeded()
            }
        }
        // Случай, когда карточка открыта из САМОГО Каталога: вкладка не
        // пересоздаётся, поэтому onAppear не сработает — ловим сигнал и
        // возвращаемся к корню каталога с применённым фильтром.
        .onReceive(CatalogNavigator.shared.$switchRequest) { _ in
            _ = applyPendingFilter(popToRoot: true)
        }
    }

    /// Применяет отложенный фильтр из CatalogNavigator (жанр/тег из карточки),
    /// если он есть. popToRoot — сперва вернуться к корню каталога (карточка
    /// была открыта из самого каталога). true — фильтр применён.
    @discardableResult
    private func applyPendingFilter(popToRoot: Bool) -> Bool {
        guard let f = CatalogNavigator.shared.pendingFilter else { return false }
        CatalogNavigator.shared.pendingFilter = nil
        ConstantsStore.shared.loadIfNeeded()
        if popToRoot { navPath = NavigationPath() }
        viewModel.apply(filter: f)
        return true
    }

    // MARK: Фильтры / Сортировка

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                showFilters = true
            } label: {
                // Иконка меняется на "wand.and.stars", когда «Спец фильтр»
                // (см. AppSettingsView/SpecialFilterStore) реально сработал
                // на текущей выборке жанров/тегов — иначе неочевидно, что
                // каталог сейчас не строго AND, а ранжированный поиск.
                controlLabel(
                    icon: viewModel.isSpecialFilterActive ? "wand.and.stars" : "slider.horizontal.3",
                    text: "Фильтры", badge: viewModel.filter.activeCount
                )
            }

            Menu {
                // .inline на ОБОИХ Picker — иначе Picker внутри Menu по
                // умолчанию сворачивается в подменю (доп. тап, чтобы
                // раскрыть), а нужен один плоский список: сначала поля
                // сортировки, направление — отдельной секцией строго внизу.
                Picker("Сортировка", selection: $viewModel.sort) {
                    ForEach(SortOption.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Направление", selection: $viewModel.sortDescending) {
                    Label("По возрастанию", systemImage: "arrow.up").tag(false)
                    Label("По убыванию", systemImage: "arrow.down").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                controlLabel(icon: "arrow.up.arrow.down", text: viewModel.sort.title, badge: 0)
            }

            Spacer(minLength: 0)
        }
    }

    private func controlLabel(icon: String, text: String, badge: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Theme.accent, in: Circle())
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        // Высота выровнена по Theme.pillControlHeight — теперь строго той же
        // высоты, что и чипы подкатегорий в Закладках.
        .frame(minHeight: Theme.pillControlHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage, viewModel.results.isEmpty {
            errorState(error)
        } else if viewModel.results.isEmpty && viewModel.didLoadOnce && !viewModel.isLoading {
            ContentUnavailableView.search(text: viewModel.query)
        } else {
            grid
        }
    }

    // Сначала меряем сетку (GeometryReader — один раз, на весь экран, а НЕ
    // на каждую карточку по отдельности), считаем ширину карточки ОДНИМ
    // числом (MangaCardView.gridCardWidth) и уже ЭТИМ числом одновременно
    // кормим и разбивку на ряды (rows ниже), и саму карточку
    // (MangaCardView.width) — сначала сетка, потом в неё кладём контент, а
    // не наоборот. Ряды — явные HStack по 3 карточки (не LazyVGrid с плоским
    // ForEach): чтобы решить, сколько строк резервировать под название, надо
    // видеть все карточки ряда сразу (см. комментарий у rows ниже).
    private var grid: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: gridSpacing,
                containerPadding: gridHorizontalPadding
            )
            // Ряды считаем явно (а не LazyVGrid с плоским ForEach): нужна ли
            // ряду высота под 2-строчное название — решение НА ВЕСЬ РЯД (см.
            // MangaCardView.rowNeedsTwoLines: название и жанр внутри каждой
            // карточки всегда вплотную друг к другу, а недостающая высота у
            // карточек с более коротким названием уходит пустым местом НИЖЕ
            // жанра), а для этого нужно видеть все 3 карточки ряда сразу.
            let rows = stride(from: 0, to: viewModel.results.count, by: gridColumnsCount).map { start in
                Array(viewModel.results[start..<min(start + gridColumnsCount, viewModel.results.count)])
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                        let rowNeedsTwoLines = rowItems.contains {
                            MangaCardView.titleLineCount($0.displayTitle, width: cardWidth) > 1
                        }

                        HStack(alignment: .top, spacing: gridSpacing) {
                            ForEach(rowItems) { item in
                                NavigationLink(value: item) {
                                    MangaCardView(item: item, width: cardWidth, rowNeedsTwoLines: rowNeedsTwoLines)
                                }
                                .buttonStyle(.plain)
                                .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, gridHorizontalPadding)
                .padding(.top, 12)
                // Запас снизу побольше обычного — гарантирует, что последний ряд
                // карточек не окажется под Фильтры/Сортировка внизу, даже если
                // safe-area-резерв через NavigationStack посчитается неточно.
                .padding(.bottom, 90)

                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
            // Прошлый вариант (GeometryReader-«датчик» + PreferenceKey) — самодельный
            // и ненадёжный способ отследить смещение скролла. onScrollGeometryChange —
            // штатный API именно под эту задачу, отдаёт contentOffset напрямую и не
            // зависит от таймингов рендера отдельного sensor-view.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newOffset in
                defer { lastScrollOffset = newOffset }
                // Пока идёт анимация схлопывания — игнорируем, иначе дребезг
                // (см. isHeaderAnimating выше).
                guard !isHeaderAnimating else { return }
                let delta = newOffset - lastScrollOffset
                if newOffset <= 0 {
                    // У самого верха (или в зоне лишнего оттягивания) шапка всегда развёрнута.
                    setHeaderCollapsed(false)
                } else if delta > 6 {
                    // Скроллим вниз (contentOffset растёт) — прячем шапку.
                    setHeaderCollapsed(true)
                } else if delta < -6 {
                    // Малейшее движение вверх — сразу возвращаем всё на место.
                    setHeaderCollapsed(false)
                }
            }
            .scrollIndicators(.hidden)
            // Пробовали .ignoresSafeArea(edges: .top) здесь как эксперимент
            // против раздутого отступа под .large — не помогло, контент
            // просто уехал под шапку/поиск (они остались на месте, т.к. это
            // системный navigationTitle/.searchable, не завязаны на верстку
            // ScrollView). Откачено.
            .overlay {
                if viewModel.isLoading && viewModel.results.isEmpty {
                    ProgressView().tint(Theme.accent)
                }
            }
        }
    }

    private func setHeaderCollapsed(_ value: Bool) {
        guard headerCollapsed != value else { return }
        isHeaderAnimating = true
        withAnimation(.easeInOut(duration: 0.22)) { headerCollapsed = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isHeaderAnimating = false }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message).foregroundStyle(Theme.textSecondary)
        } actions: {
            Button("Повторить") { viewModel.retry() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }
}

#Preview {
    MangaCatalogView().preferredColorScheme(.dark)
}
