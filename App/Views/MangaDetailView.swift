import SwiftUI
import UIKit

/// Экран тайтла: шапка, инфо-строка, кнопки, вкладки (О тайтле / Главы / Комментарии).
struct MangaDetailView: View {

    @StateObject private var viewModel: MangaDetailViewModel
    @ObservedObject private var bookmarks = BookmarksStore.shared
    @ObservedObject private var downloads = DownloadsManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private let fallbackTitle: String
    private let coverURL: URL?
    private let listItem: MangaItem?
    /// true — экран открыт из профиля через щит-меню (см. UserBookmarksView/
    /// MyCommentsView: pinnedHeader: !showsOwnHeader), кнопки "назад"/"..." тогда
    /// зафиксированы отдельным слоем поверх скролла (см. pinnedTopBar), а не
    /// уезжают вместе с heroHeader, как при обычном входе (каталог/поиск и т.п.).
    private let pinnedHeader: Bool

    @State private var tab: Tab = .about
    /// Показ sheet со всеми названиями тайтла (по тапу на название в шапке) —
    /// см. TitleNamesSheet.
    @State private var showTitleNames = false
    /// Sheet «Скачать тайтл» — см. DownloadTitleSheet.
    @State private var showDownloadSheet = false
    /// Полноэкранная листалка доп. обложек (тап по обложке в шапке) — см.
    /// CoverGalleryView/coverGalleryBadge.
    @State private var showCoverGallery = false
    /// Снимок текущего экрана (карточки тайтла) для блюр-фона листалки — см.
    /// UIView.renderedSnapshot (CoverGalleryView.swift): "размываться должна
    /// не картинка, а именно приложение за ней". Берётся ОДИН раз прямо
    /// перед открытием (см. onTapGesture ниже), не хранится постоянно.
    @State private var coverGalleryBackgroundSnapshot: UIImage?
    /// Namespace для .matchedTransitionSource/.navigationTransition(.zoom) —
    /// листалка "вырастает" из этой самой обложки при открытии, а не выезжает
    /// отдельным чёрным экраном (по прямой просьбе).
    @Namespace private var coverGalleryNamespace
    /// URL'ы для листалки — реальная галерея (GET /manga/{slug}/covers), а
    /// если она пустая (у большинства тайтлов доп. обложек вообще нет) —
    /// один-единственный URL основной обложки: тап должен открывать
    /// полноэкранный вид ВСЕГДА, вне зависимости от того, есть ли доп.
    /// обложки (по прямой просьбе), просто без пролистывания в этом случае.
    private var coverGalleryImageURLs: [URL] {
        // bestURL (md), не fullResURL (orig) — в листалке нет зума, orig
        // ничего не даёт визуально (экран телефона всё равно меньше), а
        // декодировать/рендерить полноразмерный оригинал на лету во время
        // интерактивного свайпа заметно тяжелее — вероятная причина
        // "резко перепрыгивает" при пролистывании (просадка кадров).
        if !viewModel.coverGallery.isEmpty {
            return viewModel.coverGallery.compactMap { $0.cover.bestURL }
        }
        if let url = viewModel.detail?.cover?.bestURL ?? coverURL ?? listItem?.cover?.bestURL {
            return [url]
        }
        return []
    }
    /// URL тайтла для «Поделиться» (см. actionMenu) — обычная ссылка на
    /// страницу тайтла на активном сайте.
    private var shareURL: URL? {
        URL(string: "https://\(SiteSession.shared.activeSite.host)/ru/manga/\(viewModel.slug)")
    }
    /// Пространство координат для "переезжающего" индикатора активной вкладки
    /// (см. tabButton/matchedGeometryEffect) — благодаря общему namespace
    /// SwiftUI анимирует подчёркивание как ОДНУ вьюху, плавно перемещая её (и
    /// подгоняя ширину под текст новой вкладки) между "О тайтле"/"Главы"/
    /// "Комментарии", а не гасит одно и зажигает другое.
    @Namespace private var tabIndicator
    @State private var showAddToFolder = false
    /// Открытие ридера: глава + выбранная ветка (команда). branchId nil —
    /// первая ветка главы.
    private struct ReaderOpen: Identifiable {
        let id = UUID()
        let chapter: ChapterItem
        let branchId: Int?
    }
    @State private var readerOpen: ReaderOpen?
    @State private var commentDraft = ""
    /// Режим "весь комментарий — спойлер" (см. composeBar) — ПОДТВЕРЖДЕНО
    /// реальным перехватом отправки, см. MangaNetworkService.postComment
    /// (spoilerLabel:). Подпись по умолчанию — как в примере из перехвата.
    @State private var spoilerMode = false
    @State private var spoilerLabelDraft = "спойлер"
    @State private var showLoginForComment = false
    /// Фокус полей ввода комментария (сам текст ИЛИ подпись спойлера, см.
    /// composeBar) — общий Bool на оба поля, нужен только чтобы понять, что
    /// клавиатура сейчас открыта, и свернуть её тапом по любому "пустому"
    /// месту вкладки «Комментарии» (см. commentsTab.onTapGesture), а не
    /// только системным свайпом/кнопкой "Done".
    @FocusState private var commentFieldFocused: Bool

    // MARK: Комментарии — доп. состояние UI (не сетевое, живёт только в этом View)

    /// Комментарий, на который сейчас отвечают (показывается плашка "Ответ
    /// @username" над полем ввода, см. composeBar) — nil означает обычный,
    /// корневой комментарий.
    @State private var replyingTo: Comment?
    /// Настройки комментариев — sheet с чекбоксом/слайдером, см. CommentSettingsSheet.
    @State private var showCommentSettings = false
    /// Ветки, которые пользователь вручную развернул, несмотря на авто-сворачивание
    /// с уровня collapseFromLevel (см. commentSettings) — id родительского комментария.
    @State private var expandedThreads: Set<Int> = []
    /// "Жалоба" — реального эндпоинта нет ни в одном перехваченном запросе,
    /// поэтому просто честно говорим, что функция скоро появится, а не
    /// притворяемся, что жалоба ушла.
    @State private var showReportComingSoon = false
    /// Меню "•••" у комментария (см. commentMenu): "Ссылка на комментарий"
    /// копирует ссылку вида .../manga/{slug}?section=comments&comment_id={id}
    /// (формат подтверждён примером пользователя), "Добавить в игнор лист"
    /// шлёт MangaNetworkService.addToIgnoreList (эндпоинт НЕ подтверждён
    /// перехватом — см. комментарий там). showCommentLinkCopied/
    /// showIgnoreResult — короткая обратная связь после действия.
    @State private var showCommentLinkCopied = false
    @State private var showIgnoreResult: String?

    /// Голос "+"/"-" за "Похожее" (см. similarSection/similarVoteColumn) —
    /// требует авторизации так же, как и комментарии; отдельный флаг вместо
    /// переиспользования showLoginForComment, т.к. источник действия другой.
    @State private var showLoginForSimilarVote = false
    /// Открытый профиль автора комментария (тап по нику/аватарке).
    @State private var profileUser: ProfileUserId?
    /// Открытая франшиза (тап по чипу-подкатегории, см. franchiseChip) —
    /// FranchiseRef уже Identifiable (id франшизы), отдельный обёрточный
    /// тип не нужен.
    @State private var franchiseTarget: FranchiseRef?

    /// Отключить комментарии в читалке — ПОКА ЗАГЛУШКА, как явно попросили:
    /// переключатель есть и сохраняется, но ридер комментарии не показывает
    /// вообще (ни при true, ни при false) — реальная реализация комментариев
    /// В САМОЙ ЧИТАЛКЕ не входит в этот раунд.
    @AppStorage("comments_disabled_in_reader") private var commentsDisabledInReader = false
    /// Отключить комментарии на карточке тайтла — общая настройка с читалкой
    /// (см. CommentSettingsSheet). При true вкладка «Комментарии» вместо списка
    /// показывает «Вы отключили комментарии» + кнопку «Настроить».
    @AppStorage("comments_disabled_on_card") private var commentsDisabledOnCard = false
    /// С какого уровня вложенности сворачивать ответы по умолчанию (см.
    /// commentNode) — реальная, рабочая настройка (в отличие от переключателя выше).
    @AppStorage("comments_collapse_level") private var collapseFromLevel: Double = 3

    /// Какую картинку сейчас показывает hero-баннер, и является ли она
    /// НАСТОЯЩИМ фоном (а не запасной обложкой) — см. heroHeader/updateHero.
    /// Специально ОТДЕЛЬНОЕ состояние (а не просто выражение "detail?.background
    /// ?? cover ?? coverURL" на лету) — чтобы контролировать МОМЕНТ появления
    /// картинки и не переключать её резко (см. комментарии у updateHero).
    @State private var heroURL: URL?
    @State private var heroIsRealBackground = false

    /// Сортировка глав: true — новые сверху (по умолчанию), false — старые
    /// (Глава 1) сверху. Переключается кнопкой «Сортировать».
    @State private var chaptersNewestFirst = true
    /// id главы, к которой нужно прокрутить список (кнопка «К главе»).
    @State private var chapterScrollTarget: Int?

    enum Tab: Hashable { case about, chapters, comments }

    init(slug: String, fallbackTitle: String = "", coverURL: URL? = nil, item: MangaItem? = nil,
         pinnedHeader: Bool = false) {
        // siteId берём из элемента (каталог/поиск/похожее/связанное/персонаж) —
        // тайтл может жить на другом сайте, чем активный, и без правильного
        // Site-Id карточка отдаёт 404 (пропадает описание).
        _viewModel = StateObject(wrappedValue: MangaDetailViewModel(slug: slug, siteId: item?.site))
        self.fallbackTitle = fallbackTitle
        self.coverURL = coverURL
        self.listItem = item
        self.pinnedHeader = pinnedHeader
    }

    private var title: String { viewModel.detail?.displayTitle ?? listItem?.displayTitle ?? fallbackTitle }

    var body: some View {
        ZStack(alignment: .top) {
        ScrollView {
          ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 0) {
                heroHeader
                VStack(alignment: .leading, spacing: 18) {
                    // titleBlock переехал в heroHeader (см. там) — теперь это
                    // overlay поверх фоновой картинки, а не отдельный блок
                    // здесь, чтобы фон мог тянуться ровно до его низа.
                    actionButtons
                    tabBar
                    tabContent
                }
                .padding(.horizontal, 16)
                // Раньше здесь начинался titleBlock, и отступ подгонялся под
                // высоту баннера (250/330). Теперь titleBlock сам живёт внутри
                // heroHeader (см. там) и заканчивается ровно там же, где
                // заканчивается баннер — так что этот отступ просто небольшой
                // зазор перед кнопками, как и spacing между остальными
                // элементами этого VStack (18).
                .padding(.top, 18)
                // 28→100 — та же история, что и в Каталоге/Закладках (см.
                // комментарии там): этот экран тоже пушится через
                // NavigationStack.navigationDestination, а он не всегда
                // надёжно пробрасывает ВНЕШНИЙ safeAreaInset(bottom) из
                // RootView (там резервируется место под плавающую панель) —
                // из-за этого жанры/теги внизу вкладки "О тайтле" заметно
                // заезжали под панель. MangaCatalogView для этой же защиты
                // использует 90pt — здесь беру 100 (контент тут может быть
                // длиннее/ниже, чипов больше).
                .padding(.bottom, 100)
            }
            // Прокрутка к выбранной главе (кнопка «К главе»).
            .onChange(of: chapterScrollTarget) { _, target in
                if let target {
                    // Центрируем выбранную главу, а не ставим её в самый верх.
                    withAnimation(.easeInOut(duration: 0.3)) { scrollProxy.scrollTo(target, anchor: .center) }
                    chapterScrollTarget = nil
                }
            }
          }
        }
        // Убрали видимый вертикальный скроллбар-слайдер справа экрана — как
        // попросили ("убери видимый слайдер вверх-вниз перемотки").
        .scrollIndicators(.hidden)
        // Именованное пространство координат для "тянущейся" шапки (см.
        // heroHeader) — нужно, чтобы отследить, когда ScrollView оттянут
        // вниз за верхнюю границу (overscroll/rubber-band), и растянуть
        // баннер под этот отступ вместо того, чтобы показывать пустой зазор.
        .coordinateSpace(name: "detailScroll")
        .background(Theme.background)
        // Баннер уходит под статус-бар, как в референсе — только на самом
        // ScrollView (не на внешнем ZStack, см. body), чтобы pinnedTopBar
        // (когда есть) сам оставался в системном safe area, без ручной
        // константы под статус-бар/Dynamic Island.
        .ignoresSafeArea(edges: .top)

