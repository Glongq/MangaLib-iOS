import SwiftUI
import UIKit

/// Вкладка «Закладки»: сверху заголовок/поиск + шестерёнка (Вид/Сортировка,
/// см. ViewSortSheet) и карандаш (порядок списков, см. FolderOrderSheet),
/// снизу горизонтальная полоска подкатегорий, между ними список/плитка тайтлов.
/// Плитка (gridContent/bookmarkGridCell) — число колонок из Персонализации
/// (см. CardsPerRow, 2/3/4/Авто), карточка та же архитектура точного
/// расчёта ширины/построчной высоты текста, что и в Каталоге (см.
/// MangaCatalogView.grid/MangaCardView) — плюс, по прямой просьбе, три чипа
/// поверх обложки: номер текущей главы (слева сверху), твоя личная оценка
/// (справа сверху) и "..." — быстрая смена папки (справа снизу).
struct BookmarksView: View {

    @ObservedObject private var store = BookmarksStore.shared
    @ObservedObject private var catalogNav = CatalogNavigator.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var selectedFolderId: String? = nil   // nil = «Все»
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var query = ""

    /// Тайтл, который сейчас редактируется через долгое нажатие на строку
    /// (см. row() ниже, .contextMenu) — открывает тот же AddToFolderSheet,
    /// что и на странице тайтла (сменить папку/убрать из закладок).
    @State private var editingBookmark: BookmarkedTitle?

    /// Щит редактирования порядка списков (иконка карандаша в шапке).
    @State private var showFolderOrderSheet = false
    /// Щит "Вид"/"Сортировка" (иконка шестерёнки в шапке).
    @State private var showViewSortSheet = false

    /// Папка, которую сейчас переименовывают/меняют цвет — открывается
    /// долгим нажатием на чип папки (см. categoryMenu/folderContextMenu),
    /// только для кастомных папок (см. EditFolderSheet).
    @State private var editingFolder: BookmarkFolder?
    /// Папка, которую сейчас удаляют — отдельный щит (не просто alert),
    /// потому что нужен выбор "перенести тайтлы в другую папку или нет"
    /// (см. DeleteFolderSheet) — ровно то же самое, что предлагает реальный
    /// сайт при удалении непустой папки.
    @State private var deletingFolder: BookmarkFolder?

    /// Мультивыбор тайтлов ("Выбрать" в шапке) — ПОДТВЕРЖДЕНО перехватом:
    /// `PUT/DELETE /bookmarks/bulk` (см. BookmarksStore.bulkMove/bulkDelete).
    /// Выбор — ТОЛЬКО в пределах текущей открытой папки (selectedFolderId) —
    /// по прямой просьбе, повторяет замеченное поведение реального сайта
    /// (переключение папки сбрасывает выбор — см. .onChange(of:
    /// selectedFolderId) ниже).
    @State private var isSelecting = false
    @State private var selectedSlugs: Set<String> = []
    @State private var showBulkMoveSheet = false
    @State private var showBulkDeleteConfirm = false
    @State private var isBulkProcessing = false

    /// Список/плитка — см. ViewSortSheet. Сохраняется между запусками.
    @AppStorage("bookmarks_view_mode") private var viewMode: BookmarksViewMode = .list
    /// Поле сортировки — см. ViewSortSheet.
    @AppStorage("bookmarks_sort_option") private var sortOption: BookmarksSortOption = .dateAdded
    /// Направление — реально влияет на сортировку только у полей-дат
    /// (у сортировки по названию направление уже "зашито" в сам вариант,
    /// А-Я/Я-А), но карточка выбора в ViewSortSheet видна всегда.
    @AppStorage("bookmarks_sort_direction") private var sortDirection: BookmarksSortDirection = .newestFirst
    /// Число колонок в режиме "Плитка" — из Персонализации (см. CardsPerRow,
    /// тот же ключ, что читает MangaCatalogView.gridColumnsCount).
    @AppStorage("personalization_cards_per_row") private var cardsPerRow: CardsPerRow = .auto

