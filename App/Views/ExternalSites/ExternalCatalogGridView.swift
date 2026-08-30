import SwiftUI

/// Запрос выдачи — тег/серия/... (см. ExternalTagBrowserView) ИЛИ свободный
/// текстовый поиск (см. ExternalSearchView/ExternalCombinedCatalogView,
/// capabilities.hasSearch) — один и тот же экран сетки обслуживает оба
/// случая, отличается только то, какой метод протокола дёргается за
/// очередной страницей ID (см. fetchPage).
enum ExternalCatalogQuery {
    case tag(namespace: ExternalTagNamespace, value: String)
    /// `excludedCategoryBits` — см. EHentaiCategory/EHentaiCategoryPicker;
    /// сайты без capabilities.hasCategoryFilter просто игнорируют его (см.
    /// ExternalSiteProvider.fetchIdsBySearch(excludedCategoryBits:)
    /// default-реализация), поэтому здесь один общий случай, не отдельный
    /// под каждый сайт. 0 — без ограничений (енум-кейсы не поддерживают
    /// значения параметров по умолчанию, поэтому вызывающая сторона всегда
    /// передаёт явно).
    case search(query: String, excludedCategoryBits: Int)
}

/// Один элемент СОВМЕСТНОЙ выдачи (см. ExternalCombinedCatalogView) — ID
/// тайтла сам по себе не уникален между сайтами (у hitomi и e-hentai свои,
/// не связанные пространства целых чисел), поэтому идентичность элемента
/// сетки — ВСЕГДА пара (сайт, id), не голый Int.
struct ExternalCatalogItem: Identifiable, Hashable {
    let site: ExternalSite
    let galleryId: Int
    var id: String { "\(site.rawValue)#\(galleryId)" }
}

/// Сетка тайтлов внешнего сайта (или НЕСКОЛЬКИХ сразу — см. `sites` и
/// ExternalCombinedCatalogView) по одному тегу/серии/персонажу/группе/
/// автору либо свободному запросу (см. план, Часть 6 + совместный каталог).
/// Список ID — постранично (см. fetchPage), карточки — лениво по мере
/// скролла через fetchGalleryDetail, тот же принцип "подгрузка по onAppear
/// последних элементов", что и в старом MangaCatalogView, но написан
/// заново, самостоятельно (см. план — минимально пересекаться со старым
/// кодом).
struct ExternalCatalogGridView: View {
    let sites: [ExternalSite]
    let query: ExternalCatalogQuery
    let title: String
    /// true — встроена ПРЯМО в экран поиска (см. ExternalSearchView/
    /// ExternalCombinedCatalogView, по прямой просьбе "тут же появляются
    /// тайтлы", без отдельного перехода) — без своего заголовка/фона,
    /// родительский экран уже даёт их. false (по умолчанию) — как раньше,
    /// самостоятельный экран, на который переходят (см. ExternalTagBrowserView).
    var embedded: Bool = false

    /// Доп. кнопка(и) родительского экрана в общей нижней стеклянной панели
    /// (см. controlsBar) — сейчас это «Фильтры» у ExternalSearchView/
    /// ExternalCombinedCatalogView (капсула категорий e-hentai). `AnyView`,
    /// не generic-параметр на весь struct — тип этой вью не должен
    /// протекать во все места, где создаётся ExternalCatalogGridView (была
    /// бы генерик-разводка ради одной необязательной кнопки).
    var leadingControls: AnyView?

    /// Обычный (не совместный) вызов — один сайт, самый частый случай
    /// (ExternalTagBrowserView/ExternalSearchView).
    init(site: ExternalSite, query: ExternalCatalogQuery, title: String, embedded: Bool = false, leadingControls: AnyView? = nil) {
        self.sites = [site]
        self.query = query
        self.title = title
        self.embedded = embedded
        self.leadingControls = leadingControls
    }

    /// Совместная выдача — сразу НЕСКОЛЬКО сайтов (см.
    /// ExternalCombinedCatalogView) — каждая страница мержится по всем
    /// переданным сайтам разом (см. loadNextBatch).
    init(sites: [ExternalSite], query: ExternalCatalogQuery, title: String, embedded: Bool = false, leadingControls: AnyView? = nil) {
        self.sites = sites
        self.query = query
        self.title = title
        self.embedded = embedded
        self.leadingControls = leadingControls
    }