        if pinnedHeader {
            pinnedTopBar
        }
        }
        // Свой back-button поверх hero (см. heroHeader/pinnedTopBar) вместо
        // системной navigation bar.
        .toolbar(.hidden, for: .navigationBar)
        .task { if viewModel.detail == nil { await viewModel.load() } }
        // Показ hero-картинки (см. heroHeader/updateHero): как только карточка
        // загрузилась — если у неё есть настоящий background (или хотя бы
        // cover) — показываем ЕГО, с плавным появлением.
        .task(id: viewModel.detail?.backgroundURL) {
            guard let detail = viewModel.detail else { return }
            let realBG = detail.background?.bestURL
            updateHero(to: realBG ?? detail.cover?.bestURL ?? coverURL, isReal: realBG != nil)
        }
        // "Около 0.5 сек ничего не используется, а если за это время ничего
        // не подгрузилось — ставим обложку с плавным появлением" (как
        // попросили): если через 0.5с у нас ВСЁ ЕЩЁ нет никакой hero-картинки
        // (карточка либо ещё грузится, либо у неё нет background/cover) —
        // подставляем локально известный coverURL (пришёл параметром при
        // навигации, ждать для него нечего) как временный/финальный фон.
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if heroURL == nil {
                updateHero(to: coverURL ?? listItem?.cover?.bestURL, isReal: false)
            }
        }
        .sheet(isPresented: $showAddToFolder) {
            AddToFolderSheet(
                slug: viewModel.slug, title: title,
                coverURL: coverURL?.absoluteString ?? listItem?.coverURLString,
                rating: (viewModel.detail?.rating ?? listItem?.rating)?.value
            )
        }
        .fullScreenCover(item: $readerOpen) { open in
            readerView(for: open.chapter, branchId: open.branchId)
        }
        .fullScreenCover(isPresented: $showCoverGallery) {
            CoverGalleryView(
                images: coverGalleryImageURLs,
                backgroundSnapshot: coverGalleryBackgroundSnapshot,
                transitionSourceID: "titleCover",
                transitionNamespace: coverGalleryNamespace
            )
        }
        .sheet(isPresented: $showLoginForComment) { LoginView() }
        .sheet(isPresented: $showLoginForSimilarVote) { LoginView() }
        .sheet(item: $profileUser) { pu in ProfileView(userId: pu.id) }
        .navigationDestination(item: $franchiseTarget) { ref in
            FranchiseView(slugURL: ref.slugURL, fallbackName: ref.name)
        }
        .sheet(isPresented: $showTitleNames) {
            TitleNamesSheet(
                rusName: viewModel.detail?.rusName ?? listItem?.rusName,
                originalName: viewModel.detail?.name ?? listItem?.name,
                engName: viewModel.detail?.engName ?? listItem?.engName,
                otherNames: viewModel.detail?.otherNames ?? []
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDownloadSheet) {
            DownloadTitleSheet(
                slug: viewModel.slug,
                coverURL: viewModel.detail?.cover?.bestURL ?? coverURL ?? listItem?.cover?.bestURL,
                heroURL: viewModel.detail?.backgroundURL,
                title: title,
                typeLabel: viewModel.detail?.type?.label ?? listItem?.type?.label,
                chapters: viewModel.chapters,
                readCount: bookmarks.readingProgress(forSlug: viewModel.slug)?.readCount ?? 0
            )
            // Открывается сразу до верха.
            .presentationDetents([.large])
        }
        // Жест «назад» свайпом из левой половины экрана (системный интерактивный
        // переход — во время свайпа виден предыдущий экран). См.
        // InteractivePopGesture. Только на карточке тайтла.
        .background(InteractivePopGesture())
    }

    // MARK: Hero-баннер + выступающая обложка

    /// Базовая высота баннера (без учёта названия) — см. heroHeader. Увеличена
    /// (330→400) по прямому запросу "опусти баннер": даёт больше "воздуха"
    /// картинки над обложкой/названием и делает переход к затемнению внизу
    /// более плавным/растянутым, а не резким.
    private static let heroBaseHeight: CGFloat = 400

    /// Реальный размер плавающей обложки в heroHeader (88×132, увеличенная на
    /// 1.3×1.3) — вынесено в константу, чтобы гейт-зона затемнения ниже могла
    /// точно посчитать "10% высоты обложки", не задваивая магические числа.
    private static let heroCoverSize = CGSize(width: 88 * 1.3 * 1.3, height: 132 * 1.3 * 1.3)

    /// Отступ между обложкой и названием внутри общего overlay-VStack (см.
    /// heroHeader) — тоже вынесен в константу по той же причине.
    private static let heroCoverTitleSpacing: CGFloat = 10

    /// Фиксированное расстояние от верха баннера до верха обложки. Раньше
    /// считалось как heroBaseHeight-высота_обложки-spacing (=167) — из-за чего
    /// обложка «приколачивалась» к самому низу баннера и выглядела съехавшей
    /// вниз. Теперь это НЕЗАВИСИМАЯ фиксированная величина: кнопка «назад»
    /// занимает 54...102 сверху, поэтому 120 = гарантированный зазор под ней.
    /// Обложка стоит СТРОГО на этой высоте независимо от длины названия (оно
    /// ниже обложки и на неё не наезжает), баннер естественно растёт под
    /// название — один проход, без @State/PreferenceKey.
    private static let heroCoverTopOffset: CGFloat = 120

    /// Обновляет, какую картинку показывает hero-баннер — ВСЕГДА с плавным
    /// переходом (fade), даже если это уже вторая/третья смена подряд (сперва
    /// пусто → потом обложка как временная заглушка → потом настоящий фон,
    /// как только он подгрузится). Именно это и попросили: без единого
    /// резкого "прыжка" картинки, сколько бы раз она ни менялась.
    private func updateHero(to url: URL?, isReal: Bool) {
        guard url != heroURL else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            heroURL = url
            heroIsRealBackground = isReal
        }
    }

    /// Вызывается, когда КОНКРЕТНАЯ картинка, которую сейчас пытается
    /// показать hero-баннер, не подгрузилась (см. failure-закрытие RemoteImage
    /// в heroHeader) — раньше в этом случае баннер так и оставался серым
    /// навсегда. Теперь: если не подгрузился именно настоящий фон (background)
    /// — пробуем сразу подставить обложку вместо него; если сама обложка тоже
    /// не смогла (или мы и так уже её показываем) — оставляем как есть, чтобы
    /// не зациклиться.
    private func onHeroLoadFailed(failedURL: URL?) {
        guard failedURL == heroURL, heroIsRealBackground else { return }
        let fallback = viewModel.detail?.cover?.bestURL ?? coverURL ?? listItem?.cover?.bestURL
        guard let fallback, fallback != failedURL else { return }
        updateHero(to: fallback, isReal: false)
    }

    /// Полноширинный баннер + название тайтла поверх него + сама обложка,
    /// выступающая ниже его нижнего края — тот же приём, что и в реальных
    /// читалках (обложка не теряется в мелком размере рядом с текстом, а
    /// становится акцентом шапки). Своя круглая стеклянная кнопка "назад"
    /// вместо системной — см. .toolbar(.hidden...) в body.
    ///
    /// ВАЖНО (архитектура после двух багов подряд): раньше картинка-фон была
    /// ГЛАВНЫМ элементом с явным .frame(height: heroBaseHeight+titleBlockHeight),
    /// а titleBlockHeight — @State, заполняемое ЧЕРЕЗ PreferenceKey из
    /// измерения реального названия. Это ДВУХПРОХОДНАЯ схема с задержкой:
    /// на первом кадре titleBlockHeight ещё 0/устаревший, картинка уже
    /// нарисована с этим неверным числом, а само название — уже в полный
    /// рост. Отсюда и была рассинхронизация: сначала (при .bottomLeading)
    /// обложка на мгновение залезала на кнопку "назад", после фикса через
    /// .topLeading — уже название вылезало под кнопки "Добавить в"/"Начать"
    /// снизу (тот же самый лаг, просто вылез с другой стороны).
    ///
    /// Теперь ГЛАВНЫЙ элемент — content-VStack (проставка сверху + обложка +
    /// название), который считает свою высоту ЕСТЕСТВЕННО, за один проход, без
    /// какого-либо @State/PreferenceKey. Картинка-фон навешена через
    /// .background(alignment: .top) — SwiftUI предлагает фону РОВНО тот же
    /// размер, что уже посчитан для content-VStack, СИНХРОННО, в одном и том
    /// же проходе layout. Рассинхронизации в принципе больше неоткуда взяться.
    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Прозрачная проставка — резервирует место над обложкой, чтобы
            // кнопка "назад" никогда не пересекалась с обложкой, независимо
            // от того, сколько строк займёт название ниже.
            Color.clear.frame(height: Self.heroCoverTopOffset)

            VStack(alignment: .leading, spacing: Self.heroCoverTitleSpacing) {
                // Обложка увеличена ещё на 30% сверх прошлого 1.3х (88×132 → ~149×223).
                // .highPriority — экран может открыться сразу после ленты «Читают»,
                // где в очереди URLSession ещё висят незавершённые запросы её
                // карточек (см. RemoteImageLoader.load(candidates:priority:)).
                RemoteImage(url: viewModel.detail?.cover?.bestURL ?? coverURL, priority: URLSessionTask.highPriority) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: Self.heroCoverSize.width, height: Self.heroCoverSize.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .overlay(alignment: .topLeading) { bookmarkStatusBadge }
                .overlay(alignment: .bottomLeading) { coverRatingBadge }
                .overlay(alignment: .topTrailing) { coverGalleryBadge }
                // Источник для .navigationTransition(.zoom(...)) в
                // CoverGalleryView — листалка "вырастает" из ЭТОЙ обложки.
                .matchedTransitionSource(id: "titleCover", in: coverGalleryNamespace)
                // Тап в любое место обложки — полноэкранный вид ВСЕГДА (см.
                // coverGalleryImageURLs — если доп. обложек нет, там всё
                // равно будет один URL основной обложки, просто без
                // пролистывания). Снимок экрана — прямо перед открытием, для
                // блюр-фона листалки (см. coverGalleryBackgroundSnapshot).
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !coverGalleryImageURLs.isEmpty else { return }
                    coverGalleryBackgroundSnapshot = UIApplication.shared.activeKeyWindow?.renderedSnapshot()
                    showCoverGallery = true
                }

                titleBlockOverlay
            }
            .padding(.leading, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            // GeometryReader + именованное пространство координат "detailScroll" —
            // стандартный приём "тянущейся шапки": пока прокрутка в норме, minY
            // отрицательный/нулевой и баннер выглядит как обычно. Но если
            // потянуть экран ВНИЗ дальше самого верха (rubber-band bounce), minY
            // становится положительным — раньше в этот момент под баннером было
            // видно пустой фон (интерфейс как бы "уезжал" вниз, отрываясь от
            // баннера). Теперь баннер на эту же величину растягивается вверх
            // (frame height + minY, offset -minY), закрывая собой весь зазор.
            //
            // proxy.size здесь — это РОВНО естественный размер content-VStack
            // выше (см. комментарий у heroHeader) — .background предлагает его
            // синхронно, без отдельного @State.
            GeometryReader { proxy in
                let minY = proxy.frame(in: .named("detailScroll")).minY
                let stretch = max(0, minY)
                Group {
                    if let heroURL {
                        // .id(heroURL) — заставляет SwiftUI считать это НОВОЙ
                        // вьюхой при смене картинки (а не просто обновлением
                        // параметра существующей), поэтому .transition(.opacity)
                        // ниже реально проигрывает плавный кросс-фейд между
                        // старой и новой картинкой, а не мгновенную подмену.
                        RemoteImage(url: heroURL, priority: URLSessionTask.highPriority) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            SkeletonBox()
                        } failure: {
                            // Раньше тут просто оставался голый серый прямоугольник
                            // (Theme.surfaceElevated) НАВСЕГДА, если конкретно этот
                            // URL не подгрузился (временная сетевая ошибка и т.п.) —
                            // отсюда "иногда на заднике вообще ничего, только
                            // серое". Теперь при неудаче настоящего фона сразу же
                            // пробуем откатиться на обложку (она с бОльшей вероятностью
                            // уже закэширована/грузится без проблем) — см. onFailedToLoadHero().
                            Theme.surfaceElevated
                                .onAppear { onHeroLoadFailed(failedURL: heroURL) }
                        }
                        .id(heroURL)
                        .transition(.opacity)
                    } else {
                        // Первые ~0.5с (или пока карточка не подгрузится) —
                        // буквально ничего, просто фон экрана (см. updateHero/
                        // .task в body) — как попросили, без skeleton-заглушки.
                        Theme.background
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height + stretch)
                // Ровное 10% затемнение по всей картинке — ДО блюра, чтобы в
                // заблюренном режиме оно тоже размылось вместе с картинкой.
                .overlay(Color.black.opacity(0.1))
                // Блюр — только для ЗАПАСНОЙ обложки (портретная, растянутая на
                // ширину баннера без блюра выглядит "разрезанной"). Для настоящего
                // background блюра нет (radius 0).
                .blur(radius: heroIsRealBackground ? 0 : 5)
                .clipped()
                // Градиент затемнения к фону — ПОСЛЕ блюра и clipped, чтобы низ
                // был РОВНО сплошным до самого края. Раньше он применялся ДО
                // блюра, и блюр «размывал» нижнюю сплошную кромку — из-за этого в
                // режиме запасной обложки затемнение не доходило до самого низа.
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.28),
                            .init(color: Theme.background.opacity(0.35), location: 0.5),
                            .init(color: Theme.background.opacity(0.75), location: 0.72),
                            .init(color: Theme.background, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(y: -stretch)
            }
        }
        .overlay(alignment: .topLeading) {
            // Стрелка вместо крестика + стеклянный фон (как в остальном
            // приложении), вместо .ultraThinMaterial. Добавлена ПОСЛЕДНЕЙ
            // среди overlay-ев — поэтому всегда поверх названия/обложки.
            // Только при обычном входе (не через щит-меню профиля) — иначе
            // кнопки зафиксированы отдельным слоем поверх скролла, см.
            // pinnedTopBar/pinnedHeader.
            if !pinnedHeader {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular, in: Circle())
                }
                .padding(.leading, 16)
                .padding(.top, 54) // ниже статус-бара, баннер уходит под него целиком
            }
        }
        .overlay(alignment: .topTrailing) {
            // Кнопка "..." — стандартное системное Menu (стеклянный список iOS
            // по умолчанию), как попросили. Стеклянный круг вокруг иконки — как
            // у кнопки "назад" слева. Даже с .menuStyle(.borderlessButton) и
            // идентичными width/height/padding голый Image как лейбл Menu
            // рендерился на пару пунктов НЕ на той же высоте, что обычная
            // Button "назад" — известный на iOS 26 нюанс: Menu считает
            // внутренние отступы вокруг лейбла иначе, чем Button (подтверждено
            // ответом инженера Apple DTS на форуме разработчиков). Фикс —
            // обернуть содержимое в Label(title:icon:) вместо голого Image
            // (Menu переходит на icon-only layout) + .compositingGroup() перед
            // glassEffect, чтобы Menu считал вставки по уже готовому,
            // "плоскому" слою, а не по промежуточному. Только при обычном
            // входе — см. комментарий у back-кнопки выше.
            if !pinnedHeader {
                Menu {
                    actionMenuItems
                } label: {
                    Label {
                        EmptyView()
                    } icon: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 48, height: 48)
                            .compositingGroup()
                            .glassEffect(.regular, in: Circle())
                    }
                }
                .menuStyle(.borderlessButton)
                .padding(.trailing, 16)
                .padding(.top, 54)
            }
        }
    }

    /// Пункты меню "..." шапки тайтла — общий источник для обычного (overlay
    /// на heroHeader) и зафиксированного (pinnedTopBar) вариантов, чтобы не
    /// дублировать список при добавлении pinnedTopBar.
    @ViewBuilder
    private var actionMenuItems: some View {
        if let shareURL {
            ShareLink(item: shareURL) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        }
        Button { /* ЗАГЛУШКА */ } label: { Label("Редактирование глав", systemImage: "square.and.pencil") }
        Button { /* ЗАГЛУШКА */ } label: { Label("Добавить главы", systemImage: "plus") }
        Button { /* ЗАГЛУШКА */ } label: { Label("Редактирование тайтла", systemImage: "pencil") }
        Button { showDownloadSheet = true } label: { Label("Скачать тайтл", systemImage: "arrow.down.circle") }
    }

    /// Зафиксированная шапка (назад + "...") — только когда карточка открыта из
    /// профиля через щит-меню (см. pinnedHeader/init, устанавливается в
    /// UserBookmarksView/MyCommentsView через pinnedHeader: !showsOwnHeader). В
    /// отличие от обычного входа (каталог/поиск и т.п., см. heroHeader.overlay
    /// выше) кнопки здесь — ОТДЕЛЬНЫЙ слой ПОВЕРХ ScrollView (тот же приём, что
    /// и ProfileView.topBar в AccountInfoView.swift), а не overlay НА
    /// heroHeader, который сам едет со скроллом — поэтому не уезжают при
    /// скролле карточки. Обе кнопки — в ОДНОЙ HStack-строке (а не в двух
    /// независимых overlay в разных углах, как в обычном режиме) — именно это,
    /// а не сам Menu/Label фикс выше, устраняет разъезд по высоте: раньше
    /// высота каждой кнопки считалась независимо от угла heroHeader, теперь
    /// SwiftUI центрирует обе по общей оси HStack. Размер 44×44 и
    /// .interactive() стекло — как у остальных зафиксированных шапок в
    /// приложении (ProfileView.topBar/HistoryView/MyCommentsView).
    private var pinnedTopBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())

            Spacer(minLength: 0)

            Menu {
                actionMenuItems
            } label: {
                Label {
                    EmptyView()
                } icon: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .compositingGroup()
                        .glassEffect(.regular.interactive(), in: Circle())
                }
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        // Как в HistoryView.header — внешний ZStack (см. body) уважает
        // системный safe area, статус-бар/Dynamic Island уже учтён им, это
        // чисто визуальный зазор, а не ручная аппроксимация высоты статус-бара.
        .padding(.top, 8)
    }

    /// titleBlock с отступом справа — вынесено отдельно от heroHeader просто
    /// для читаемости (никакого измерения высоты больше не нужно, см.
    /// комментарий у heroHeader — высота теперь считается естественно).
    private var titleBlockOverlay: some View {
        // Раньше здесь был .padding(.horizontal, 16) — но titleBlockOverlay
        // живёт ВНУТРИ combo VStack (см. heroHeader), у которого уже есть свой
        // .padding(.leading, 16). Из-за этого название получало ДВОЙНОЙ отступ
        // слева (16+16=32) и визуально съезжало вправо относительно обложки
        // (у которой только один отступ) — отсюда и был замечен сдвиг. Оставляем
        // только правый отступ (безопасный отступ от края экрана при переносе).
        titleBlock
            .padding(.trailing, 16)
    }

    /// Бэйдж статуса закладки поверх обложки тайтла (слева сверху) — тот же
    /// стиль/цвета, что и на карточках каталога, см. MangaCardView.statusBadge.
    @ViewBuilder
    private var bookmarkStatusBadge: some View {
        if let folderId = bookmarks.folderId(forSlug: viewModel.slug),
           let folder = bookmarks.allFolders.first(where: { $0.id == folderId }) {
            Text(folder.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(folder.badgeColor, in: Capsule())
                .padding(6)
        }
    }

    /// Рейтинг поверх обложки тайтла — единый бэйдж (см. RatingChip), тот же
    /// стиль/цвет, что и на карточках каталога и в закладках. Сверху справа
    /// (было снизу справа) — как явно попросили.
    /// Верхний правый бейдж обложки: ★ + оценка + просмотры (коротко, K/M).
    /// Звёздочка перед оценкой, просмотры перенесены сюда (нижний-левый бейдж
    /// удалён) — как попросили.
    @ViewBuilder
    private var coverRatingBadge: some View {
        let ratingObj = viewModel.detail?.rating ?? listItem?.rating
        let rating = ratingObj?.value
        let votes = ratingObj?.votes
        let views = viewModel.detail?.views
        let hasRating = (rating ?? 0) > 0
        let hasVotes = (votes ?? 0) > 0
        let hasViews = (views ?? 0) > 0
        if hasRating || hasViews {
            HStack(spacing: 4) {
                if hasRating, let rating {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                    // Сколько людей поставило оценку — в коротком формате (762k).
                    if hasVotes, let votes {
                        Text(Self.shortCount(votes).lowercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                if hasViews, let views {
                    Text(Self.shortCount(views))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    /// Чип "иконка изображения + кол-во доп. обложек" — сверху справа на
    /// обложке (см. GET /manga/{slug}/covers, MangaDetailViewModel.coverGallery).
    /// Показывается только если обложек БОЛЬШЕ ОДНОЙ (при ровно одной чип не
    /// нужен — по прямой просьбе, хотя тап всё равно открывает её на весь
    /// экран, см. coverGalleryImageURLs). Тап по всей обложке (не только по
    /// чипу) открывает полноэкранную листалку — см. heroHeader.
    @ViewBuilder
    private var coverGalleryBadge: some View {
        if viewModel.coverGallery.count > 1 {
            HStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                Text("\(viewModel.coverGallery.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    /// Короткий формат числа: 2.43K, 1.2M (без хвостовых нулей).
    private static func shortCount(_ n: Int) -> String {
        func trim(_ v: Double) -> String {
            var s = String(format: "%.2f", v)
            if s.contains(".") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }
        switch n {
        case 1_000_000...: return trim(Double(n) / 1_000_000) + "M"
        case 1_000...:     return trim(Double(n) / 1_000) + "K"
        default:           return "\(n)"
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                // Максимум 2 строки + обрезка — чтобы длинное название не
                // раздувало баннер и не наезжало на элементы (обложка теперь
                // на фиксированной высоте, см. heroCoverTopOffset).
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let eng = viewModel.detail?.name ?? listItem?.name, eng != title {
                Text(eng).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }

            // Рейтинг перенесён на саму обложку (см. heroHeader.coverRatingBadge).
        }
        // Тап по названию открывает sheet со всеми названиями тайтла (русское/
        // оригинальное/английское/альтернативные) — см. TitleNamesSheet.
        // contentShape(Rectangle()) — чтобы тап ловился по всей области блока,
        // включая пустые промежутки между строками, а не только по буквам.
        .contentShape(Rectangle())
        .onTapGesture { showTitleNames = true }
    }

    // MARK: Info row (блоки Тип/Статус/Год/Просмотры/Формат)

    // Причина 422 (см. MangaNetworkService.fetchMangaDetail) найдена и
    // исправлена — теперь все 5 блоков реально приходят с сервера, поэтому
    // горизонтальный скролл снова уместен: без него 5 плашек просто не влезут
    // в ширину экрана. Стиль — тот же, что у полоски подкатегорий в
    // закладках (см. BookmarksView.categoryMenu): ScrollView(.horizontal) +
    // .scrollIndicators(.hidden), там это привычный, понятный пользователю
    // паттерн ("листай пальцем вбок").
    // Вернулись к чипам с подложкой (см. infoBlock) вместо App Store-стиля
    // с разделителями — как попросили. Разделители (верхняя полоска и
    // вертикальные линии между блоками) убраны совсем, между чипами теперь
    // обычный зазор.
    private var infoRow: some View {
        let rawItems: [(heading: String, value: String?)] = [
            (heading: "Тип", value: (viewModel.detail?.type ?? listItem?.type)?.label),
            (heading: "Статус", value: (viewModel.detail?.status ?? listItem?.status)?.label),
            (heading: "Год выпуска", value: viewModel.detail?.yearString),
            // Просмотры — 4-е место (сразу после года), как попросили.
            (heading: "Просмотры", value: viewModel.detail?.viewsString),
            (heading: "Формат", value: formatValue),
        ]
        let items: [(heading: String, value: String)] = rawItems.compactMap { item in
            guard let value = item.value, !value.isEmpty else { return nil }
            return (heading: item.heading, value: value)
        }

        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    infoBlock(item.heading, value: item.value)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var formatValue: String? {
        let labels = viewModel.detail?.formatLabels ?? []
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    // Высота чипа teamChip (см. ниже, раздел "Главы") — аватар 28pt +
    // вертикальный паддинг 8×2 = 44. Общая константа, чтобы чипы метаданных
    // и переводчиков совпадали по высоте пиксель в пиксель, а не примерно —
    // как попросили выровнять. fileprivate (не private) — нужна и в
    // TeamChipView ниже (отдельная struct в этом же файле, см. её объявление).
    fileprivate static let metaChipHeight: CGFloat = 44

    @ViewBuilder
    private func infoBlock(_ heading: String, value: String) -> some View {
        // Формат чипа — тот же, что у чипов "Жанры и теги" (см.
        // CollapsibleChips.chipView): .padding(.horizontal, 12), Capsule +
        // Theme.surfaceElevated + обводка Theme.separator. Высота — явно
        // Self.metaChipHeight (см. выше), а не паддинг по вертикали, чтобы
        // ровно совпадать с teamChip независимо от разницы в содержимом
        // (там одна строка + аватар, тут заголовок+значение в два ряда).
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    // MARK: Похожее (GET /manga/{slug}/similar, POST /similar/{id}/vote)

    /// Раздел "Похожее" — заголовок со стрелочкой вправо (чисто декоративная:
    /// отдельного эндпоинта "показать все похожие" в перехваченном API нет,
    /// весь список приходит одним запросом, см. MangaNetworkService.fetchSimilar
    /// — поэтому у стрелочки нет действия по нажатию) + горизонтальный слайдер
    /// карточек. Скрыт полностью, если список пуст (не грузится ещё/у тайтла
    /// нет похожих).
    @ViewBuilder
    private var similarSection: some View {
        if !viewModel.similar.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    blockTitle("Похожее")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }

                // GeometryReader — чтобы посчитать ширину карточки как долю
                // от РЕАЛЬНОЙ видимой ширины экрана (~60%, как попросили),
                // а не дать тексту растягивать карточку как попало (раньше
                // так и было — карточки получались разного размера в
                // зависимости от длины названия). Явная .frame(height:) на
                // самом GeometryReader обязательна — сам он высоту не знает,
                // без неё бы схлопнулся или растянулся на весь ScrollView.
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(viewModel.similar) { item in
                                similarCard(item, width: proxy.size.width * Self.similarCardWidthFraction)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(height: Self.similarCardHeight)
            }
        }
    }

    // MARK: Статистика (GET /manga/{slug}/stats)

    /// Виджет «Оценки пользователей» (распределение 10→1) + «В списках у N
    /// человек» (распределение по папкам). Скрыт, если статистики нет.
    @ViewBuilder
    private var statsSection: some View {
        if let stats = viewModel.stats,
           (stats.rating?.stats?.isEmpty == false) || (stats.bookmarks?.stats?.isEmpty == false) {
            VStack(alignment: .leading, spacing: 24) {
                ratingStatsBlock(stats.rating)
                bookmarkStatsBlock(stats.bookmarks)
            }
        }
    }

    /// Отзывы — ПОДТВЕРЖДЕНО перехватом `GET /reviews?reviewable_type=manga&
    /// reviewable_id=`, см. MangaReviewsView. Отдельным пушнутым экраном (не
    /// ещё одной вкладкой внутри и так большого MangaDetailView), тот же
    /// подход, что уже применён для Друзей/Коллекций/Списков в профиле.
    @ViewBuilder
    private var reviewsEntryRow: some View {
        if let mangaId = viewModel.detail?.id {
            NavigationLink {
                MangaReviewsView(mangaId: mangaId, mangaTitle: title, siteId: viewModel.resolvedSiteId)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.subheadline).foregroundStyle(Theme.accent)
                    Text("Отзывы").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func ratingStatsBlock(_ group: StatGroup?) -> some View {
        if let entries = group?.stats, !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    blockTitle("Оценки пользователей")
                    Spacer(minLength: 0)
                    if let r = viewModel.detail?.rating {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill").font(.subheadline).foregroundStyle(Theme.accent)
                            Text(r.average ?? r.averageFormated ?? "—")
                                .font(.headline).foregroundStyle(Theme.textPrimary)
                            if let v = r.votes {
                                Text(Self.shortCount(v)).font(.footnote).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                VStack(spacing: 9) {
                    ForEach(entries) { e in
                        statRow(leading: { ratingLeading(e.label) },
                                leadingWidth: 40,
                                percent: e.percent,
                                color: Self.ratingColor(for: e.label),
                                value: e.value)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bookmarkStatsBlock(_ group: StatGroup?) -> some View {
        if let entries = group?.stats, !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                blockTitle("В списках у \(group?.count ?? 0) человек")
                VStack(spacing: 9) {
                    ForEach(entries) { e in
                        statRow(leading: {
                            Text(e.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        },
                                leadingWidth: 96,
                                percent: e.percent,
                                color: Theme.accent,
                                value: e.value)
                    }
                }
            }
        }
    }

    /// Одна строка распределения: слева подпись (номер+звезда / название),
    /// далее полоса, справа процент и абсолютное число.
    private func statRow<Leading: View>(@ViewBuilder leading: () -> Leading,
                                        leadingWidth: CGFloat,
                                        percent: Double,
                                        color: Color,
                                        value: Int) -> some View {
        HStack(spacing: 10) {
            leading().frame(width: leadingWidth, alignment: .leading)
            statBar(percent: percent, color: color)
            Text(Self.percentString(percent))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 52, alignment: .trailing)
            Text("\(value)")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func ratingLeading(_ label: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func statBar(percent: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceElevated)
                Capsule().fill(color)
                    .frame(width: barWidth(total: geo.size.width, percent: percent))
            }
        }
        .frame(height: 7)
        .frame(maxWidth: .infinity)
    }

    private func barWidth(total: CGFloat, percent: Double) -> CGFloat {
        let p = min(max(percent, 0), 100) / 100
        let w = total * CGFloat(p)
        // Ненулевой процент показываем хотя бы тонкой полоской (как на сайте).
        return percent > 0 ? max(w, 5) : 0
    }

    private static func ratingColor(for label: String) -> Color {
        guard let score = Int(label) else { return Theme.accent }
        // 1 → оранжевый, 10 → зелёный (плавный переход по hue).
        let t = Double(min(max(score, 1), 10) - 1) / 9.0
        let hue = 0.03 + t * (0.33 - 0.03)
        return Color(hue: hue, saturation: 0.75, brightness: 0.85)
    }

    private static func percentString(_ p: Double) -> String {
        if p == p.rounded() { return "\(Int(p))%" }
        return String(format: "%.1f%%", p)
    }

    // MARK: Персонажи (GET /character?media_id=)

    /// Карусель персонажей — та же идея, что «Похожее»/«Связанное»: строка
    /// снизу, тап открывает экран персонажа. Скрыта, если персонажей нет.
    @ViewBuilder
    private var charactersSection: some View {
        if !viewModel.characters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                blockTitle("Персонажи")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(viewModel.characters) { ch in
                            characterCard(ch)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func characterCard(_ ch: Character) -> some View {
        NavigationLink {
            CharacterView(slugURL: ch.slugURL, fallbackName: ch.displayName, coverURL: ch.cover?.bestURL)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: ch.cover?.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: 104, height: 140)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(ch.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 104, alignment: .leading)

                if let pos = ch.positionLabel, !pos.isEmpty {
                    Text(pos)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 104, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Высота карточек "Похожее"/"Связанное" — обложка теперь занимает ВСЮ
    /// эту высоту, вплотную к левому/верхнему/нижнему краю подложки (как
    /// явно попросили: "увеличь обложку до размеров подложки, чтобы левый
    /// край подложки начинался с обложки").
    private static let similarCardHeight: CGFloat = 132
    /// Ширина обложки при этой высоте — та же пропорция 2:3, что у главной
    /// обложки тайтла в шапке (heroCoverSize, 88×132) — попросили привести
    /// к единому виду вместо прежних 80:112 (~5:7).
    private static let similarCoverWidth: CGFloat = similarCardHeight * 2 / 3
    /// Ширина карточки — доля от видимой ширины экрана. Изначально было 0.6
    /// ("по ширине примерно максимум 60% видимого экрана"), потом попросили
    /// увеличить на +20% (0.6 × 1.2 = 0.72) — фиксированная, не зависит от
    /// длины названия/подписи; всё, что не влезает (максимум 2 строки) —
    /// обрезается многоточием (см. .lineLimit(2) у Text ниже, truncation по
    /// умолчанию — хвостом, "...").
    private static let similarCardWidthFraction: CGFloat = 0.72

    /// Одна карточка "Похожего": обложка слева вплотную к краю (скруглена
    /// только с внешней стороны — левые углы), справа — текстовая колонка
    /// (СНАЧАЛА подпись-причина "Схож по жанрам и сюжету" ГОЛУБЫМ, НИЖЕ
    /// название тайтла, ещё ниже "Тип · Статус" — порядок и цвет поменяны по
    /// прямой просьбе), у правого края карточки — голосующая колонка "+/число/-".
    ///
    /// ВАЖНО: голосующая колонка — СОСЕД NavigationLink в общем HStack, а НЕ
    /// что-то вложенное внутрь его label и НЕ наложенное поверх через ZStack
    /// (так было раньше — не сработало, кнопки не были кликабельны). Теперь
    /// это физически отдельная область карточки, никак не перекрывающаяся с
    /// тап-зоной NavigationLink, поэтому конфликт жестов исключён полностью.
    ///
    /// Сама карточка — ссылка на карточку этого тайтла через прямой
    /// NavigationLink с destination (а НЕ value-based navigationDestination(for:)) —
    /// этот экран может быть открыт из разных стеков навигации (Каталог/
    /// Закладки/История), каждый регистрирует destination для СВОЕГО типа, и
    /// MangaDetailView заранее не знает, в каком именно стеке он сейчас
    /// показан, поэтому прямой destination-конструктор надёжнее.
    private func similarCard(_ item: SimilarItem, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                MangaDetailView(
                    slug: item.media.apiSlug, fallbackTitle: item.media.displayTitle,
                    coverURL: item.media.cover?.bestURL, item: item.media
                )
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    RemoteImage(url: item.media.cover?.bestURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        SkeletonBox()
                    } failure: {
                        ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
                    }
                    .frame(width: Self.similarCoverWidth, height: Self.similarCardHeight)
                    .clipped()
                    // Все 4 угла одинаково скруглены (было — только левые,
                    // вплотную к краю подложки) — как явно попросили.
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // .frame(maxWidth: .infinity) — КЛЮЧЕВОЕ: без него VStack
                    // растягивался под самый длинный текст (название/подпись),
                    // и карточки получались разной ширины. Теперь текстовая
                    // колонка получает РОВНО столько места, сколько осталось
                    // от фиксированной ширины карточки (width, см. ниже) — а
                    // всё, что не влезает в 2 строки (.lineLimit(2)), само
                    // обрезается многоточием (это поведение Text по умолчанию).
                    VStack(alignment: .leading, spacing: 4) {
                        if let reason = item.similar, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.cyan)
                                .lineLimit(2)
                        }

                        Text(item.media.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)

                        // Spacer ПЕРЕД "Тип · Статус" (а не после) — прижимает
                        // эту строку к самому низу подложки, а не оставляет
                        // пустое место под ней, как попросили.
                        Spacer(minLength: 0)

                        let typeStatus = [item.media.type?.label, item.media.status?.label]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                        if !typeStatus.isEmpty {
                            Text(typeStatus)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
            }
            .buttonStyle(.plain)

            // Отступ от текста до голосующей колонки чуть увеличен (было 8).
            similarVoteColumn(item)
                .padding(.leading, 14)
                .padding(.trailing, 10)
        }
        .frame(width: width, height: Self.similarCardHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Голосующая колонка справа: сверху "+", по центру число (чистый счёт
    /// up-down; зелёное если положительное, красное если отрицательное,
    /// серое ровно на 0), снизу "-" — порядок и положение по прямой просьбе
    /// ("должно быть скраю справа. выше + по середине число и ниже минус").
    private func similarVoteColumn(_ item: SimilarItem) -> some View {
        let score = item.votes.up - item.votes.down
        return VStack(spacing: 8) {
            voteSquareButton(symbol: "plus", isActive: item.votes.user == 1, activeColor: .green) {
                Task { await castSimilarVote(item, isUp: true) }
            }

            Text("\(score)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(score > 0 ? .green : (score < 0 ? .red : Theme.textSecondary))

            voteSquareButton(symbol: "minus", isActive: item.votes.user == 0, activeColor: .red) {
                Task { await castSimilarVote(item, isUp: false) }
            }
        }
    }

    /// Квадрат со скруглёнными углами вокруг "+"/"-" — лёгкая заливка цветом
    /// (~15% непрозрачности), ТОЛЬКО когда это ТЕКУЩИЙ голос пользователя
    /// (votes.user). Обводку (stroke) убрали по прямой просьбе — размер
    /// бокса (24×24, радиус 7) НЕ трогал, только саму рамку.
    private func voteSquareButton(symbol: String, isActive: Bool, activeColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(isActive ? activeColor : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? activeColor.opacity(0.15) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func castSimilarVote(_ item: SimilarItem, isUp: Bool) async {
        guard AuthSession.shared.isLoggedIn else {
            showLoginForSimilarVote = true
            return
        }
        await viewModel.voteSimilar(item, isUp: isUp)
    }

    // MARK: Связанное (GET /manga/{slug}/relations)

    /// Раздел "Связанное" — та же карусель, что и "Похожее" (см. similarSection),
    /// но БЕЗ голосов и БЕЗ стрелочки — попросили ровно так же оформить, но
    /// без плюса/минуса. Скрыт полностью, если связей нет (частый случай —
    /// "связанное может не отображаться, если его банально нет", как и
    /// предупредили).
    @ViewBuilder
    private var relatedSection: some View {
        if !viewModel.related.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                blockTitle("Связанное")

                // Тот же приём с GeometryReader, что и в similarSection —
                // фиксированная ширина карточки (~60% видимой ширины),
                // независимая от длины текста.
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(viewModel.related) { item in
                                relatedCard(item, width: proxy.size.width * Self.similarCardWidthFraction)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(height: Self.similarCardHeight)
            }
        }
    }

    /// Карточка "Связанного" — как similarCard (обложка во всю высоту
    /// подложки вплотную к краю, подпись-причина related_type.label ГОЛУБЫМ
    /// СВЕРХУ, название ниже), но без голосующей колонки — своего NavigationLink
    /// достаточно, вложенных кнопок тут нет и конфликт тап-жестов не грозит.
    private func relatedCard(_ item: RelatedItem, width: CGFloat) -> some View {
        NavigationLink {
            MangaDetailView(
                slug: item.media.apiSlug, fallbackTitle: item.media.displayTitle,
                coverURL: item.media.cover?.bestURL, item: item.media
            )
        } label: {
            HStack(alignment: .center, spacing: 10) {
                RemoteImage(url: item.media.cover?.bestURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: Self.similarCoverWidth, height: Self.similarCardHeight)
                .clipped()
                // Все 4 угла одинаково скруглены, как у similarCard.
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // .frame(maxWidth: .infinity) — та же причина, что и в
                // similarCard: без него карточки были бы разной ширины.
                VStack(alignment: .leading, spacing: 4) {
                    if let reason = item.relatedType?.label, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.cyan)
                            .lineLimit(2)
                    }

                    Text(item.media.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    // Spacer ПЕРЕД "Тип · Статус" — прижимает строку к самому
                    // низу подложки, как и в similarCard.
                    Spacer(minLength: 0)

                    let typeStatus = [item.media.type?.label, item.media.status?.label]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    if !typeStatus.isEmpty {
                        Text(typeStatus)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, height: Self.similarCardHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Action buttons

    // Нативные .bordered/.borderedProminent вместо стеклянных капсул — как
    // просили ("Добавить в" = серый bordered, "Начать/Продолжить" = заливка
    // акцентом). Обе кнопки растянуты поровну на всю ширину (50/50).
    private var actionButtons: some View {
        let progress = bookmarks.readingProgress(forSlug: viewModel.slug)
        return HStack(spacing: 8) {
            // Добавить в закладки — вместо общего "В закладках" показываем
            // РЕАЛЬНОЕ название текущей папки (Читаю/В планах/Брошено/
            // Прочитано/Любимые/кастомная), как попросили — тот же источник,
            // что и у bookmarkStatusBadge на обложке в heroHeader.
            let inList = bookmarks.isBookmarked(slug: viewModel.slug)
            let folderName = bookmarks.folderId(forSlug: viewModel.slug)
                .flatMap { id in bookmarks.allFolders.first(where: { $0.id == id })?.name }
            Button { showAddToFolder = true } label: {
                Label(inList ? (folderName ?? "В закладках") : "Добавить в", systemImage: inList ? "bookmark.fill" : "bookmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.bordered)
            .tint(inList ? Theme.accent : Theme.textSecondary)

            // Продолжить / Начать.
            if let target = viewModel.continueChapter(progress: progress), let progress {
                readerLink(chapter: target, label: "Продолжить \(progress.lastChapterNumber)/\(viewModel.totalChapters)")
            } else if let first = displayChapters.first {
                readerLink(chapter: first, label: "Начать")
            } else {
                // Раньше это был Text с ручным RoundedRectangle(10) — форма
                // отличалась от .borderedProminent-кнопки readerLink выше,
                // из-за чего при появлении глав кнопка визуально "прыгала"
                // из квадратной в обычную. Теперь тот же buttonStyle
                // (просто disabled + серый tint) — форма не меняется никогда.
                Button {} label: {
                    Text("Нет глав").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.surfaceElevated)
                .foregroundStyle(Theme.textSecondary)
                .disabled(true)
            }
        }
    }

    private func readerLink(chapter: ChapterItem, label: String) -> some View {
        Button {
            readerOpen = ReaderOpen(chapter: chapter, branchId: nil)
        } label: {
            Text(label)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private func readerView(for chapter: ChapterItem, branchId: Int?) -> some View {
        let chapters = displayChapters
        return MangaReaderView(
            slug: viewModel.slug,
            chapters: chapters,
            startIndex: max(chapters.firstIndex(where: { $0.id == chapter.id }) ?? 0, 0),
            // Numeric id тайтла — нужен для реальной отметки главы
            // просмотренной в аккаунте (см. ReaderViewModel.recordProgress).
            mangaId: viewModel.detail?.id ?? listItem?.id,
            mangaTitle: title,
            // Тип тайтла (Манга/Манхва/...) — определяет дефолт вписывания
            // страницы в читалке (см. MangaReaderView.defaultFitWidth).
            mangaTypeName: viewModel.detail?.type?.label ?? listItem?.type?.label,
            coverURL: coverURL?.absoluteString ?? listItem?.coverURLString,
            preferredBranchId: branchId,
            // Сайт тайтла — страницы главы с другого сайта тоже нужно грузить
            // с его Site-Id (см. ReaderViewModel.siteId).
            siteId: viewModel.resolvedSiteId
        )
    }

    // MARK: Tabs
    //
    // Плоские текстовые вкладки с подчёркиванием у активной вместо
    // стеклянных капсул — как просили.

    private var tabBar: some View {
        // Было: три вкладки поровну делят ширину (1/3 каждая) — из-за этого
        // "О тайтле" (короче) и "Комментарии" (длиннее) оказывались на
        // РАЗНОМ расстоянии от краёв экрана, хотя обе вкладки крайние (по
        // прямой жалобе — "разный зазор у О тайтлы и комментарии от углов").
        // Теперь вкладки — по естественной ширине текста, с фиксированным
        // зазором МЕЖДУ ними, а весь ряд центрируется целиком как один блок
        // (Spacer с обеих сторон снаружи) — "Главы NNNN" всегда в середине
        // этого блока, а расстояние от "О тайтле"/"Комментарии" до краёв
        // экрана теперь буквально одинаковое (не по совпадению, а потому что
        // Spacer слева и справа делят оставшееся место поровну), плюс сами
        // вкладки визуально ближе друг к другу, как и просили ("сблизить").
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                tabButton("О тайтле", .about)
                tabButton(displayChapters.isEmpty ? "Главы" : "Главы \(max(viewModel.totalChapters, displayChapters.count))", .chapters)
                tabButton("Комментарии", .comments)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let active = tab == value
        return Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { tab = value } } label: {
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 13)
                .overlay(alignment: .bottom) {
                    // Подчёркивание рисуется ТОЛЬКО у активной вкладки, но с
                    // общим matchedGeometryEffect(id:) — поэтому при смене
                    // вкладки SwiftUI не удаляет одну полоску и создаёт другую,
                    // а плавно "переезжает" ту же самую на новое место (анимация
                    // задаётся withAnimation в action кнопки ниже).
                    if active {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tabIndicator", in: tabIndicator)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .about:    aboutTab
        case .chapters: chaptersTab
        case .comments: commentsTab
        }
    }

    // MARK: Tab «О тайтле»

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Тип/Статус/Год/Просмотры/Формат — только здесь, во вкладке
            // «О тайтле», а не на всех вкладках (пробовали над вкладками —
            // попросили вернуть обратно). БЕЗ компенсирующего отступа сверху
            // (был -8pt, подгонявший зазор до 10pt) — teamChip в «Главах»
            // тоже первый элемент своего таба без компенсации, так что оба
            // ряда чипов теперь стоят на одном уровне под вкладками при
            // переключении между табами, как попросили выровнять.
            infoRow

            if viewModel.detail == nil && viewModel.isLoading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }

            // Автор/Художник(и)/Издатель(и) — ОДНА строка чипов НАД описанием
            // (по прямой просьбе). См. creditsRow.
            creditsRow

            if isBlockedByLicenseOrModeration {
                // "Нет глав" + подтверждённые маркеры (is_licensed/moderated,
                // см. MangaDetail.isBlockedByLicenseOrModeration) — вместо
                // обычного описания объясняем ПОЧЕМУ глав нет, как попросили.
                // Отступ заголовок→контент визуально меньше, чем 10pt у
                // similarSection/relatedSection/"Жанры и теги" — там под
                // заголовком идёт не-текстовый контент (карусель/чипы), а
                // здесь Text под Text, и встроенный line-height у обоих
                // складывается с VStack-отступом, из-за чего 10pt казались
                // заметно больше, чем в остальных блоках (попросили
                // выровнять на глаз).
                VStack(alignment: .leading, spacing: 6) {
                    blockTitle("Описание")
                    Label(
                        "Главы удалены по требованию правообладателя или роскомнадзора, либо тайтл находится на проверке.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }
            } else if let summary = viewModel.detail?.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    blockTitle("Описание")
                    // Максимум 4 строки + оранжевая "Подробнее.../Свернуть" —
                    // см. ExpandableDescription (показывается только если текст
                    // реально длиннее 4 строк).
                    ExpandableDescription(text: summary)
                }
            }

            // Жанры и теги объединены в один блок чипов (сначала жанры, потом
            // теги) — как попросили, вместо двух отдельных секций. Возрастной
            // рейтинг (см. ageRatingChip) — первым в списке, если это 18+/16+
            // (12+/6+/"Нет" не показываются вовсе — как попросили).
            // Жанры и теги — один блок, но по-разному: сначала жанры обычными
            // чипами (без префикса), затем теги, каждый с "#" (как хештег) —
            // как попросили. Возрастной рейтинг (ageRatingChip) по-прежнему
            // самым первым, если это 18+/16+.
            // Каждый жанр/тег кликабельный: тап открывает Каталог с фильтром по
            // нему (см. CatalogNavigator). Сортируем сущности по имени, сохраняя
            // их id для фильтра.
            let genreEntities = (viewModel.detail?.genres ?? []).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            let tagEntities = (viewModel.detail?.tags ?? []).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            let genreItems = genreEntities.map { g in
                CollapsibleChips.Item(text: g.name, onTap: {
                    CatalogNavigator.shared.openCatalog(filter: CatalogNavigator.genreFilter(id: g.id))
                })
            }
            let tagItems = tagEntities.map { t in
                CollapsibleChips.Item(text: "# \(t.name)", onTap: {
                    CatalogNavigator.shared.openCatalog(filter: CatalogNavigator.tagFilter(id: t.id))
                })
            }
            let chipItems = [ageRatingChip].compactMap { $0 } + genreItems + tagItems
            if !chipItems.isEmpty {
                // Тот же единый отступ 10pt заголовок→контент, что у
                // Описания/Похожего/Связанного.
                VStack(alignment: .leading, spacing: 10) {
                    blockTitle("Жанры и теги")
                    CollapsibleChips(items: chipItems)
                }
            }

            // Франшиза — ОТДЕЛЬНАЯ подкатегория ПОД "Жанры и теги" (по прямой
            // просьбе — раньше была вмешана первым чипом в тот же ряд, теперь
            // свой заголовок и свой блок), см. franchiseChip.
            if let franchiseChip {
                VStack(alignment: .leading, spacing: 10) {
                    blockTitle("Франшиза")
                    CollapsibleChips(items: [franchiseChip])
                }
            }

            // Порядок ниже — как явно попросили: Связанное ВСЕГДА выше
            // Похожего, оба опциональны и просто скрываются (см.
            // relatedSection/similarSection), если списки пустые.
            relatedSection
            similarSection
            charactersSection
            statsSection
            reviewsEntryRow

            if viewModel.detail == nil && !viewModel.isLoading {
                VStack(alignment: .leading, spacing: 10) {
                    // ВРЕМЕННО: показываем РЕАЛЬНЫЙ текст ошибки вместо
                    // захардкоженного "Не удалось загрузить описание." —
                    // используем detailErrorMessage (а не errorMessage,
                    // который пуст, если главы всё же загрузились) — чтобы
                    // наконец увидеть, что именно отвечает сервер (404 / 401 /
                    // таймаут / ошибка разбора JSON), а не гадать вслепую в
                    // очередной раз. Уберём после того, как найдём и починим
                    // настоящую причину.
                    Text(viewModel.detailErrorMessage ?? "Не удалось загрузить описание (причина неизвестна).")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tab «Главы»

    @ViewBuilder
    private var chaptersTab: some View {
        let chapters = displayChapters
        if chapters.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: viewModel.isLoading ? "hourglass" : "book.closed")
                    .font(.title2).foregroundStyle(Theme.textSecondary)
                Text(viewModel.isLoading ? "Загрузка глав…" : "Главы не найдены")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // Команды перевода тайтла — чипы сверху (аватар + имя + колокол),
                // тап открывает страницу переводчика (см. TeamView).
                let teams = allTeams
                if !teams.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(teams) { team in
                                if let slugURL = team.slugURL {
                                    NavigationLink {
                                        TeamView(slugURL: slugURL, fallbackName: team.name, coverURL: team.avatarURL)
                                    } label: {
                                        teamChip(team)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    teamChip(team)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                // Строка «Сортировать» (слева) + «К главе» (справа, если есть закладка).
                sortAndJumpRow(count: chapters.count)

                // Пока идёт скачивание — показываем прогресс над списком, а
                // справа — «Стоп»/«Возобновить» (см. downloadStopResumeButton).
                if let p = activeDownloadProgress {
                    let paused = downloads.isPaused(slug: viewModel.slug)
                    HStack(spacing: 10) {
                        if paused {
                            Image(systemName: "pause.circle").foregroundStyle(Theme.textSecondary)
                        } else {
                            ProgressView().tint(Theme.accent)
                        }
                        Text(paused ? "Пауза… \(p.completed)/\(p.total)" : "Главы качаются… \(p.completed)/\(p.total)")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        downloadStopResumeButton(paused: paused)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Порядок: по умолчанию новые сверху; «Сортировать» переключает.
                let sorted = chaptersNewestFirst ? Array(chapters.reversed()) : chapters
                // LazyVStack — при 300+ главах обычный VStack строит и
                // раскладывает ВСЕ строки сразу (весь экран — один общий
                // ScrollView), из-за чего скролл фризился тем сильнее, чем
                // больше глав. LazyVStack строит только то, что реально
                // попадает в область показа — ровно как в остальных списках
                // читалки (ChapterListSheet/ChapterCommentsSheet).
                LazyVStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, chapter in
                        chapterBlock(chapter)
                            .id(chapter.id) // для прокрутки по «К главе»
                        if index < sorted.count - 1 {
                            Divider().overlay(Theme.separator).padding(.leading, 14)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    /// Строка с кнопками «Сортировать» (⇅) и «К главе» (↓, только при закладке).
    private func sortAndJumpRow(count: Int) -> some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { chaptersNewestFirst.toggle() }
            } label: {
                chipLabel("Сортировать", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(.plain)

            Spacer()

            // «К главе» видна всегда, пока есть главы (раньше требовалась
            // сохранённая закладка/прогресс — по просьбе убрал это условие).
            if count > 0 {
                Menu {
                    ForEach(jumpTargets(count: count), id: \.pos) { target in
                        Button(target.label) { chapterScrollTarget = chapterId(atPosition: target.pos) }
                    }
                } label: {
                    chipLabel("К главе", systemImage: "arrow.down")
                }
            }
        }
    }

    /// «Стоп»/«Возобновить» у строки прогресса загрузки тайтла (chaptersTab) —
    /// пилюля с подложкой справа. На паузе — зелёная «Возобновить», иначе —
    /// обычная «Стоп». Пропадает вместе со всей строкой прогресса, когда
    /// загрузка реально завершится (см. activeDownloadProgress).
    private func downloadStopResumeButton(paused: Bool) -> some View {
        Button {
            if paused { downloads.resume(slug: viewModel.slug) }
            else { downloads.pause(slug: viewModel.slug) }
        } label: {
            Text(paused ? "Возобновить" : "Стоп")
                .font(.caption.weight(.semibold))
                .foregroundStyle(paused ? .green : Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    /// Точки прыжка «К главе»: 1, 50, 100, дальше +100, и «Конец» (ответ 1а).
    private func jumpTargets(count: Int) -> [(label: String, pos: Int)] {
        guard count > 0 else { return [] }
        var result: [(String, Int)] = []
        for base in [1, 50, 100] where base <= count { result.append(("Глава \(base)", base)) }
        var v = 200
        while v <= count { result.append(("Глава \(v)", v)); v += 100 }
        result.append(("Конец", count))
        return result
    }

    /// id главы на позиции pos (1-based, в порядке чтения: Глава 1 = позиция 1).
    private func chapterId(atPosition pos: Int) -> Int? {
        let chapters = displayChapters
        let idx = min(max(pos - 1, 0), max(chapters.count - 1, 0))
        return chapters.indices.contains(idx) ? chapters[idx].id : nil
    }

    /// Уникальные команды перевода по всем главам (для чипов сверху).
    private var allTeams: [ChapterTeam] {
        var seen = Set<Int>()
        var result: [ChapterTeam] = []
        for ch in displayChapters {
            for b in ch.branches ?? [] {
                for t in b.teams ?? [] where !seen.contains(t.id) {
                    seen.insert(t.id)
                    result.append(t)
                }
            }
        }
        return result
    }

    private func teamChip(_ team: ChapterTeam) -> some View {
        TeamChipView(team: team)
    }

    /// Блок одной главы: если у неё ≥2 веток (команд) — заголовок + под-строки
    /// по каждой ветке (команда/дата/скачать), как на сайте; иначе компактная
    /// строка (одна ветка/офлайн).
    @ViewBuilder
    private func chapterBlock(_ chapter: ChapterItem) -> some View {
        let branches = chapter.branches ?? []
        if branches.count >= 2 {
            VStack(alignment: .leading, spacing: 0) {
                chapterHeaderRow(chapter)
                ForEach(branches) { branch in
                    branchRow(chapter, branch)
                }
                Spacer().frame(height: 3)
            }
        } else {
            compactChapterRow(chapter, branchId: branches.first?.branchId)
        }
    }

    /// Заголовок главы (глазок + название) — без скачивания, оно у веток.
    private func chapterHeaderRow(_ chapter: ChapterItem) -> some View {
        HStack(spacing: 5) {
            Button { markReadUpTo(chapter) } label: {
                Image(systemName: isRead(chapter) ? "bookmark.fill" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(isRead(chapter) ? Theme.accent : Theme.textSecondary)
                    .frame(width: 20, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(chapter.displayTitle)
                .font(.subheadline)
                .foregroundStyle(chapterColor(chapter))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 2)
    }

    /// Под-строка ветки (команды): отступ-«дерево» + аватар + имя + дата + скачать.
    /// Тап читает именно эту ветку.
    private func branchRow(_ chapter: ChapterItem, _ branch: ChapterBranch) -> some View {
        Button {
            readerOpen = ReaderOpen(chapter: chapter, branchId: branch.branchId)
        } label: {
            HStack(spacing: 10) {
                // «Дерево»: вертикальная линия в фиксированной зоне-отступе, чтобы
                // имя команды вставало под названием главы, а края строк совпадали.
                // Зона остаётся 26pt (чтобы не сдвинуть аватар/имя), но сама
                // линия прижата к leading с отступом 9 — тогда её центр (14+10=24)
                // совпадает с центром глазка в chapterHeaderRow (тоже 14+10,
                // т.к. у него .frame(width: 20, ...)); раньше линия центрировалась
                // в зоне 26 и уезжала на 3pt правее глазка.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.separator)
                    .frame(width: 2, height: 20)
                    .padding(.leading, 9)
                    .frame(width: 26, alignment: .leading)

                RemoteImage(url: branch.teamAvatarURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.surfaceElevated)
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())

                Text(branch.teamName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let date = branch.dateString {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                chapterDownloadControl(chapter, branchId: branch.branchId)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Компактная строка главы (одна ветка/офлайн): глазок + название + дата + скачать.
    private func compactChapterRow(_ chapter: ChapterItem, branchId: Int?) -> some View {
        Button {
            readerOpen = ReaderOpen(chapter: chapter, branchId: branchId)
        } label: {
            HStack(spacing: 5) {
                Button { markReadUpTo(chapter) } label: {
                    Image(systemName: isRead(chapter) ? "bookmark.fill" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(isRead(chapter) ? Theme.accent : Theme.textSecondary)
                        .frame(width: 20, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(chapter.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(chapterColor(chapter))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let date = chapter.dateString {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                chapterDownloadControl(chapter, branchId: branchId)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isRead(_ chapter: ChapterItem) -> Bool {
        guard let p = bookmarks.readingProgress(forSlug: viewModel.slug) else { return false }
        return viewModel.position(of: chapter) <= p.readCount
    }

    // MARK: Скачанные главы (для отметки/оффлайна)

    /// Запись этого тайтла в загрузках (если он скачан хоть частично).
    private var downloadedEntry: DownloadedTitle? {
        downloads.titles.first(where: { $0.slug == viewModel.slug })
    }

    /// id скачанных глав — для зелёной отметки в списке.
    private var downloadedChapterIds: Set<Int> {
        Set(downloadedEntry?.chapters.map(\.id) ?? [])
    }

    /// Главы для показа/чтения: обычно из сети (полный список), но если сеть не
    /// дала список (например, зашли из «Загрузок» офлайн) — показываем хотя бы
    /// уже скачанные главы (из manifest), чтобы «в разделе Главы появлялось то,
    /// что скачано», и их можно было читать офлайн.
    private var displayChapters: [ChapterItem] {
        if !viewModel.chapters.isEmpty { return viewModel.chapters }
        return downloadedEntry?.chapterItems ?? []
    }

    private func isDownloaded(_ chapter: ChapterItem) -> Bool {
        downloadedChapterIds.contains(chapter.id)
    }

    /// Идёт ли прямо сейчас скачивание этого тайтла (см. DownloadsManager).
    private var activeDownloadProgress: DownloadsManager.Progress? {
        if let p = downloads.progress[viewModel.slug], !p.finished { return p }
        return nil
    }

    /// Есть ли вообще «контекст загрузки» — тайтл скачан (хотя бы частично) или
    /// качается сейчас. Только в этом случае красим главы серым/белым по факту
    /// скачанности; иначе (тайтл не качали) — всё как обычно, белым.
    private var hasDownloadContext: Bool {
        downloadedEntry != nil || activeDownloadProgress != nil
    }

    private func chapterColor(_ chapter: ChapterItem) -> Color {
        guard hasDownloadContext else { return Theme.textPrimary }
        return isDownloaded(chapter) ? Theme.textPrimary : Theme.textSecondary
    }

    /// Глазок/закладка слева: отметить прочитанными все главы ДО этой
    /// включительно (прогресс чтения). Тайтл при этом добавляется в «Читаю»,
    /// если его ещё нет в закладках (иначе прогресс некуда писать).
    ///
    /// `force: true` в setProgress — повторный тап на уже другую главу
    /// ПЕРЕСТАВЛЯЕТ закладку ровно на неё (в т.ч. назад: например, была
    /// глава 170, тапнули 166 — прогресс становится 166, и главы 167-170
    /// в списке возвращаются в непрочитанное состояние), а не только
    /// увеличивает счётчик, как это происходит при обычном чтении подряд.
    private func markReadUpTo(_ chapter: ChapterItem) {
        if !bookmarks.isBookmarked(slug: viewModel.slug) {
            bookmarks.add(
                slug: viewModel.slug, title: title,
                coverURL: coverURL?.absoluteString ?? listItem?.coverURLString,
                toFolder: BookmarkFolder.reading.id
            )
        }
        let pos = viewModel.position(of: chapter)
        bookmarks.setProgress(
            slug: viewModel.slug,
            chapterNumber: chapter.number, chapterVolume: chapter.volume,
            readCount: pos, total: displayChapters.count, force: true
        )

        // То же самое реальное подтверждение на сервере, что и при обычном
        // чтении главы (см. ReaderViewModel.recordProgress) — POST
        // .../view для выбранной главы, чтобы "продолжить чтение"
        // на сайте/в других клиентах тоже указывало на неё.
        if let mangaId = viewModel.detail?.id {
            Task {
                do {
                    try await MangaNetworkService.shared.markChapterViewed(mangaId: mangaId, chapterId: chapter.id, siteId: viewModel.resolvedSiteId)
                } catch {
                    print("[MangaDetailView] не удалось отметить главу просмотренной на сервере: \(error)")
                }
            }
        }
    }

    /// Контрол скачивания главы справа: серый значок «скачать» → кружок
    /// прогресса (заливается зелёным по %) → «…» с меню (размер / скачать ещё
    /// раз / удалить).
    @ViewBuilder
    private func chapterDownloadControl(_ chapter: ChapterItem, branchId: Int?) -> some View {
        let slug = viewModel.slug
        if downloads.isChapterDownloaded(slug: slug, chapterId: chapter.id, branchId: branchId) {
            Menu {
                Section("Размер: \(downloads.chapterSizeString(slug: slug, chapterId: chapter.id, branchId: branchId))") {
                    Button { redownloadChapter(chapter, branchId: branchId) } label: {
                        Label("Скачать ещё раз", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        downloads.deleteChapter(slug: slug, chapterId: chapter.id, branchId: branchId)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
        } else if let frac = downloads.chapterFraction(slug: slug, chapterId: chapter.id, branchId: branchId) {
            ZStack {
                Circle().stroke(Theme.separator, lineWidth: 2)
                Circle().trim(from: 0, to: max(0.02, frac))
                    .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            // Та же зона 28×30, что у кнопки "скачать"/меню "…" в соседних
            // ветках этого @ViewBuilder — иначе при смене состояния кружок
            // (20×20 без внешней зоны) съезжает на ~4pt относительно места,
            // где были иконки, и выглядит криво пришпиленным.
            .frame(width: 28, height: 30)
            .animation(.linear(duration: 0.15), value: frac)
        } else {
            Button { startChapterDownload(chapter, branchId: branchId) } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func startChapterDownload(_ chapter: ChapterItem, branchId: Int?) {
        downloads.downloadChapter(
            slug: viewModel.slug,
            title: title,
            typeLabel: viewModel.detail?.type?.label ?? listItem?.type?.label,
            coverURLString: (viewModel.detail?.cover?.bestURL ?? coverURL ?? listItem?.cover?.bestURL)?.absoluteString,
            heroURLString: viewModel.detail?.backgroundURL?.absoluteString,
            chapter: chapter,
            branchId: branchId
        )
    }

    private func redownloadChapter(_ chapter: ChapterItem, branchId: Int?) {
        downloads.deleteChapter(slug: viewModel.slug, chapterId: chapter.id, branchId: branchId)
        startChapterDownload(chapter, branchId: branchId)
    }

    // MARK: Tab «Комментарии»
    //
    // GET/POST /comments — ПОДТВЕРЖДЕНО реальным перехватом (см. файлы
    // "comments.txt"/"comments Отправка.txt" и комментарии у
    // MangaNetworkService.fetchComments/postComment). Голосование ("Жалоба",
    // сами стрелочки вверх/вниз как КНОПКИ) — эндпоинт НЕ подтверждён нигде,
    // поэтому счётчик голосов только ОТОБРАЖАЕТСЯ (реальные данные с
    // сервера), а не позволяет голосовать — честнее, чем притворяться, что
    // тап что-то реально отправляет.

    private var commentsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if commentsDisabledOnCard {
                // Комментарии отключены на карточке — акцентный текст + «Настроить».
                HStack(spacing: 12) {
                    Text("Вы отключили комментарии")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 8)
                    Button { showCommentSettings = true } label: {
                        Text("Настроить")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
            } else {
                stickyCommentCard
                commentsHeader
                composeBar

                if viewModel.isLoadingComments && viewModel.comments.isEmpty {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, minHeight: 100)
                } else if let error = viewModel.commentsError, viewModel.comments.isEmpty {
                    commentsErrorState(error)
                } else if viewModel.comments.isEmpty && viewModel.hasLoadedComments {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                        Text("Пока нет комментариев").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    commentsList
                }
            }
        }
        .task { if !commentsDisabledOnCard { await viewModel.loadCommentsIfNeeded() } }
        // Тап по любому "пустому" месту вкладки — свернуть клавиатуру, если
        // сейчас пишем комментарий/подпись спойлера (см. composeBar). Кнопки/
        // текстфилды сами уже занимают приоритет (это ловит только тапы МИМО
        // них — обычное поведение вложенных SwiftUI-жестов), заново открыть
        // клавиатуру можно тапом по самому полю ввода.
        .contentShape(Rectangle())
        .onTapGesture {
            if commentFieldFocused { commentFieldFocused = false }
        }
        .sheet(isPresented: $showCommentSettings) {
            CommentSettingsSheet(
                disabledInReader: $commentsDisabledInReader,
                disabledOnCard: $commentsDisabledOnCard,
                collapseFromLevel: $collapseFromLevel
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("Жалобы скоро появятся", isPresented: $showReportComingSoon) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("Отправка жалоб на комментарии пока не реализована.")
        }
        .alert("Ссылка скопирована", isPresented: $showCommentLinkCopied) {
            Button("Понятно", role: .cancel) {}
        }
        .alert("Игнор-лист", isPresented: Binding(
            get: { showIgnoreResult != nil },
            set: { if !$0 { showIgnoreResult = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(showIgnoreResult ?? "")
        }
    }

    /// Ссылка на конкретный комментарий — вида .../manga/{slug}?section=
    /// comments&comment_id={id} (формат из примера пользователя). Хост берём
    /// по фактическому сайту тайтла (resolvedSiteId), а не активному в меню —
    /// комментарий мог быть открыт на карточке с другого сайта, чем выбран
    /// сейчас глобально.
    private func commentLink(_ comment: Comment) -> String {
        let host = LibSite(rawValue: viewModel.resolvedSiteId ?? 0)?.host ?? SiteSession.shared.activeSite.host
        return "https://\(host)/ru/manga/\(viewModel.slug)?section=comments&comment_id=\(comment.id)"
    }

    /// "•••" рядом с "Ответить"/"Жалоба" — "Ссылка на комментарий" (копирует
    /// commentLink в буфер) и "Добавить в игнор лист" (см.
    /// MangaNetworkService.addToIgnoreList — эндпоинт не подтверждён
    /// перехватом, поэтому честно показываем ошибку, если сервер её вернёт).
    @ViewBuilder
    private func commentMenu(_ comment: Comment) -> some View {
        Menu {
            Button {
                UIPasteboard.general.string = commentLink(comment)
                showCommentLinkCopied = true
            } label: {
                Label("Ссылка на комментарий", systemImage: "link")
            }

            if let authorId = comment.author?.id, authorId > 0, authorId != AuthSession.shared.userId {
                Button {
                    guard AuthSession.shared.isLoggedIn else { showLoginForComment = true; return }
                    Task { await addToIgnoreList(userId: authorId) }
                } label: {
                    Label("Добавить в игнор лист", systemImage: "eye.slash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
        }
    }

    private func addToIgnoreList(userId: Int) async {
        do {
            try await MangaNetworkService.shared.addToIgnoreList(userId: userId)
            showIgnoreResult = "Пользователь добавлен в игнор-лист."
        } catch {
            showIgnoreResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// "Популярные/Старые/Новые" (меню сортировки) + "Настройки" (sheet) —
    /// над полем ввода, как попросили.
    private var commentsHeader: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Сортировка", selection: Binding(
                    get: { viewModel.commentSort },
                    set: { newValue in Task { await viewModel.changeCommentSort(newValue) } }
                )) {
                    ForEach(CommentSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } label: {
                // Обычная непрозрачная пилюля (Theme.surfaceElevated), как у
                // остальных чипов карточки (infoBlock/жанры) — не стекло.
                Label(viewModel.commentSort.title, systemImage: "arrow.up.arrow.down")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.pillControlHeight)
                    .background(Theme.surfaceElevated, in: Capsule())
            }

            Spacer(minLength: 0)

            Button { showCommentSettings = true } label: {
                Label("Настройки", systemImage: "slider.horizontal.3")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.pillControlHeight)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
        }
    }

    /// Поле ввода нового комментария (или ответа — см. replyingTo) — видно
    /// только авторизованным (см. AuthSession); иначе кнопка предлагает
    /// войти, как и остальные авторизацией-зависимые действия в приложении.
    @ViewBuilder
    private var composeBar: some View {
        if AuthSession.shared.isLoggedIn {
            VStack(alignment: .leading, spacing: 6) {
                if let replyingTo {
                    HStack(spacing: 6) {
                        Text("Ответ \(replyingTo.author?.username ?? "аноним")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                        Button { self.replyingTo = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                // Высота и вертикальное центрирование строки — как у чипов
                // «Сортировать»/«К главе» (см. chipLabel, minHeight 34) на
                // вкладке глав того же тайтла: центр по HStack + стрелка
                // зажата в те же 34pt, а не «плавает» по своей intrinsic-высоте.
                HStack(alignment: .center, spacing: 8) {
                    TextField(spoilerMode ? "Скрытый текст спойлера..." : "Написать комментарий...",
                              text: $commentDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .focused($commentFieldFocused)

                    let trimmed = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button {
                        let text = commentDraft
                        let label = spoilerMode ? spoilerLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                        let parent = replyingTo
                        commentDraft = ""
                        replyingTo = nil
                        spoilerMode = false
                        commentFieldFocused = false
                        Task {
                            let ok = await viewModel.postComment(text: text, spoilerLabel: label, replyingTo: parent)
                            if !ok { commentDraft = text }
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(trimmed.isEmpty ? Theme.textSecondary : Theme.accent)
                    }
                    .frame(width: 34, height: 34)
                    .disabled(trimmed.isEmpty || viewModel.isPostingComment)
                }

                // Панель форматирования — пока только спойлер (см.
                // MangaNetworkService.postComment(spoilerLabel:)). Тап по
                // иконке "разворачивает вниз" поле подписи спойлера (по
                // прямой просьбе), сам комментарий целиком уходит спойлером.
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { spoilerMode.toggle() }
                    } label: {
                        Image(systemName: spoilerMode ? "eye.slash.fill" : "eye.slash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(spoilerMode ? Theme.accent : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)

                if spoilerMode {
                    TextField("Подпись спойлера", text: $spoilerLabelDraft)
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 30)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .focused($commentFieldFocused)
                }
            }
        } else {
            Button { showLoginForComment = true } label: {
                Label("Войдите, чтобы оставить комментарий", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
        }
    }

    /// Закреплённый командой перевода/модератором комментарий (см.
    /// MangaNetworkService.fetchStickyComment) — своя карточка НАД обычной
    /// лентой, только булавка сверху-справа (по прямой просьбе убрали
    /// подпись "Закреплённый комментарий" — .overlay, а не отдельный ряд в
    /// layout, чтобы не оставалось пустой строки над комментарием).
    @ViewBuilder
    private var stickyCommentCard: some View {
        if let sticky = viewModel.stickyComment {
            commentRow(sticky)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .rotationEffect(.degrees(45))
                        .foregroundStyle(Theme.accent)
                        .padding(10)
                }
        }
    }

    /// Дерево комментариев, построенное из плоского списка (см.
    /// Comment.groupedByParent). "Популярные" — клиентская пересортировка
    /// корней и каждой группы ответов по score (сервер сортировку по
    /// популярности не подтверждён что умеет, см. MangaDetailViewModel).
    private var commentsList: some View {
        let grouped = viewModel.comments.groupedByParent()
        // Порядок корней теперь задаёт СЕРВЕР (Новые/Старые/Популярные —
        // votes_up/desc), клиентская пересортировка больше не нужна.
        let roots = grouped[0] ?? []
        return LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(roots) { root in
                // Один блок (карточка) на КОРНЕВОЙ комментарий целиком, вместе
                // со ВСЕМИ его ответами любой глубины (см. commentNode — они
                // строятся рекурсивно внутри одного и того же VStack). Другой,
                // не связанный корневой комментарий — уже отдельная карточка.
                // Раньше карточка/фон был у КАЖДОГО отдельного комментария
                // (см. commentRow) — из-за этого ответы визуально не читались
                // как единый тред с родителем, а выглядели как россыпь
                // независимых карточек.
                commentNode(root, grouped: grouped)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onAppear {
                        guard root.id == roots.last?.id else { return }
                        Task { await viewModel.loadMoreCommentsIfNeeded(currentComment: root) }
                    }
            }
            if viewModel.isLoadingComments && !viewModel.comments.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
    }

    /// Один узел дерева: сам комментарий + (если есть и не свёрнуты) его
    /// ответы рекурсивно ниже.
    ///
    /// Возвращает AnyView, а НЕ `some View` — commentNode вызывает САМ СЕБЯ
    /// (рекурсивно строит ответы на ответы), а непрозрачный тип `some View`
    /// принципиально не может быть рекурсивным: компилятор обязан вывести
    /// ОДИН конкретный тип для "some View", но при самовызове этот тип
    /// оказывается выражен через самого себя — отсюда ошибка сборки
    /// "opaque type was inferred as ..., which defines the opaque type in
    /// terms of itself" (и цепная реакция той же ошибки во всех вызывающих
    /// местах выше по цепочке: commentsList → commentsTab → body).
    /// AnyView стирает конкретный тип, разрывая эту рекурсию — стандартный,
    /// единственный способ сделать рекурсивную SwiftUI-вью.
    /// `forceExpanded` — унаследовано от родителя: если ХОТЬ ОДИН предок по
    /// цепочке уже был явно развёрнут (см. кнопку "Ещё комментарии" ниже),
    /// весь поддерево под ним считается развёрнутым СРАЗУ на всю глубину, а
    /// не только на один уровень — раньше при глубокой вложенности каждый
    /// следующий уровень заново упирался в collapseFromLevel и показывал
    /// СВОЮ кнопку "Ещё комментарии", так что до конца ветки приходилось
    /// нажимать её по одному разу на каждый уровень (по прямой жалобе).
    private func commentNode(_ comment: Comment, grouped: [Int: [Comment]], forceExpanded: Bool = false) -> AnyView {
        // Было children.sort{...} (мутирующий вызов, возвращает Void) — внутри
        // @ViewBuilder-контекста это ломало компиляцию отдельно от проблемы
        // выше; заменено на .sorted (не мутирует, обычное присваивание).
        let children: [Comment] = {
            let arr = grouped[comment.id] ?? []
            return viewModel.commentSort == .popular ? arr.sorted { $0.score > $1.score } : arr
        }()
        let expandedHere = forceExpanded || expandedThreads.contains(comment.id)

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                commentRow(comment)

                if !children.isEmpty {
                    // Сворачиваем ответы по умолчанию, если их СОБСТВЕННЫЙ уровень
                    // вложенности достиг порога из настроек (см. collapseFromLevel) —
                    // если пользователь уже разворачивал ЭТУ ветку (или любого её
                    // предка) вручную, не сворачиваем снова (см. expandedHere).
                    if let firstLevel = children.first?.commentLevel,
                       Double(firstLevel) >= collapseFromLevel, !expandedHere {
                        // Показывает ВСЕ уже загруженные ответы этой ветки разом,
                        // причём СРАЗУ на всю глубину (см. forceExpanded выше) —
                        // без парной кнопки "Скрыть" после (по прямой просьбе,
                        // однонаправленно, как и было).
                        // Тот же HStack(threadBars + spacing 8), что и в
                        // commentRow — гарантирует, что подпись встанет РОВНО
                        // под тем же левым краем, что и "Показать полностью"
                        // внутри самого комментария (а не под threadBars, как
                        // было раньше с произвольным padding 28).
                        HStack(spacing: 8) {
                            threadBars(comment.commentLevel)
                            Button {
                                expandedThreads.insert(comment.id)
                            } label: {
                                Text("Ещё комментарии (\(children.count))")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(children) { child in
                                // Тонкая линия-разделитель между соседними
                                // комментариями ВНУТРИ одного блока (см.
                                // commentsList) — теперь у отдельного
                                // комментария нет своей карточки (см.
                                // commentRow), поэтому нужна хоть какая-то
                                // визуальная граница между "текст родителя" и
                                // "текст ответа", раз они в одном фоне.
                                Divider().overlay(Theme.separator)
                                commentNode(child, grouped: grouped, forceExpanded: expandedHere)
                            }
                        }
                    }
                }
            }
        )
    }

    /// Вертикальные полоски-индикаторы треда слева от комментария — теперь
    /// РОВНО commentLevel полосок (было commentLevel+1): у корневого
    /// комментария (level 0) полосок вообще нет, у первого ответа (level 1) —
    /// одна, у ответа на ответ (level 2) — две и т.д., как явно попросили
    /// ("на родительском (первом) комментарии не должно быть полоски. а на
    /// ответах да должны быть").
    @ViewBuilder
    private func threadBars(_ level: Int) -> some View {
        if level > 0 {
            HStack(spacing: 4) {
                ForEach(0..<level, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.separator)
                        .frame(width: 2)
                }
            }
        }
    }

    private func commentRow(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            threadBars(comment.commentLevel)

            VStack(alignment: .leading, spacing: 8) {
                // Шапка: аватарка + ник/время СПРАВА от неё, выровненные по
                // центру относительно высоты аватарки (а не по верху, как
                // раньше) — как попросили. Сам текст комментария — НЕ здесь
                // (раньше был справа от аватарки, в одной колонке с ником),
                // а отдельным блоком НИЖЕ, во всю ширину, начинающимся от
                // того же левого края, что и аватарка (см. ниже).
                Button {
                    if let uid = comment.author?.id, uid > 0 { profileUser = ProfileUserId(id: uid) }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        RemoteImage(url: comment.author?.avatarURL.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Theme.surfaceElevated)
                        } failure: {
                            Circle().fill(Theme.surfaceElevated).overlay(
                                Image(systemName: "person.fill").font(.footnote).foregroundStyle(Theme.textSecondary)
                            )
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(comment.author?.username ?? "Аноним")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            if let date = comment.date {
                                // Русский относительный формат ОДНОЙ единицей
                                // ("5 дней назад", "7 часов назад") вместо
                                // системного Text(date, style: .relative)
                                // (показывал по-английски и/или комбинировал
                                // единицы вроде "3 дня 17 часов") — как попросили.
                                Text(date.relativeRussianString)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                // Спойлеры (см. Comment.segments) — свои чипы вместо
                // обычного текста; без них — старое поведение целиком
                // ("Показать полностью" НАД рядом Ответить/Жалоба/голоса).
                CommentBodyView(comment: comment)

                // Низ сообщения: "Ответить"/"Жалоба"/"•••" вместе слева,
                // счётчик голосов (▲ число ▼) справа — по прямой просьбе
                // выровнять первые три рядом друг с другом (раньше "Жалоба"
                // с "•••" были прижаты к голосам справа, а "Ответить" —
                // отдельно слева).
                HStack(spacing: 16) {
                    Button { replyingTo = comment } label: {
                        Text("Ответить").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button { showReportComingSoon = true } label: {
                        Text("Жалоба").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    commentMenu(comment)

                    Spacer(minLength: 0)

                    // Реальное голосование (эндпоинт подтверждён). Плюс/минус —
                    // кнопки; активный голос подсвечивается; без входа — предложить войти.
                    HStack(spacing: 5) {
                        Button {
                            if AuthSession.shared.isLoggedIn { Task { await viewModel.voteComment(comment, isUp: true) } }
                            else { showLoginForComment = true }
                        } label: {
                            Image(systemName: comment.userVote == 1 ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                                .font(.system(size: 11))
                                .foregroundStyle(comment.userVote == 1 ? .green : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Text("\(comment.score)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(commentScoreColor(comment.score))

                        Button {
                            if AuthSession.shared.isLoggedIn { Task { await viewModel.voteComment(comment, isUp: false) } }
                            else { showLoginForComment = true }
                        } label: {
                            Image(systemName: comment.userVote == 0 ? "arrowtriangle.down.fill" : "arrowtriangle.down")
                                .font(.system(size: 11))
                                .foregroundStyle(comment.userVote == 0 ? .red : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // Раньше здесь был .padding(12).background(Theme.surface, in:
        // RoundedRectangle...) — у КАЖДОГО отдельного комментария была своя
        // карточка. Теперь карточка одна на весь тред (корень + все ответы,
        // см. commentsList), поэтому отдельная строка комментария больше не
        // рисует свой фон — иначе ответы визуально не читались бы как часть
        // одного блока с родителем.
    }

    /// >0 зелёным, <0 красным, 0 нейтральным — как попросили.
    private func commentScoreColor(_ score: Int) -> Color {
        if score > 0 { return .green }
        if score < 0 { return .red }
        return Theme.textSecondary
    }

    private func commentsErrorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
            Button {
                Task { await viewModel.loadComments() }
            } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // MARK: Helpers

    private func blockTitle(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(Theme.textPrimary)
    }

    private func sortedNames(_ entities: [NamedEntity]?) -> [String] {
        (entities ?? []).map(\.name).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// "Нет глав" (виден пустой список chapters, уже загружено, не в
    /// процессе загрузки) + подтверждённые маркеры лицензии/модерации (см.
    /// MangaDetail.isBlockedByLicenseOrModeration) — тогда вместо описания
    /// показываем текст-объяснение, см. aboutTab.
    private var isBlockedByLicenseOrModeration: Bool {
        guard let detail = viewModel.detail, viewModel.chapters.isEmpty, !viewModel.isLoading else { return false }
        return detail.isBlockedByLicenseOrModeration
    }

    /// Чип франшизы — своя ОТДЕЛЬНАЯ подкатегория под "Жанры и теги" (см. её
    /// использование в aboutTab), не вмешан в общий ряд чипов жанров/тегов.
    /// Акцентный цвет (не как обычный жанр и не как тег с "#"), тап пушит
    /// FranchiseView (см. franchiseTarget/navigationDestination в body).
    /// Требует fields[]=franchise (см. MangaDetail.franchise).
    private var franchiseChip: CollapsibleChips.Item? {
        guard let ref = viewModel.detail?.franchise else { return nil }
        return .init(text: ref.name, tint: Theme.accent, onTap: { franchiseTarget = ref })
    }

    /// Один общий ряд Автор/Художник(и)/Издатель(и) НАД описанием (по прямой
    /// просьбе). Если автор и художник — ОДИН И ТОТ ЖЕ человек (совпадающий
    /// набор id, обычно один автор-иллюстратор), показываем ОДИН
    /// объединённый чип "Автор и Художник" без листа выбора — тап сразу
    /// пушит его карточку (см. MergedCreditsChip). Иначе — отдельные группы
    /// (см. CreditsChip): у каждой всегда есть лист выбора (даже если внутри
    /// один человек — для единообразия поведения), у издательства — своя,
    /// никогда не объединяется с автором/художником.
    @ViewBuilder
    private var creditsRow: some View {
        let authors = viewModel.detail?.authors ?? []
        let artists = viewModel.detail?.artists ?? []
        let publishers = viewModel.detail?.publisher ?? []
        let authorIds = Set(authors.map(\.id))
        let artistIds = Set(artists.map(\.id))
        let sameSinglePerson = authors.count == 1 && authorIds == artistIds

        if !authors.isEmpty || !artists.isEmpty || !publishers.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if sameSinglePerson, let person = authors.first {
                        MergedCreditsChip(person: person)
                    } else {
                        if !authors.isEmpty {
                            CreditsChip(people: authors, kind: .people, sheetTitle: authors.count == 1 ? "Автор" : "Авторы")
                        }
                        if !artists.isEmpty {
                            CreditsChip(people: artists, kind: .people, sheetTitle: artists.count == 1 ? "Художник" : "Художники")
                        }
                    }
                    if !publishers.isEmpty {
                        CreditsChip(people: publishers, kind: .publisher, sheetTitle: publishers.count == 1 ? "Издательство" : "Издатели")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Чип возрастного рейтинга для блока "Жанры и теги" — как попросили:
    /// 18+ красным (текст + обводка), 16+ таким же образом оранжевым, а
    /// 12+/6+/"Нет"/отсутствие рейтинга вообще не показываются (nil).
    /// Показывается сразу после чипа франшизы (см. franchiseChip выше) — см.
    /// aboutTab, где он идёт перед genres+tags.
    private var ageRatingChip: CollapsibleChips.Item? {
        guard let label = viewModel.detail?.ageRestriction?.label else { return nil }
        let digits = label.prefix { $0.isNumber }
        switch digits {
        case "18": return .init(text: label, tint: .red)
        case "16": return .init(text: label, tint: .orange)
        default: return nil // 12+, 6+, "Нет" и т.п. — не показываем.
        }
    }
}

/// Чип команды перевода в списке глав — аватар + имя + колокольчик подписки.
/// Отдельная struct (не просто @ViewBuilder-функция, как раньше) — колокольчику
/// нужно своё локальное состояние (подписан/грузится).
///
/// Колокольчик — РЕАЛЬНАЯ подписка, не заглушка: `POST /favorites
/// {source_id, source_type:"team"}` — ПОДТВЕРЖДЕНО перехватом, toggle
/// работает в обе стороны (повторным перехватом подтверждена и отписка).
/// Стартовое состояние при появлении чипа подтягивается реальным
/// `GET /favorites/team/{id}` (см. .task ниже) — тоже ПОДТВЕРЖДЕНО
/// перехватом, больше не "всегда стартует не подписан".
struct TeamChipView: View {
    let team: ChapterTeam

    @State private var isSubscribed = false
    @State private var isToggling = false

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: team.avatarURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Theme.surface)
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            Text(team.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Button { toggle() } label: {
                Group {
                    if isToggling {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: isSubscribed ? "bell.fill" : "bell")
                    }
                }
                .font(.caption)
                .foregroundStyle(isSubscribed ? Theme.accent : Theme.textSecondary)
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(isToggling)
        }
        .padding(.horizontal, 10)
        .frame(height: MangaDetailView.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
        .task {
            // Реальный стартовый статус — ПОДТВЕРЖДЕНО перехватом
            // GET /favorites/team/{id} (см. MangaNetworkService.fetchFavoriteStatus).
            guard let result = try? await MangaNetworkService.shared.fetchFavoriteStatus(sourceId: team.id, sourceType: "team") else { return }
            isSubscribed = result.isSubscribed
        }
    }

    private func toggle() {
        guard !isToggling else { return }
        isToggling = true
        Task {
            do {
                let result = try await MangaNetworkService.shared.toggleFavorite(sourceId: team.id, sourceType: "team")
                isSubscribed = result.isSubscribed
            } catch {
                // Тихо игнорируем — колокольчик просто останется в прежнем состоянии.
            }
            isToggling = false
        }
    }
}

/// Круглый аватар для чипов Автор/Художник/Издатель (см. MergedCreditsChip/
/// CreditsChip/CreditsSheet ниже) — реальная обложка человека/издательства
/// (DirectoryEntity.coverURL), тот же RemoteImage, что и везде.
private func creditsAvatar(_ url: URL?, size: CGFloat) -> some View {
    RemoteImage(url: url) { image in
        image.resizable().scaledToFill()
    } placeholder: {
        Circle().fill(Theme.surface)
    } failure: {
        Circle().fill(Theme.surface).overlay(
            Image(systemName: "person.fill").font(.caption2).foregroundStyle(Theme.textSecondary)
        )
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
}

/// Автор и художник — ОДИН И ТОТ ЖЕ человек (см. MangaDetailView.creditsRow) —
/// один чип БЕЗ листа выбора, тап сразу пушит его карточку.
private struct MergedCreditsChip: View {
    let person: DirectoryEntity

    var body: some View {
        NavigationLink {
            DirectoryDetailView(kind: .people, slugURL: person.slugURL, fallbackName: person.displayName, coverURL: person.coverURL)
        } label: {
            HStack(spacing: 8) {
                creditsAvatar(person.coverURL, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("Автор и художник")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Группа (Авторы/Художники/Издатели) — до двух аватарок внахлёст + имена
/// через "&", "+N" если людей больше двух ("если 2 всего — без +1", по
/// прямой просьбе), а под именами — подпись роли (sheetTitle: "Автор"/
/// "Авторы"/"Художник"/"Художники"/"Издательство"/"Издатели"), по аналогии
/// с "Автор и художник" у MergedCreditsChip (раньше была только ник/имя без
/// подписи роли). Тап ВСЕГДА открывает лист со всеми (даже если человек
/// один — единообразное поведение, по прямой просьбе "лист всегда").
private struct CreditsChip: View {
    let people: [DirectoryEntity]
    let kind: DirectoryKind
    let sheetTitle: String

    @State private var showSheet = false

    private var shown: [DirectoryEntity] { Array(people.prefix(2)) }
    private var remaining: Int { people.count - shown.count }

    var body: some View {
        Button { showSheet = true } label: {
            HStack(spacing: 8) {
                avatarsStack
                VStack(alignment: .leading, spacing: 0) {
                    Text(namesLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(sheetTitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            CreditsSheet(title: sheetTitle, people: people, kind: kind)
        }
    }

    private var avatarsStack: some View {
        HStack(spacing: -10) {
            ForEach(Array(shown.enumerated()), id: \.offset) { idx, person in
                creditsAvatar(person.coverURL, size: 28)
                    .overlay(Circle().stroke(Theme.surfaceElevated, lineWidth: 2))
                    .zIndex(Double(shown.count - idx))
            }
        }
    }

    private var namesLabel: String {
        let names = shown.map(\.displayName).joined(separator: " & ")
        return remaining > 0 ? "\(names) +\(remaining)" : names
    }
}

/// Лист выбора одного из группы (Авторы/Художники/Издатели) — та же сетка в
/// 2 колонки, что и TeamMembersSheet (участники команды), тап пушит
/// DirectoryDetailView.
private struct CreditsSheet: View {
    let title: String
    let people: [DirectoryEntity]
    let kind: DirectoryKind

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(people) { person in
                        NavigationLink {
                            DirectoryDetailView(kind: kind, slugURL: person.slugURL, fallbackName: person.displayName, coverURL: person.coverURL)
                        } label: {
                            personCell(person)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
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
    }

    private func personCell(_ person: DirectoryEntity) -> some View {
        HStack(spacing: 8) {
            creditsAvatar(person.coverURL, size: 28)
            Text(person.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated, in: Capsule())
    }
}

#Preview {
    NavigationStack {
        MangaDetailView(slug: "example", fallbackTitle: "Пример манги")
    }
    .preferredColorScheme(.dark)
}