    /// Применить папку, запрошенную извне (профиль «Списки тайтлов» → «Читаю»).
    private func applyPendingFolder() {
        guard let folder = catalogNav.pendingBookmarksFolder else { return }
        catalogNav.pendingBookmarksFolder = nil
        selectedFolderId = folder
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                titlesList
            }
            // Потянуть вниз — реальная пересинхронизация закладок с
            // сервера (GET /bookmarks, тот же store.syncFromServer, что и
            // при открытии вкладки), без сессии — no-op. Тот же принцип,
            // что и в Читают/Уведомлениях/Каталоге.
            .refreshable { await store.syncFromServer() }
            // Родной системный поиск (сам выезжает сверху, свой Cancel, своя
            // анимация — высоту менять нельзя, это контролирует iOS) +
            // .large — эталон App Store (см. тот же приём в MangaCatalogView):
            // крупный заголовок без фона в покое, системный блюр проявляется
            // при первом скролле, заголовок схлопывается в маленький.
            // Раньше здесь был самодельный всегда видимый TextField в
            // стеклянной капсуле со своим схлопыванием заголовка.
            .navigationTitle("Закладки")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Поиск в «\(selectedName)»")
            // Шестерёнка (Вид/Сортировка) + карандаш (порядок списков) — в
            // ОДНОЙ ToolbarItemGroup: систему сама объединяет несколько
            // элементов группы в один Liquid-Glass pill (см. WWDC25 Liquid
            // Glass toolbars) — БЕЗ ручного .glassEffect. Предыдущая попытка
            // (свой HStack + .glassEffect в одном ToolbarItem) давала
            // задвоение: системный toolbar и так добавляет свой glass-фон
            // вокруг содержимого ToolbarItem, поверх которого наш ручной
            // .glassEffect накладывался вторым слоем ("призрачный" pill на
            // скриншоте).
            .toolbar {
                // Порядок и иконки — 1-в-1 с реальным сайтом (по прямой
                // просьбе): список-с-галочками (мультивыбор) → карандаш
                // (порядок списков) → шестерёнка (Вид/Сортировка).
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Мультивыбор — не показываем, пока список пуст, нет
                    // смысла. Активен — та же иконка, тонирована акцентом
                    // (тап всегда переключает вкл/выкл).
                    if !currentTitles.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting.toggle()
                                selectedSlugs.removeAll()
                            }
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .tint(isSelecting ? Theme.accent : nil)
                    }
                    if !isSelecting {
                        Button { showFolderOrderSheet = true } label: {
                            Image(systemName: "pencil")
                        }
                        Button { showViewSortSheet = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .onAppear { applyPendingFolder() }
            .onChange(of: catalogNav.openBookmarksRequest) { _, _ in applyPendingFolder() }
            // Смена открытой папки сбрасывает выбор — повторяет замеченное
            // поведение реального сайта (см. isSelecting выше).
            .onChange(of: selectedFolderId) { _, _ in
                selectedSlugs.removeAll()
                refreshRemoteOrder()
            }
            // Открытая папка могла реально исчезнуть (удалена на сайте/
            // другом устройстве, подтягивается через store.syncFoldersFromServer
            // при потянуть-обновить) — без этого экран молча показывал бы
            // пустой список без активного чипа и без объяснения.
            .onChange(of: store.folders) { _, _ in
                if let id = selectedFolderId, !store.allFolders.contains(where: { $0.id == id }) {
                    selectedFolderId = nil
                }
            }
            // Реальный порядок с сервера (см. currentTitles/
            // refreshRemoteOrder) — перезапрашивается при смене поля/
            // направления сортировки, папки (см. выше) и при первом
            // открытии экрана.
            .onChange(of: sortOption) { _, _ in refreshRemoteOrder() }
            .onChange(of: sortDirection) { _, _ in refreshRemoteOrder() }
            .task { refreshRemoteOrder() }
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
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            .sheet(isPresented: $showFolderOrderSheet) {
                FolderOrderSheet(store: store)
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            .sheet(isPresented: $showViewSortSheet) {
                ViewSortSheet(viewMode: $viewMode, sortOption: $sortOption, sortDirection: $sortDirection)
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            // Долгое нажатие на чип кастомной папки → переименовать/сменить
            // цвет (см. folderContextMenu) — ПОДТВЕРЖДЕНО перехватом `PUT
            // /bookmarks/folder/{id}` (см. EditFolderSheet).
            .sheet(item: $editingFolder) { folder in
                EditFolderSheet(store: store, folder: folder)
                    .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            // Долгое нажатие → "Удалить папку" (см. folderContextMenu) —
            // ПОДТВЕРЖДЕНО перехватом `DELETE /bookmarks/folder/{id}` (см.
            // DeleteFolderSheet).
            .sheet(item: $deletingFolder) { folder in
                DeleteFolderSheet(store: store, folder: folder) {
                    if selectedFolderId == folder.id { selectedFolderId = nil }
                }
                .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            // "Переместить" на панели мультивыбора (см. selectionBar) —
            // выбор папки назначения, тот же PUT /bookmarks/bulk (см.
            // BookmarksStore.bulkMove).
            .sheet(isPresented: $showBulkMoveSheet) {
                BulkMoveFolderSheet(store: store, excludingFolderId: selectedFolderId) { targetId in
                    bulkMove(to: targetId)
                }
                .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
            }
            .alert("Удалить \(selectedSlugs.count) \(pluralizedTitlesWord(selectedSlugs.count)) из закладок?", isPresented: $showBulkDeleteConfirm) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) { bulkDelete() }
            } message: {
                Text("Действие необратимо.")
            }
            // Полоска подкатегорий — снизу, над главной панелью. ВНУТРИ
            // NavigationStack (на корневом контенте), а не снаружи него: раньше
            // висела снаружи, чтобы обойти баг совместного расчёта с ВНЕШНИМ
            // инсетом самодельного BottomBar из старого RootView — но RootView
            // стал настоящим системным TabView, та причина отпала. А снаружи
            // NavigationStack полоска оставалась на экране ПОВЕРХ любого пуша
            // (карточки тайтла и т.д.), т.к. технически была соседом стека, а
            // не частью его корневого экрана — отсюда баг "подкатегории не
            // пропадают на карточке тайтла".
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Group {
                    if isSelecting {
                        selectionBar
                    } else {
                        categoryMenu
                    }
                }
                // 20 — та же ширина/выравнивание, что и у главной панели.
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .transition(.blurFade)
            }
        }
        .tint(Theme.accent)
        // Подтягивает реальные закладки аккаунта (5 стандартных папок) при
        // открытии вкладки, если есть сессия — см. BookmarksStore.syncFromServer.
        // Без сессии ничего не делает (просто локальный список, как раньше).
        .task { await store.syncFromServer() }
    }

    private var currentTitles: [BookmarkedTitle] {
        let base = store.titles(in: selectedFolderId)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty ? base : base.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        // Реальный порядок с сервера, если уже пришёл (см.
        // store.remoteOrderedSlugs/refreshRemoteOrder) — гарантированно
        // совпадает с сайтом 1-в-1, в отличие от клиентской sorted(_:)
        // ниже, которая лишь приближение (использовалось как fallback на
        // время загрузки/при сетевой ошибке).
        if let remoteOrder = store.remoteOrderedSlugs {
            let orderIndex = Dictionary(uniqueKeysWithValues: remoteOrder.enumerated().map { ($1, $0) })
            return filtered.sorted { (orderIndex[$0.slug] ?? Int.max) < (orderIndex[$1.slug] ?? Int.max) }
        }
        return sorted(filtered)
    }

    /// sort_by/sort_type для refreshRemoteOrder — ПОДТВЕРЖДЕНО перехватом
    /// для всех, КРОМЕ dateRead: "updated_at" там — обоснованная догадка
    /// (updated_at у самой ЗАПИСИ закладки меняется, когда двигается
    /// прогресс чтения), а не буквально перехваченный пример с "датой
    /// чтения" — если оно вдруг не совпадёт с сайтом, значит поле другое.
    private var serverSortParams: (sortBy: String, sortType: String) {
        let sortBy: String
        switch sortOption {
        case .titleAsc:       sortBy = "name"
        case .titleDesc:      sortBy = "rus_name"
        case .dateAdded:      sortBy = "created_at"
        case .userRating:     sortBy = "rating"
        case .chapterUpdated: sortBy = "last_chapter_at"
        case .dateRead:       sortBy = "updated_at"
        }
        return (sortBy, sortDirection == .newestFirst ? "desc" : "asc")
    }

    private func refreshRemoteOrder() {
        let params = serverSortParams
        store.refreshRemoteOrder(folderId: selectedFolderId, sortBy: params.sortBy, sortType: params.sortType)
    }

    // MARK: Сортировка (см. ViewSortSheet)

    private func sorted(_ titles: [BookmarkedTitle]) -> [BookmarkedTitle] {
        switch sortOption {
        case .titleAsc:
            // "По названию (A-Z)" — оригинальное/англ. название (см.
            // BookmarkedTitle.originalTitle, ПОДТВЕРЖДЕНО перехватом:
            // sort_by=name), общий sortDirection ниже, как и у всех
            // остальных полей (не зашитое направление, как было раньше).
            return sortedByTitle(titles) { $0.originalTitle ?? $0.title }
        case .titleDesc:
            // "По названию (А-Я)" — русское название (BookmarkedTitle.title
            // уже приоритезирует rusName, см. syncFromServer), ПОДТВЕРЖДЕНО
            // перехватом: sort_by=rus_name.
            return sortedByTitle(titles) { $0.title }
        case .dateAdded:
            return sortedByDate(titles) { $0.addedAt }
        case .userRating:
            // Личная оценка (см. BookmarkedTitle.myRating — уже реальная,
            // приходит с сервером синхронно с закладками, см.
            // BookmarksStore.syncFromServer) — без оценки всегда в конец,
            // тот же принцип, что и у sortedByDate ниже.
            return titles.sorted { a, b in
                switch (a.myRating, b.myRating) {
                case let (ra?, rb?): return sortDirection == .newestFirst ? ra > rb : ra < rb
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): return false
                }
            }
        case .dateRead:
            return sortedByDate(titles) { store.readingProgress(forSlug: $0.slug)?.lastReadAt }
        case .chapterUpdated:
            // Нет подтверждённых данных о дате обновления глав ИМЕННО этого
            // тайтла на стороне закладок (BookmarkedTitle — лёгкий локальный
            // снимок, без этого поля) — пока не переставляем список, чтобы
            // не выдумывать несуществующие данные. Появится вместе с самими
            // данными (см. project.yml/CLAUDE.md — принцип "не полу-готовые
            // реализации").
            return titles
        }
    }

    /// Общий компаратор для обоих "По названию" — .newestFirst здесь значит
    /// то же, что и у дат/оценки: "по убыванию" (Z-A/Я-А), не завязано на
    /// конкретное поле.
    private func sortedByTitle(_ titles: [BookmarkedTitle], key: (BookmarkedTitle) -> String) -> [BookmarkedTitle] {
        titles.sorted { a, b in
            let cmp = key(a).localizedCaseInsensitiveCompare(key(b))
            return sortDirection == .newestFirst ? cmp == .orderedDescending : cmp == .orderedAscending
        }
    }

    private func sortedByDate(_ titles: [BookmarkedTitle], date: (BookmarkedTitle) -> Date?) -> [BookmarkedTitle] {
        titles.sorted { a, b in
            switch (date(a), date(b)) {
            case let (da?, db?): return sortDirection == .newestFirst ? da > db : da < db
            case (nil, .some): return false   // без даты — всегда в конец
            case (.some, nil): return true
            case (nil, nil): return false
            }
        }
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
                    if folder.isDefault {
                        // 5 стандартных папок на реальном сайте вообще не
                        // переименовываются/не удаляются — там нет такого UI,
                        // поэтому долгое нажатие тут ничего не открывает.
                        categoryChip(title: folder.name, id: folder.id)
                    } else {
                        categoryChip(title: folder.name, id: folder.id)
                            .contextMenu { folderContextMenu(folder) }
                    }
                }
                addFolderChip
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Долгое нажатие на чип кастомной папки — ПОДТВЕРЖДЕНО перехватом:
    /// переименование/цвет (`PUT /bookmarks/folder/{id}`) и удаление
    /// (`DELETE /bookmarks/folder/{id}`, см. BookmarksStore.updateFolder/
    /// deleteFolder).
    private func folderContextMenu(_ folder: BookmarkFolder) -> some View {
        Group {
            Button {
                editingFolder = folder
            } label: {
                Label("Изменить", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deletingFolder = folder
            } label: {
                Label("Удалить папку", systemImage: "trash")
            }
        }
    }

    // MARK: Мультивыбор ("Выбрать" в шапке)

    /// Панель мультивыбора — заменяет собой categoryMenu на время выбора
    /// (см. safeAreaInset выше). "N выбрано" + "Все"/"Снять" + Переместить/
    /// Удалить, ПОДТВЕРЖДЕНО перехватом (PUT/DELETE /bookmarks/bulk, см.
    /// BookmarksStore.bulkMove/bulkDelete).
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button(selectedSlugs.count == currentTitles.count ? "Снять" : "Все") {
                if selectedSlugs.count == currentTitles.count {
                    selectedSlugs.removeAll()
                } else {
                    selectedSlugs = Set(currentTitles.map { $0.slug })
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accent)

            Text("\(selectedSlugs.count) выбрано")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 0)

            if isBulkProcessing {
                ProgressView().tint(Theme.accent)
            } else {
                Button {
                    showBulkMoveSheet = true
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(selectedSlugs.isEmpty)

                Button(role: .destructive) {
                    showBulkDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedSlugs.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.pillControlHeight + 12)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    private func bulkMove(to folderId: String) {
        let slugs = Array(selectedSlugs)
        isBulkProcessing = true
        Task {
            do {
                try await store.bulkMove(slugs: slugs, toFolder: folderId)
                selectedSlugs.removeAll()
                isSelecting = false
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
            }
            isBulkProcessing = false
        }
    }

    private func bulkDelete() {
        let slugs = Array(selectedSlugs)
        isBulkProcessing = true
        Task {
            do {
                try await store.bulkDelete(slugs: slugs)
                selectedSlugs.removeAll()
                isSelecting = false
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DownloadsManager.shared.showBanner(message)
            }
            isBulkProcessing = false
        }
    }

    /// Общая "плашка тапа" на строку/карточку тайтла — в обычном режиме
    /// открывает карточку (NavigationLink) + долгое нажатие меняет папку
    /// (bookmarkContextMenu), в режиме мультивыбора тап переключает выбор,
    /// вместо навигации, с кружком-чекбоксом поверх обложки.
    @ViewBuilder
    private func bookmarkTapTarget<Content: View>(_ bm: BookmarkedTitle, @ViewBuilder content: () -> Content) -> some View {
        let selected = selectedSlugs.contains(bm.slug)
        let base = content().overlay(alignment: .topLeading) {
            if isSelecting {
                // ЗАМЕТКА: не .symbolRenderingMode(.palette) с двумя цветами
                // — у "circle" всего один слой, вторая цветовая палитра для
                // него молча игнорируется (проверено), кружок в невыбранном
                // состоянии рисовался бы background-цветом, а не серым
                // полупрозрачным. Поэтому явные Circle-фигуры, а не SF Symbol.
                ZStack {
                    Circle()
                        .fill(selected ? Theme.accent : Color.black.opacity(0.35))
                    if !selected {
                        Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    }
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.background)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(6)
            }
        }
        if isSelecting {
            Button {
                if selected { selectedSlugs.remove(bm.slug) } else { selectedSlugs.insert(bm.slug) }
            } label: {
                base
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: bm) { base }
                .buttonStyle(.plain)
                .contextMenu { bookmarkContextMenu(bm) }
        }
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
                // В режиме "Плитка" — скелетон-сетка под текущее число
                // колонок (та же идея, что и в Каталоге, см. skeletonGrid
                // там), в списке — как раньше, просто спиннер.
                if viewMode == .grid {
                    bookmarksSkeletonGrid
                } else {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Пусто",
                    systemImage: "bookmark",
                    description: Text("Добавляйте тайтлы через кнопку «Добавить в» на странице тайтла.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            // Список/плитка — см. ViewSortSheet (иконка шестерёнки).
            switch viewMode {
            case .list: listContent
            case .grid: gridContent
            }
        }
    }

    /// Зажать палец на тайтле — изменить папку/убрать из закладок, не
    /// открывая страницу тайтла. Общий для списка и плитки.
    @ViewBuilder
    private func bookmarkContextMenu(_ bm: BookmarkedTitle) -> some View {
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

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(currentTitles) { bm in
                    bookmarkTapTarget(bm) { row(bm) }
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
        .scrollIndicators(.hidden)
    }

    // Число колонок — динамическое (см. cardsPerRow/CardsPerRow), 2/3/4/Авто(=3).
    private var gridColumnsCount: Int { cardsPerRow.columns }
    private static let gridSpacing: CGFloat = 12
    private static let gridHorizontalPadding: CGFloat = 12

    /// Та же архитектура, что и MangaCatalogView.grid (см. комментарий там
    /// и у MangaCardView.width): ширина карточки считается ОДИН раз через
    /// GeometryReader и кормит и GridItem(.fixed), и саму карточку — вместо
    /// LazyVGrid(.flexible())+.aspectRatio, которые могли разойтись на
    /// пиксель между соседними карточками. Ряды — явным stride, а не плоский
    /// ForEach: нужно видеть все карточки ряда сразу, чтобы решить, нужна ли
    /// ряду высота под 2-строчные название/прогресс (см. bookmarkGridCell).
    private var gridContent: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: Self.gridSpacing,
                containerPadding: Self.gridHorizontalPadding
            )
            let titles = currentTitles
            let rows = stride(from: 0, to: titles.count, by: gridColumnsCount).map { start in
                Array(titles[start..<min(start + gridColumnsCount, titles.count)])
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                        let twoLineTitle = rowItems.contains {
                            Self.gridTitleLineCount($0.title, width: cardWidth) > 1
                        }
                        let twoLineProgress = rowItems.contains {
                            Self.gridProgressLineCount(progressText(for: $0), width: cardWidth) > 1
                        }
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            ForEach(rowItems) { bm in
                                bookmarkTapTarget(bm) {
                                    bookmarkGridCell(bm, width: cardWidth,
                                                      twoLineTitle: twoLineTitle, twoLineProgress: twoLineProgress)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Скелетон-сетка на время первой подтяжки закладок аккаунта (см.
    /// titlesList/store.isSyncing) — та же ширина карточки, что и у
    /// настоящей плитки, шиммер-плейсхолдеры вместо реальных обложек/текста.
    /// 12 ячеек с запасом — не привязано к реальному количеству закладок
    /// (его ещё не знаем).
    private var bookmarksSkeletonGrid: some View {
        GeometryReader { proxy in
            let cardWidth = MangaCardView.gridCardWidth(
                totalWidth: proxy.size.width,
                columns: gridColumnsCount,
                spacing: Self.gridSpacing,
                containerPadding: Self.gridHorizontalPadding
            )
            let placeholderCount = 12
            let rows = stride(from: 0, to: placeholderCount, by: gridColumnsCount).map { start in
                Array(start..<min(start + gridColumnsCount, placeholderCount))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, rowIndices in
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            ForEach(rowIndices, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    SkeletonBox()
                                        .frame(width: cardWidth, height: (cardWidth * 3 / 2).rounded())
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    SkeletonBar(width: cardWidth * 0.85, height: 12)
                                    SkeletonBar(width: cardWidth * 0.5, height: 10)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.gridHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// "Продолжить N/M" / "Продолжить: Том X, Глава Y" / "Начать чтение" —
    /// тот же формат, что и в списке (см. row(_:) ниже), только с явным
    /// "Начать чтение" вместо "Открыть" для карточек плитки, по прямой просьбе.
    private func progressText(for bm: BookmarkedTitle) -> String {
        guard let p = store.readingProgress(forSlug: bm.slug) else { return "Начать чтение" }
        return p.totalChapters > 0
            ? "Продолжить \(p.lastChapterNumber)/\(p.totalChapters)"
            : "Продолжить: Том \(p.lastChapterVolume), Глава \(p.lastChapterNumber)"
    }

    /// Карточка плитки закладок: обложка 2:3 с тремя чипами поверх (глава
    /// слева сверху / твоя оценка справа сверху / "..." смена папки справа
    /// снизу, все три — см. helpers ниже), название (макс 2 строки) +
    /// прогресс чтения (макс 2 строки). twoLineTitle/twoLineProgress считает
    /// родительский ряд целиком (см. gridContent) — та же логика, что и в
    /// MangaCardView.rowNeedsTwoLines: у всех карточек ряда одна и та же
    /// минимальная высота текстового блока, сами строки внутри каждой
    /// карточки всегда стоят вплотную, недостающая высота уходит пустым
    /// местом снизу, а не зазором между названием и прогрессом.
    private func bookmarkGridCell(_ bm: BookmarkedTitle, width: CGFloat, twoLineTitle: Bool, twoLineProgress: Bool) -> some View {
        let progress = store.readingProgress(forSlug: bm.slug)
        return VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: bm.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: width, height: (width * 3 / 2).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            .overlay(alignment: .topLeading) { chapterChip(progress) }
            .overlay(alignment: .topTrailing) { myRatingChip(bm.myRating) }
            .overlay(alignment: .bottomTrailing) { folderMenuChip(bm) }

            VStack(alignment: .leading, spacing: Self.gridTextSpacing) {
                Text(bm.title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .topLeading)

                Text(progressText(for: bm))
                    .font(.caption2)
                    .foregroundStyle(progress != nil ? Theme.accent : Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .topLeading)
            }
            .frame(width: width, alignment: .top)
            .frame(minHeight: Self.gridTextBlockHeight(twoLineTitle: twoLineTitle, twoLineProgress: twoLineProgress), alignment: .top)
        }
        .frame(width: width, alignment: .top)
    }

    // MARK: Точный расчёт высоты текстового блока плитки (см. bookmarkGridCell)

    private static var gridTitleFont: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    private static var gridProgressFont: UIFont { UIFont.preferredFont(forTextStyle: .caption2) }
    private static var gridTextSpacing: CGFloat { gridTitleFont.leading }

    private static func gridLineCount(_ text: String, width: CGFloat, font: UIFont) -> Int {
        guard width > 0 else { return 1 }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return min(max(Int((box.height / font.lineHeight).rounded(.up)), 1), 2)
    }
    private static func gridTitleLineCount(_ text: String, width: CGFloat) -> Int {
        gridLineCount(text, width: width, font: gridTitleFont)
    }
    private static func gridProgressLineCount(_ text: String, width: CGFloat) -> Int {
        gridLineCount(text, width: width, font: gridProgressFont)
    }
    private static func gridTextBlockHeight(twoLineTitle: Bool, twoLineProgress: Bool) -> CGFloat {
        let titleHeight = gridTitleFont.lineHeight * (twoLineTitle ? 2 : 1)
        let progressHeight = gridProgressFont.lineHeight * (twoLineProgress ? 2 : 1)
        return (titleHeight + gridTextSpacing + progressHeight).rounded(.up)
    }

    // MARK: Чипы поверх обложки в плитке

    /// Номер текущей/последней открытой главы — слева сверху, только в
    /// плитке. Ничего не рисует, если прогресса ещё нет (тайтл не открывали).
    @ViewBuilder
    private func chapterChip(_ progress: ReadingProgress?) -> some View {
        if let progress {
            Text("Глава \(progress.lastChapterNumber)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
    }

    /// Твоя личная оценка тайтла (см. BookmarkedTitle.myRating) — справа
    /// сверху. В отличие от RatingChip (оценка САЙТА, 3 фиксированные зоны
    /// цвета красный/жёлтый/зелёный) здесь НЕПРЕРЫВНЫЙ градиент красный→
    /// зелёный по значению 0-10, по прямой просьбе. Ничего не рисует, если
    /// оценка ещё не подтянулась (см. BookmarksStore.setMyRating).
    @ViewBuilder
    private func myRatingChip(_ rating: Int?) -> some View {
        if let rating {
            Text("\(rating)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(personalRatingColor(rating), in: Capsule())
                .padding(6)
        }
    }

    /// "..." — быстрая смена папки без захода на страницу тайтла и без
    /// долгого нажатия, справа снизу. .highPriorityGesture (а не Button) —
    /// карточка целиком лежит внутри NavigationLink(value:), обычный Button
    /// внутри его лейбла не всегда надёжно перехватывает тап отдельно от
    /// самой навигации; .highPriorityGesture гарантированно забирает тап
    /// раньше NavigationLink, не запуская переход на карточку тайтла.
    private func folderMenuChip(_ bm: BookmarkedTitle) -> some View {
        Image(systemName: "ellipsis")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.55), in: Circle())
            .padding(6)
            .contentShape(Circle())
            .highPriorityGesture(TapGesture().onEnded { editingBookmark = bm })
    }

    /// Соотношение сторон и закругление обложки — эталон Каталог/Новинки
    /// (см. MangaCardView.cover: 2:3, radius 16), раньше здесь было 78×109
    /// (≈5:7, чуть уже) и radius 12 — рассинхрон с остальным приложением.
    /// Увеличена и вплотную к краю подложки (была с отступом 10 со всех
    /// сторон, как у обычного .padding()) — тот же приём, что у
    /// continueReadingCard/updateRow: паддинг только у текстовой колонки и
    /// справа, радиус обложки = радиусу подложки (16, было 18) — угол в угол.
    static let bookmarkCoverWidth: CGFloat = 80
    static let bookmarkCoverHeight: CGFloat = (bookmarkCoverWidth * 3 / 2).rounded()

    private func row(_ bm: BookmarkedTitle) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: bm.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.bookmarkCoverWidth, height: Self.bookmarkCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            // ТВОЯ личная оценка справа сверху — тот же чип (myRatingChip),
            // тот же размер, что и в Плитке (см. bookmarkGridCell), для
            // единообразия между Списком и Плиткой. Раньше здесь была
            // общая (сайтовая) RatingChip — в Плитке в этом углу её и не
            // было никогда, только личная оценка.
            .overlay(alignment: .topTrailing) { myRatingChip(bm.myRating) }

            // Тот же размер текста, что и в «Новое» (NotificationsView.row) —
            // .subheadline для основной строки, .caption2 для второстепенной
            // (было .system(size: 16, weight: .medium) / .caption — крупнее
            // и другой шрифт, экраны выглядели по-разному при одинаковой
            // структуре, попросили "одинаковые по форме").
            VStack(alignment: .leading, spacing: 4) {
                Text(bm.title)
                    .font(.subheadline)
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
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Открыть").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.trailing, 12)
        .frame(height: Self.bookmarkCoverHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Вид/Сортировка (см. BookmarksView.ViewSortSheet)

/// Список/плитка — см. BookmarksView.gridContent/listContent.
enum BookmarksViewMode: String {
    case list, grid
}

/// Поле сортировки списка закладок — см. BookmarksView.sorted(_:).
enum BookmarksSortOption: String, CaseIterable, Identifiable {
    // titleAsc/titleDesc — ИМЕНА оставлены как есть (raw value = ключ
    // @AppStorage) для двух РАЗНЫХ полей, не направлений одного и того же:
    // ПОДТВЕРЖДЕНО перехватом (GET /bookmarks?sort_by=...) — сервер знает
    // ОТДЕЛЬНО `sort_by=name` (оригинальное/англ. название, "A-Z") И
    // `sort_by=rus_name` (русское, "А-Я") — каждое с СОБСТВЕННЫМ asc/desc.
    // Раньше здесь по ошибке было "направление зашито в вариант" (titleAsc/
    // titleDesc = один и тот же текст, А-Я/Я-А) — по факту это два разных
    // ПОЛЯ сортировки, оба подчиняются общему sortDirection ниже, как и
    // остальные пункты.
    case titleAsc, titleDesc, dateAdded, userRating, chapterUpdated, dateRead

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleAsc:        return "По названию (A-Z)"
        case .titleDesc:       return "По названию (А-Я)"
        case .dateAdded:       return "По дате добавления"
        case .userRating:      return "Оценке пользователя"
        case .chapterUpdated:  return "Дате обновления глав"
        case .dateRead:        return "Дате чтения"
        }
    }
}

/// Направление — карточка с "Сначала новые"/"Сначала старые" под списком
/// полей сортировки, ВСЕГДА видна (по прямой просьбе — раньше пряталась
/// для сортировки по названию, "чтобы не пропадало").
enum BookmarksSortDirection: String, CaseIterable, Identifiable {
    case newestFirst, oldestFirst

    var id: String { rawValue }

    /// "По убыванию"/"По возрастанию" — 1-в-1 подписи реального сайта (по
    /// прямой просьбе, скриншот "Настройки" списков закладок), нейтральные
    /// к полю сортировки — годятся и для дат, и для оценки пользователя
    /// (raw-значения newestFirst/oldestFirst не переименовывал — это только
    /// ключ для @AppStorage, смена сломала бы уже сохранённый выбор).
    var title: String { self == .newestFirst ? "По убыванию" : "По возрастанию" }
}

/// Щит редактирования порядка списков (иконка карандаша в шапке Закладок) —
/// драг для перестановки, порядок определяет порядок чипов внизу
/// (BookmarksView.categoryMenu читает store.allFolders в этом же порядке).
/// Плюс кнопка создания новой папки — по прямой просьбе ("и в этом щите
/// ещё кнопка создать новую папку").
private struct FolderOrderSheet: View {
    @ObservedObject var store: BookmarksStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.allFolders) { folder in
                    Text(folder.name)
                        .foregroundStyle(Theme.textPrimary)
                        .listRowBackground(Theme.surface)
                }
                .onMove { from, to in store.moveFolders(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            // Список всегда в режиме перестановки — экран только для этого,
            // отдельный переключатель "Изменить"/"Готово" не нужен. Без
            // .onDelete кнопка удаления строки не появляется — только ручка
            // перетаскивания.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Порядок списков")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .alert("Новая папка", isPresented: $showNewFolder) {
                TextField("Название папки", text: $newFolderName)
                Button("Отмена", role: .cancel) { newFolderName = "" }
                Button("Создать") {
                    store.createFolder(name: newFolderName)
                    newFolderName = ""
                }
            } message: {
                Text("Папка появится здесь и в списке «Добавить в».")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Переименование/смена цвета кастомной папки — долгое нажатие на чип (см.
/// folderContextMenu). ПОДТВЕРЖДЕНО перехватом `PUT /bookmarks/folder/{id}`
/// (см. BookmarksStore.updateFolder) — тело ВСЕГДА полное, все 4 поля разом:
/// название, цвет, "Публичная" (public) и "Уведомлять о новых главах"
/// (notify) — по прямой просьбе, ровно то же самое, что предлагает реальный
/// сайт в форме редактирования папки.
private struct EditFolderSheet: View {
    @ObservedObject var store: BookmarksStore
    let folder: BookmarkFolder
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: Color
    @State private var isPublic: Bool
    @State private var notify: Bool

    init(store: BookmarksStore, folder: BookmarkFolder) {
        self.store = store
        self.folder = folder
        _name = State(initialValue: folder.name)
        _color = State(initialValue: Color(editFolderHex: folder.colorHex) ?? Theme.accent)
        _isPublic = State(initialValue: folder.isPublic ?? true)
        _notify = State(initialValue: folder.notify ?? false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Название").font(.footnote).foregroundStyle(Theme.textSecondary)
                        TextField("Название папки", text: $name)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack {
                        Text("Цвет").foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        ColorPicker("", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(spacing: 0) {
                        Toggle(isOn: $isPublic) {
                            Text("Публичная").foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)

                        Divider().overlay(Theme.separator).padding(.leading, 16)

                        Toggle(isOn: $notify) {
                            Text("Уведомлять о новых главах").foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Изменить папку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") {
                        store.updateFolder(folder.id, name: name, colorHex: color.editFolderHexString,
                                            notify: notify, isPublic: isPublic)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// Удаление кастомной папки — долгое нажатие на чип (см. folderContextMenu).
/// ПОДТВЕРЖДЕНО перехватом `DELETE /bookmarks/folder/{id}`, опционально
/// `{"move_to":<id>}` (см. BookmarksStore.deleteFolder). "Перенести тайтлы"
/// — ВЫКЛЮЧЕНО по умолчанию, ровно как на реальном сайте (там это
/// отдельная, самостоятельно включаемая галочка — по умолчанию тайтлы
/// удаляются вместе с папкой).
private struct DeleteFolderSheet: View {
    @ObservedObject var store: BookmarksStore
    let folder: BookmarkFolder
    /// Вызывается сразу после реального удаления — вызывающий экран
    /// сбрасывает выбранный фильтр, если он указывал на эту папку.
    var onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var moveItems = false
    @State private var targetFolderId: String?

    private var itemsCount: Int { store.titlesCount(in: folder.id) }
    private var otherFolders: [BookmarkFolder] { store.allFolders.filter { $0.id != folder.id } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                    Text("Удалить «\(folder.name)»?")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if itemsCount > 0 {
                        Text("В папке \(itemsCount) \(titlesWord(itemsCount)). Без переноса они будут удалены вместе с папкой — как на сайте.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 12)

                if itemsCount > 0 {
                    VStack(spacing: 0) {
                        Toggle(isOn: $moveItems.animation(.easeInOut(duration: 0.2))) {
                            Text("Перенести тайтлы в другую папку").foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)

                        if moveItems, !otherFolders.isEmpty {
                            Divider().overlay(Theme.separator).padding(.leading, 16)
                            HStack {
                                Text("Куда").foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                                Picker("", selection: $targetFolderId) {
                                    ForEach(otherFolders) { f in
                                        Text(f.name).tag(Optional(f.id))
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Theme.accent)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                    }
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    store.deleteFolder(folder.id, moveTo: moveItems ? targetFolderId : nil)
                    onDeleted()
                    dismiss()
                } label: {
                    Text("Удалить папку")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .onAppear {
            // Дефолт — "Читаю", как на реальном сайте (там перенос по
            // умолчанию целится в id 1/21, стандартную папку "в процессе").
            targetFolderId = otherFolders.first(where: { $0.id == "reading" })?.id ?? otherFolders.first?.id
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func titlesWord(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "тайтл" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "тайтла" }
        return "тайтлов"
    }
}

/// Выбор папки назначения для группового перемещения (см. BookmarksView.
/// selectionBar/bulkMove) — ПОДТВЕРЖДЕНО перехватом `PUT /bookmarks/bulk`.
/// Простой список, без отложенного "Применить" (в отличие от
/// AddToFolderSheet) — тап сразу вызывает onSelect и закрывает лист, т.к.
/// это одноразовое действие над уже явно выбранной группой тайтлов.
private struct BulkMoveFolderSheet: View {
    @ObservedObject var store: BookmarksStore
    /// Папка, из которой сейчас перемещают (если открыта конкретная, не
    /// «Все») — исключаем её саму из списка целей, перенос "туда же" не нужен.
    let excludingFolderId: String?
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var targets: [BookmarkFolder] {
        store.allFolders.filter { $0.id != excludingFolderId }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(targets) { folder in
                        Button {
                            onSelect(folder.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(folder.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Переместить в")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// "тайтл"/"тайтла"/"тайтлов" — та же ru-плюрализация, что и у
/// DeleteFolderSheet.titlesWord выше (своя копия — BookmarksView нужна для
/// алерта группового удаления, см. selectionBar).
private func pluralizedTitlesWord(_ n: Int) -> String {
    let mod10 = n % 10, mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return "тайтл" }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "тайтла" }
    return "тайтлов"
}

/// Свой парсер hex-цвета (тот же приём, что и в BookmarksStore/
/// UserBookmarksView/NotificationSettingsView — там он `private` и не виден
/// отсюда) — плюс обратная конвертация Color → hex, нужна только здесь
/// (сохранение выбора ColorPicker, см. EditFolderSheet).
private extension Color {
    init?(editFolderHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var editFolderHexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// Щит "Вид"/"Сортировка" (иконка шестерёнки в шапке Закладок).
private struct ViewSortSheet: View {
    @Binding var viewMode: BookmarksViewMode
    @Binding var sortOption: BookmarksSortOption
    @Binding var sortDirection: BookmarksSortDirection

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                // Заголовки секций — ОТДЕЛЬНО НАД подложкой, не первой
                // строкой внутри неё (эталон — системные "Настройки" iOS, по
                // прямой просьбе со скриншотом: там подпись сверху, мелким
                // серым, не на самой карточке). См. sectionBlock ниже.
                VStack(alignment: .leading, spacing: 20) {
                    sectionBlock("Вид") {
                        selectableRow(title: "Список", icon: "list.bullet", isSelected: viewMode == .list) {
                            viewMode = .list
                        }
                        divider
                        selectableRow(title: "Плитка", icon: "square.grid.2x2", isSelected: viewMode == .grid) {
                            viewMode = .grid
                        }
                    }

                    sectionBlock("Сортировка") {
                        ForEach(BookmarksSortOption.allCases) { option in
                            selectableRow(title: option.title, isSelected: sortOption == option) {
                                sortOption = option
                            }
                            if option != BookmarksSortOption.allCases.last {
                                divider
                            }
                        }
                    }

                    // Направление — своя ОТДЕЛЬНАЯ подложка ниже, без
                    // заголовка, ВСЕГДА видна (по прямой просьбе — раньше
                    // пряталась для сортировки по названию, "чтобы не
                    // пропадало").
                    card {
                        ForEach(BookmarksSortDirection.allCases) { direction in
                            selectableRow(title: direction.title, isSelected: sortDirection == direction) {
                                sortDirection = direction
                            }
                            if direction != BookmarksSortDirection.allCases.last {
                                divider
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        // Полностью открытым сразу (не .medium с доводкой пальцем до
        // .large) — по прямой просьбе, этот щит короткий и разворачивать
        // руками смысла нет.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var divider: some View {
        Divider().overlay(Theme.separator).padding(.leading, 16)
    }

    /// Заголовок + подложка под ним — эталон "Настройки" iOS (см. body):
    /// подпись мелким серым текстом СВЕРХУ, отдельно от карточки, не первой
    /// строкой внутри неё.
    private func sectionBlock(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            card(content: content)
        }
    }

    private func selectableRow(title: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                }
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Радиус — тот же, что и у карточек в разделе "Меню" (см.
    // SideMenuView.cardCornerRadius) — тот же эталон, что и в
    // PersonalizationSettingsView.card.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    BookmarksView().preferredColorScheme(.dark)
}