    private static let pageSize = 25

    @State private var items: [ExternalCatalogItem] = []
    /// Курсор следующей страницы НА КАЖДЫЙ сайт — отсутствие ключа значит
    /// "ещё не спрашивали", nil-курсор при первом запросе (см. fetchPage).
    @State private var cursors: [ExternalSite: String] = [:]
    /// Сайты, у которых ещё МОЖЕТ быть следующая страница — как только сайт
    /// вернул nextCursor == nil (или упал ошибкой) он отсюда убирается,
    /// чтобы не долбить его бесконечно повторными подгрузками.
    @State private var pending: Set<ExternalSite> = []
    @State private var details: [String: ExternalGalleryDetail] = [:]
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var jumpPageText = ""
    /// НЕПРОЗРАЧНЫЙ ключ сортировки (см. ExternalSiteProvider.
    /// fetchIdsByTag(sortKey:), HitomiProvider.SortOption.rawValue) — nil =
    /// сортировка по умолчанию (по дате добавления). Только у сайтов с
    /// capabilities.hasSortOptions (сейчас только hitomi, см. showsSortMenu).
    @State private var sortKey: String?

    /// Число колонок — та же общая настройка Персонализации (2/3/4/Авто),
    /// что и у обычного каталога (см. MangaCatalogView/MangaCardView,
    /// CardsPerRow.swift) — общий тип, тот же @AppStorage-ключ, по прямой
    /// просьбе "по аналогии с работой фн персонализация".
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto
    private var gridColumns: Int { cardsPerRow.columns }

