import SwiftUI

/// Вкладка «Закладки»: сверху заголовок/поиск, снизу горизонтальная полоска
/// подкатегорий, между ними список тайтлов.
struct BookmarksView: View {

    @ObservedObject private var store = BookmarksStore.shared
    @State private var selectedFolderId: String? = nil   // nil = «Все»
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    // Схлопывание шапки при скролле — тот же механизм, что в Каталоге:
    // вниз — заголовок "Закладки" прячется, поиск занимает его место;
    // вверх (хоть чуть-чуть) — возвращается.
    @State private var headerCollapsed = false
    @State private var lastScrollOffset: CGFloat = 0
    // Пока идёт анимация схлопывания/разворота, само изменение высоты шапки
    // (заголовок исчезает/появляется) на мгновение сдвигает contentOffset
    // ScrollView — это НЕ реальный скролл пользователя, но наш обработчик
    // видел его как "скрольнули вверх" и тут же откатывал схлопывание назад,
    // из-за чего заголовок дёргался ("трясло") вместо того, чтобы просто
    // спокойно спрятаться. Пока isHeaderAnimating — игнорируем входящие
    // события скролла целиком.
    @State private var isHeaderAnimating = false

    /// Тайтл, который сейчас редактируется через долгое нажатие на строку
    /// (см. row() ниже, .contextMenu) — открывает тот же AddToFolderSheet,
    /// что и на странице тайтла (сменить папку/убрать из закладок).
    @State private var editingBookmark: BookmarkedTitle?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                titlesList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        header
                    }
                    .overlay {
                        if searchFocused {
                            Color.black.opacity(0.0001)
                                .contentShape(Rectangle())
                                .onTapGesture { searchFocused = false }
                        }
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: BookmarkedTitle.self) { bm in
                MangaDetailView(slug: bm.slug, fallbackTitle: bm.title,
                                coverURL: bm.coverURL.flatMap(URL.init(string:)))
            }
            .alert("Новая папка", isPresented: $showNewFolder) {
                TextField("Название папки", text: $newFolderName)
                Button("Отмена", role: .cancel) { newFolderName = "" }
                Button("Создать") {
                    if let folder = store.createFolder(name: newFolderName) {
                        selectedFolderId = folder.id
                    }
                    newFolderName = ""
                }
            } message: {
                Text("Папка появится здесь и в списке «Добавить в».")
            }
            // Открывается долгим нажатием на строку тайтла (.contextMenu
            // в titlesList) — тот же лист выбора папки, что и на странице
            // тайтла, с моделью "отложенный выбор + Применить".
            .sheet(item: $editingBookmark) { bm in
                AddToFolderSheet(slug: bm.slug, title: bm.title, coverURL: bm.coverURL, rating: bm.rating)
                    .preferredColorScheme(.dark)
            }
        }
        // Полоска подкатегорий — снизу, над главной панелью. safeAreaInset
        // здесь применён СНАРУЖИ NavigationStack (не внутри него) — вложенный
        // внутрь NavigationStack safeAreaInset не всегда корректно складывается
        // с ВНЕШНИМ инсетом BottomBar из RootView.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            categoryMenu
                // 20 — та же ширина/выравнивание, что и у главной панели
                // (BottomBar тоже использует padding.horizontal 20), чтобы
                // полоска была строго той же ширины и по тем же краям.
                .padding(.horizontal, 20)
                // Этот .safeAreaInset вложен ВНУТРИ "screen" (BookmarksView),
                // а RootView применяет свой .safeAreaInset(bottom){Color.clear
                // height: 84} СНАРУЖИ, поверх этого — то есть зона под
                // categoryMenu заканчивается РОВНО там, где начинается зона
                // главной панели. Поэтому это число — и есть ТОЧНЫЙ зазор между
                // низом плашки категорий и верхом главной панели: 20 = 20.
                .padding(.bottom, 20)
        }
        .tint(Theme.accent)
        // Подтягивает реальные закладки аккаунта (5 стандартных папок) при
        // открытии вкладки, если есть сессия — см. BookmarksStore.syncFromServer.
        // Без сессии ничего не делает (просто локальный список, как раньше).
        .task { await store.syncFromServer() }
    }

    // MARK: Шапка (без общей подложки — просто текст сверху)

    private var header: some View {
        VStack(spacing: 10) {
            if !headerCollapsed {
                Text("Закладки")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
            searchField
        }
        // 20 — то же выравнивание/ширина, что у полоски подкатегорий внизу и
        // у главной панели (см. комментарий там).
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            // Плейсхолдер отражает текущую выбранную подкатегорию — «Поиск в
            // «Все»»/«Поиск в «Читаю»» и т.д.
            TextField("", text: $query,
                      prompt: Text("Поиск в «\(selectedName)»").foregroundColor(Theme.textSecondary))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var currentTitles: [BookmarkedTitle] {
        let base = store.titles(in: selectedFolderId)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var selectedName: String {
        guard let id = selectedFolderId else { return "Все" }
        return store.allFolders.first { $0.id == id }?.name ?? "Все"
    }

    // MARK: Полоска подкатегорий (горизонтальный скролл, вместо аккордеона)

    // Переделано с "тап → разворачивается список" на постоянно видимую
    // горизонтальную полоску чипов — все подкатегории видны сразу, если не
    // влезают — скроллятся вбок. Активная горит акцентным (оранжевым) фоном.
    private var categoryMenu: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryChip(title: "Все", id: nil)
                ForEach(store.allFolders) { folder in
                    categoryChip(title: folder.name, id: folder.id)
                }
                addFolderChip
            }
        }
        .scrollIndicators(.hidden)
    }

    private func categoryChip(title: String, id: String?) -> some View {
        let active = selectedFolderId == id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selectedFolderId = id
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(active ? .semibold : .regular))
                Text("\(store.titlesCount(in: id))").font(.caption2.weight(.bold))
            }
            .foregroundStyle(active ? Theme.background : Theme.textPrimary)
            .padding(.horizontal, 14)
            // Высота выровнена по Theme.pillControlHeight — строго та же
            // высота, что у Фильтры/Сортировка в Каталоге.
            .frame(minHeight: Theme.pillControlHeight)
            .contentShape(Capsule())
            // .interactive() вернул именно здесь (в отличие от триггера
            // старого аккордеона, который чинили раньше) — это тот же
            // проверенный рецепт, что уже используется и работает в
            // MangaDetailView.tabButton: .regular.tint(...).interactive() для
            // активного состояния. Без .interactive() тонированное стекло
            // выглядит слишком плоским/сплошным — самому эффекту стекла
            // (блик, лёгкая прозрачность) как раз и нужен .interactive(),
            // просто так его и рисует Liquid Glass. Здесь это безопасно:
            // чип маленький и однородный (не широкая пилюля с разнородным
            // содержимым по краям, как было в старом триггере) — тот баг был
            // именно про это, а не про .interactive() как таковой.
            .glassEffect(active ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var addFolderChip: some View {
        Button {
            newFolderName = ""
            showNewFolder = true
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: Theme.pillControlHeight)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Список тайтлов

    @ViewBuilder
    private var titlesList: some View {
        if currentTitles.isEmpty {
            if store.isSyncing {
                // Идёт первая подтяжка закладок аккаунта — иначе пустой экран
                // на секунду выглядит как баг (будто ничего не подтянулось).
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Пусто",
                    systemImage: "bookmark",
                    description: Text("Добавляйте тайтлы через кнопку «Добавить в» на странице тайтла.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(currentTitles) { bm in
                        NavigationLink(value: bm) { row(bm) }
                            .buttonStyle(.plain)
                            // Зажать палец на тайтле — изменить папку/убрать
                            // из закладок, не открывая страницу тайтла.
                            .contextMenu {
                                Button {
                                    editingBookmark = bm
                                } label: {
                                    Label("Изменить папку", systemImage: "folder")
                                }
                                Button(role: .destructive) {
                                    store.remove(slug: bm.slug)
                                } label: {
                                    Label("Убрать из закладок", systemImage: "bookmark.slash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                // Запас снизу побольше обычного — гарантирует, что последний
                // тайтл не окажется под полоской подкатегорий, даже если
                // safe-area-резерв через NavigationStack посчитается неточно.
                // 90→120 — увеличили ещё немного.
                .padding(.bottom, 120)
            }
            // Тот же механизм схлопывания шапки, что в Каталоге, плюс защита
            // от дребезга — см. isHeaderAnimating выше.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newOffset in
                defer { lastScrollOffset = newOffset }
                guard !isHeaderAnimating else { return }
                let delta = newOffset - lastScrollOffset
                if newOffset <= 0 {
                    setHeaderCollapsed(false)
                } else if delta > 6 {
                    setHeaderCollapsed(true)
                } else if delta < -6 {
                    setHeaderCollapsed(false)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func setHeaderCollapsed(_ value: Bool) {
        guard headerCollapsed != value else { return }
        isHeaderAnimating = true
        withAnimation(.easeInOut(duration: 0.22)) { headerCollapsed = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isHeaderAnimating = false }
    }

    private func row(_ bm: BookmarkedTitle) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: bm.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            // 1.3x увеличенная обложка (было 60x84).
            .frame(width: 78, height: 109)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Единый бэйдж оценки (см. RatingChip) — тот же стиль/цвет, что и
            // в каталоге/карточке тайтла, теперь и в закладках.
            .overlay(alignment: .topTrailing) { RatingChip(rating: bm.rating) }

            VStack(alignment: .leading, spacing: 6) {
                Text(bm.title)
                    // Обложка стала крупнее — чуть увеличили и текст названия
                    // (было .subheadline/15pt), оставили 2 строки с обрезкой.
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let p = store.readingProgress(forSlug: bm.slug) {
                    // totalChapters может быть 0 — если прогресс подтянут из
                    // реальной истории аккаунта (см. BookmarksStore.
                    // syncHistoryFromServer), а не из живого списка глав,
                    // открытого в этом приложении. "N/0" выглядело бы криво —
                    // тогда просто показываем номер главы без знаменателя.
                    Text(p.totalChapters > 0
                         ? "Продолжить \(p.lastChapterNumber)/\(p.totalChapters)"
                         : "Продолжить: Том \(p.lastChapterVolume), Глава \(p.lastChapterNumber)")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Открыть").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    BookmarksView().preferredColorScheme(.dark)
}
