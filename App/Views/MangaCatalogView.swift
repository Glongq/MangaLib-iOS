import SwiftUI

/// Экран «Каталог»: строка поиска, кнопки Фильтры/Сортировка и сетка карточек.
struct MangaCatalogView: View {

    @StateObject private var viewModel = CatalogViewModel()
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    // Схлопывание шапки при скролле: вниз — заголовок и Фильтры/Сортировка
    // прячутся, поиск занимает их место; вверх (хоть чуть-чуть) — всё возвращается.
    @State private var headerCollapsed = false
    @State private var lastScrollOffset: CGFloat = 0
    // Пока идёт анимация схлопывания, само изменение высоты шапки на мгновение
    // сдвигает contentOffset ScrollView — не реальный скролл, но без этой
    // защиты обработчик видел его как "скрollнули вверх" и тут же откатывал
    // назад, из-за чего заголовок дёргался. См. тот же фикс в BookmarksView.
    @State private var isHeaderAnimating = false

    // Сетка: ровно 3 колонки одинаковой ширины — строгое выравнивание карточек.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                // Никакой общей подложки под шапкой — заголовок голый текст,
                // а у поиска остаётся ЕГО СОБСТВЕННЫЙ материал (как был),
                // просто без общей панели позади всех.
                content
                    .safeAreaInset(edge: .top, spacing: 0) {
                        header
                    }
                    .overlay {
                        // Пока активна клавиатура поиска, первый тап по чему угодно
                        // в сетке (например по манге) должен ТОЛЬКО закрыть клавиатуру,
                        // а не сразу переходить в тайтл. Прозрачный, но кликабельный
                        // слой поверх сетки перехватывает этот первый тап; как только
                        // фокус снят, слой исчезает и тапы снова доходят до карточек.
                        if searchFocused {
                            Color.black.opacity(0.0001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    searchFocused = false
                                }
                        }
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
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
        }
        // Фильтры/Сортировка теперь ВНИЗУ, над главной панелью — safeAreaInset
        // здесь применён СНАРУЖИ NavigationStack (не внутри него), иначе
        // повторяется тот же баг, что был у подкатегорий в Закладках: вложенный
        // safeAreaInset внутри NavigationStack не всегда корректно
        // складывается с ВНЕШНИМ инсетом BottomBar из RootView (NavigationStack
        // может не пробрасывать чужой safe-area context внутрь себя), из-за
        // чего контент визуально уезжал ПОД панель независимо от паддингов.
        // Применяя инсет СНАРУЖИ (на этом же уровне, что и NavigationStack),
        // он гарантированно складывается с внешним инсетом BottomBar как сосед,
        // а не как вложенный элемент внутри чужого safe-area контекста.
        // Раньше по отдельной просьбе были ВСЕГДА видимыми, независимо от
        // скролла — теперь по новой просьбе прячутся при скролле вниз, как и
        // заголовок "Каталог" (тот же headerCollapsed, тот же withAnimation
        // из setHeaderCollapsed — значит анимируются синхронно с шапкой).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !headerCollapsed {
                controlsBar
                    // 16→20 — выравнено по главной панели (BottomBar тоже
                    // использует padding.horizontal 20), та же ширина и края.
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    // Тот же принцип, что и в Закладках (см. BookmarksView.swift):
                    // этот .safeAreaInset вложен внутри "screen", а RootView
                    // резервирует зону под главную панель СНАРУЖИ — значит это
                    // число и есть точный зазор между Фильтры/Сортировка и верхом
                    // главной панели.
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .tint(Theme.accent)
        .onAppear { viewModel.loadInitialIfNeeded() }
    }

    // MARK: Шапка (без общей подложки)

    private var header: some View {
        VStack(spacing: 10) {
            if !headerCollapsed {
                Text("Каталог")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }

            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("", text: $viewModel.query,
                      prompt: Text("Поиск по названию").foregroundColor(Theme.textSecondary))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Собственное стекло поля — не трогаю, как просили.
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: Фильтры / Сортировка

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                showFilters = true
            } label: {
                controlLabel(icon: "slider.horizontal.3", text: "Фильтры", badge: viewModel.filter.activeCount)
            }

            Menu {
                Picker("Сортировка", selection: $viewModel.sort) {
                    ForEach(SortOption.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
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

    // ИСПРАВЛЕНО (регрессия): пробовал считать ширину карточки вручную через
    // GeometryReader и передавать явным числом в каждую MangaCardView —
    // из-за расхождения этого вручную вычисленного числа с тем, что
    // LazyVGrid САМА даёт .flexible()-колонке, карточки переставали
    // совпадать со своим слотом сетки ("поплывшие" обложки). Вернул простую,
    // проверенную версию: карточки сами берут ширину из .flexible()-колонки
    // (через .aspectRatio(fit).frame(maxWidth:.infinity) внутри
    // MangaCardView) — никакой ручной геометрии на уровне каталога.
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(viewModel.results) { item in
                    NavigationLink(value: item) {
                        MangaCardView(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(.horizontal, 12)
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
        .overlay {
            if viewModel.isLoading && viewModel.results.isEmpty {
                ProgressView().tint(Theme.accent)
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
            Button("Повторить") { viewModel.loadInitialIfNeeded() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }
}

#Preview {
    MangaCatalogView().preferredColorScheme(.dark)
}