    private let gridSpacing: CGFloat = 12
    /// Бейдж с источником имеет смысл показывать ТОЛЬКО когда сайтов
    /// несколько — в обычном одно-сайтовом режиме и так понятно, откуда
    /// тайтл (см. ExternalTagBrowserView/ExternalSearchView, где sites — [x]).
    private var showsSourceBadge: Bool { sites.count > 1 }
    /// «Перейти на страницу» (см. ExternalSiteCapabilities.hasPageJump) —
    /// хотя бы один из sites должен это уметь, иначе строка ни на что не
    /// повлияет (см. jump(toPage:) — сайты без поддержки там просто
    /// пропускаются, начинают заново с первой страницы). По прямой просьбе
    /// — всегда СВЕРХУ, видимой строкой, не спрятана за кнопкой/алертом.
    private var showsPageJump: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasPageJump } }
    /// Сортировка (см. ExternalSiteCapabilities.hasSortOptions) — сейчас
    /// подтверждена живым HAR только у hitomi (см. HitomiProvider.
    /// SortOption), кнопка видна, если ХОТЯ БЫ один из sites её понимает —
    /// у e-hentai в совместной выдаче sortKey просто честно игнорируется
    /// (см. ExternalSiteProvider extension-дефолт).
    private var showsSortMenu: Bool { sites.contains { ExternalSiteRegistry.provider(for: $0).capabilities.hasSortOptions } }
    private var showsControlsBar: Bool { showsPageJump || showsSortMenu || leadingControls != nil }

    @FocusState private var isJumpFieldFocused: Bool

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .background(Theme.background.ignoresSafeArea())
            }
        }
        .task { await loadFirstPage() }
        .onChange(of: sortKey) { _, _ in resetAndReload() }
        // Панель снизу, стеклянными пилюлями — 1-в-1 MangaCatalogView.
        // controlsBar/controlLabel (по прямой просьбе 30.08 "кнопка
        // фильтры внизу... быстрый переход к странице тоже сделай кнопку
        // стеклянную внизу"), а не сверху обычными плашками, как было.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsControlsBar {
                controlsBar
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
        }
    }

    /// Смена сортировки — начинаем выдачу заново с первой страницы (тот же
    /// сброс, что и у jump(toPage:), просто без синтеза курсора страницы).
    private func resetAndReload() {
        items = []
        details = [:]
        cursors = [:]
        Task { await performInitialLoad() }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            leadingControls
            if showsPageJump {
                pageJumpButton
            }
            if showsSortMenu {
                sortMenuButton
            }
            Spacer(minLength: 0)
        }
    }

    /// Тот же стиль стеклянной пилюли, что и у MangaCatalogView.controlLabel
    /// (Фильтры/Сортировка внизу обычного каталога) — переиспользуют его и
    /// «Фильтры» родительского экрана (см. leadingControls), и «Стр.»/
    /// «Сортировка» здесь: единый вид всех кнопок нижней панели.
    private func controlPill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// «Стр.» — пилюля с полем ввода + стрелкой, лист снизу (см.
    /// jumpFieldSheet) вместо строки инлайн, чтобы поле ввода не торчало
    /// прямо в нижней панели рядом с остальными кнопками. Тап по пилюле
    /// открывает лист; клавиатура сворачивается кнопкой "Готово" в
    /// toolbar(.keyboard) самого листа (см. jumpFieldSheet) — по прямой
    /// просьбе "не забудь чтобы можно было свернуть клавиатуру".
    @State private var showJumpSheet = false

    private var pageJumpButton: some View {
        Button {
            showJumpSheet = true
        } label: {
            controlPill(icon: "arrow.right.to.line", text: "Стр.")
        }
        .sheet(isPresented: $showJumpSheet) {
            jumpFieldSheet
        }
    }

    private var jumpFieldSheet: some View {
        VStack(spacing: 16) {
            Text("Перейти на страницу")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                TextField("№", text: $jumpPageText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .focused($isJumpFieldFocused)
                    .padding(.horizontal, 6)
                    .frame(width: 64, height: 40)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    if let page = Int(jumpPageText), page > 0 {
                        jump(toPage: page)
                        showJumpSheet = false
                    }
                } label: {
                    Text("Перейти")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(Int(jumpPageText) == nil)
            }
        }
        .padding(20)
        .presentationDetents([.height(160)])
        .presentationDragIndicator(.visible)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { isJumpFieldFocused = true }
        // Клавиатура (numberPad) сама по себе кнопки "Готово" не даёт —
        // по прямой просьбе "не забудь чтобы можно было свернуть
        // клавиатуру". Тулбар вешается ЗДЕСЬ, на содержимом самого листа
        // (не на body ExternalCatalogGridView снаружи) — у .sheet своя
        // независимая иерархия, внешний toolbar(.keyboard) над её
        // клавиатурой не показался бы.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { isJumpFieldFocused = false }
            }
        }
    }

    /// Ключ сортировки — `String?` (nil = по умолчанию), а не сам enum,
    /// т.к. это ОБЩЕЕ поле для любого сайта (см. sortKey doc-comment выше);
    /// Picker внутри работает с HitomiProvider.SortOption через
    /// Binding(get:set:) — единственная сегодня реализация, см. showsSortMenu.
    private var sortSelection: Binding<HitomiProvider.SortOption> {
        Binding(
            get: { sortKey.flatMap(HitomiProvider.SortOption.init(rawValue:)) ?? .dateAdded },
            set: { newValue in sortKey = newValue == .dateAdded ? nil : newValue.rawValue }
        )
    }

    private var sortMenuButton: some View {
        Menu {
            Picker("Сортировка", selection: sortSelection) {
                ForEach(HitomiProvider.SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            controlPill(icon: "arrow.up.arrow.down", text: sortSelection.wrappedValue.label)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            // Скелетон-сетка вместо голого спиннера — 1-в-1
            // MangaCatalogView.skeletonGrid (по прямой просьбе "скелетоны в
            // разделе каталог"), та же ширина карточки, что и у настоящей
            // сетки (см. grid ниже).
            skeletonGrid
        } else if let errorMessage, items.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await loadFirstPage() } }, fillScreen: true)
        } else if items.isEmpty {
            StateView(icon: "square.grid.2x2", title: "Тайтлов не найдено", fillScreen: true)
        } else {
            grid
        }
    }

    /// Число ячеек-заглушек не привязано к реальным данным (их ещё нет) —
    /// просто с запасом на экран при любом gridColumns (2/3/4).
    private var skeletonGrid: some View {
        GeometryReader { proxy in
            let spacing = gridSpacing
            let totalSpacing = spacing * CGFloat(gridColumns - 1) + 24
            let cardWidth = ((proxy.size.width - totalSpacing) / CGFloat(gridColumns)).rounded(.down)
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: gridColumns)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(0..<12, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBox()
                                .frame(width: cardWidth, height: (cardWidth * 3 / 2).rounded())
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            SkeletonBar(width: cardWidth * 0.85, height: 12)
                            SkeletonBar(width: cardWidth * 0.5, height: 10)
                        }
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let spacing = gridSpacing
            let totalSpacing = spacing * CGFloat(gridColumns - 1) + 24
            let cardWidth = ((proxy.size.width - totalSpacing) / CGFloat(gridColumns)).rounded(.down)
            let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: gridColumns)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink {
                            ExternalGalleryDetailView(site: item.site, id: item.galleryId, preloaded: details[item.id])
                        } label: {
                            card(item: item, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .onAppear { onCardAppear(item) }
                    }
                }
                .padding(12)

                if isLoadingMore {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func card(item: ExternalCatalogItem, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let detail = details[item.id], let cover = detail.coverURL {
                        ExternalImage(url: cover) { SkeletonBox() }
                            .scaledToFill()
                    } else {
                        SkeletonBox()
                    }
                }
                .frame(width: width, height: (width * 3 / 2).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipped()

                if showsSourceBadge {
                    Text(item.site.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }

            Text(details[item.id]?.title ?? "…")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .topLeading)

            // Тип тайтла — третьей строкой под названием, тем же приёмом,
            // что и в обычном каталоге (MangaCardView: название, сразу под
            // ним тип секондари-цветом), по прямой просьбе (30.08). НА
            // АНГЛИЙСКОМ, как есть на самом сайте (hitomi отдаёт "manga"/
            // "doujinshi"/"misc"/... строчными, e-hentai — "Manga"/... с
            // большой) — не переводим и не меняем регистр.
            if let type = details[item.id]?.type, !type.isEmpty {
                Text(type)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .top)
    }

    private func onCardAppear(_ item: ExternalCatalogItem) {
        if details[item.id] == nil {
            Task { await loadDetail(item) }
        }
        guard let index = items.firstIndex(of: item), index >= items.count - 6 else { return }
        Task { await loadMoreIfNeeded() }
    }

    private func loadDetail(_ item: ExternalCatalogItem) async {
        let provider = ExternalSiteRegistry.provider(for: item.site)
        guard let detail = try? await provider.fetchGalleryDetail(id: item.galleryId) else { return }
        details[item.id] = detail
    }

    /// Один и тот же метод для любого сайта — у него нет своего "не умеет
    /// такое" исключения: сайт без hasSearch (например hitomi) для запроса
    /// `.search` просто трактует введённый текст КАК ТЕГ (fetchIdsByTag —
    /// именно так на hitomi ищется что-то по имени: неизвестное имя-тег
    /// просто вернёт пустой список/404, это нормальный ответ, не ошибка,
    /// см. HitomiProvider.fetchIdsByTag). `static`, без захвата `self` —
    /// вызывается из параллельных задач в loadNextBatch (см. ниже), лишний
    /// захват целого View-структа в @Sendable-замыкании ни к чему.
    private static func fetchPage(site: ExternalSite, cursor: String?, query: ExternalCatalogQuery, sortKey: String?) async throws -> (ids: [Int], nextCursor: String?) {
        let provider = ExternalSiteRegistry.provider(for: site)
        switch query {
        case let .tag(namespace, value):
            return try await provider.fetchIdsByTag(namespace: namespace, value: value, sortKey: sortKey, cursor: cursor, limit: pageSize)
        case let .search(text, excludedCategoryBits):
            if provider.capabilities.hasSearch {
                return try await provider.fetchIdsBySearch(query: text, excludedCategoryBits: excludedCategoryBits, sortKey: sortKey, cursor: cursor, limit: pageSize)
            } else {
                return try await provider.fetchIdsByTag(namespace: .tag, value: text, sortKey: sortKey, cursor: cursor, limit: pageSize)
            }
        }
    }

    private func loadFirstPage() async {
        guard items.isEmpty else { return }
        cursors = [:]
        await performInitialLoad()
    }

    /// Сбрасывает выдачу и запускает её заново, начиная с курсора, который
    /// каждый провайдер (см. cursorForPage) сам синтезирует под "страницу
    /// N" — у сайтов без capabilities.hasPageJump курсор просто не
    /// задаётся, они честно начинают заново с первой страницы (не ошибка,
    /// см. showsPageJump — кнопка видна, если ХОТЯ БЫ один сайт умеет).
    private func jump(toPage page: Int) {
        items = []
        details = [:]
        cursors = sites.reduce(into: [ExternalSite: String]()) { result, site in
            if let cursor = ExternalSiteRegistry.provider(for: site).cursorForPage(page, limit: Self.pageSize) {
                result[site] = cursor
            }
        }
        Task { await performInitialLoad() }
    }

    private func performInitialLoad() async {
        isLoading = true
        errorMessage = nil
        pending = Set(sites)
        // `anySucceeded` — отличает РЕАЛЬНЫЙ сбой сети (ни один сайт не
        // ответил успешно) от честного "0 совпадений" (запрос прошёл,
        // просто пусто — например по hitomi ищут точное имя тега, которого
        // нет). Раньше здесь смотрели только на `items.isEmpty &&
        // pending.isEmpty` — это условие ОДИНАКОВО истинно в обоих
        // случаях (успешный пустой ответ тоже убирает сайт из `pending`,
        // см. loadNextBatch), из-за чего любой пустой поиск на hitomi тут
        // же показывал "Проверьте соединение и попробуйте ещё раз" —
        // выглядит как сетевая ошибка с намёком нажать "Обновить", хотя
        // сеть отработала нормально, просто совпадений нет (жалоба
        // "фаллбек слишком быстро предлагает нажать обновить").
        let anySucceeded = await loadNextBatch()
        if items.isEmpty && pending.isEmpty && !anySucceeded {
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
        isLoading = false
    }

    private func loadMoreIfNeeded() async {
        guard !isLoadingMore, !pending.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadNextBatch()
    }

    /// Опрашивает ПАРАЛЛЕЛЬНО все сайты из `pending` (первая страница — это
    /// просто "все сайты из `sites`" на старте), мержит результат ЧЕРЕДУЯ по
    /// сайтам (не "сначала все с одного, потом все с другого" — иначе
    /// совместная сетка выглядела бы как склейка двух отдельных, а не
    /// единая выдача). Возвращает, ответил ли хоть один сайт УСПЕШНО (даже
    /// пустым списком) — см. performInitialLoad, где это отличает реальный
    /// сбой сети от честного "0 совпадений". `@discardableResult` —
    /// loadMoreIfNeeded этот флаг не нужен (там об ошибке уже сообщать
    /// нечего, экран и так что-то показывает).
    @discardableResult
    private func loadNextBatch() async -> Bool {
        let sitesToQuery = Array(pending)
        guard !sitesToQuery.isEmpty else { return true }
        let currentQuery = query
        let currentSortKey = sortKey
        let cursorsSnapshot = cursors

        let results = await withTaskGroup(of: (ExternalSite, [Int], String?, Bool).self) { group in
            for site in sitesToQuery {
                let cursor = cursorsSnapshot[site]
                group.addTask {
                    do {
                        let page = try await Self.fetchPage(site: site, cursor: cursor, query: currentQuery, sortKey: currentSortKey)
                        return (site, page.ids, page.nextCursor, true)
                    } catch {
                        return (site, [], nil, false)
                    }
                }
            }
            var collected: [(ExternalSite, [Int], String?, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var idsBySite: [ExternalSite: [Int]] = [:]
        var anySucceeded = false
        for (site, ids, nextCursor, succeeded) in results {
            if succeeded { anySucceeded = true }
            if succeeded, let nextCursor {
                cursors[site] = nextCursor
            } else {
                // Либо сайт честно сказал "дальше ничего нет", либо запрос
                // упал — в обоих случаях не спрашиваем этот сайт снова, но
                // то, что он УЖЕ вернул в этом батче (если succeeded),
                // всё равно попадает в выдачу.
                pending.remove(site)
            }
            idsBySite[site] = ids
        }

        let maxCount = idsBySite.values.map(\.count).max() ?? 0
        var merged: [ExternalCatalogItem] = []
        for index in 0..<maxCount {
            for site in sites {
                guard let ids = idsBySite[site], index < ids.count else { continue }
                merged.append(ExternalCatalogItem(site: site, galleryId: ids[index]))
            }
        }

        let existing = Set(items.map(\.id))
        items.append(contentsOf: merged.filter { !existing.contains($0.id) })
        return anySucceeded
    }
}

#Preview {
    NavigationStack {
        ExternalCatalogGridView(site: .hitomi, query: .tag(namespace: .tag, value: "full color"), title: "full color")
    }
    .preferredColorScheme(.dark)
}
