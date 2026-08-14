import SwiftUI
import UIKit

/// Экран тайтла: шапка, инфо-строка, кнопки, вкладки (О тайтле / Главы / Комментарии).
struct MangaDetailView: View {

    @StateObject private var viewModel: MangaDetailViewModel
    @ObservedObject private var bookmarks = BookmarksStore.shared
    @ObservedObject private var downloads = DownloadsManager.shared
    @Environment(\.dismiss) private var dismiss

    private let fallbackTitle: String
    private let coverURL: URL?
    private let listItem: MangaItem?

    @State private var tab: Tab = .about
    /// Показ sheet со всеми названиями тайтла (по тапу на название в шапке) —
    /// см. TitleNamesSheet.
    @State private var showTitleNames = false
    /// Sheet «Скачать тайтл» — см. DownloadTitleSheet.
    @State private var showDownloadSheet = false
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
    @State private var showLoginForComment = false

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

    /// Голос "+"/"-" за "Похожее" (см. similarSection/similarVoteColumn) —
    /// требует авторизации так же, как и комментарии; отдельный флаг вместо
    /// переиспользования showLoginForComment, т.к. источник действия другой.
    @State private var showLoginForSimilarVote = false

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

    init(slug: String, fallbackTitle: String = "", coverURL: URL? = nil, item: MangaItem? = nil) {
        _viewModel = StateObject(wrappedValue: MangaDetailViewModel(slug: slug))
        self.fallbackTitle = fallbackTitle
        self.coverURL = coverURL
        self.listItem = item
    }

    private var title: String { viewModel.detail?.displayTitle ?? listItem?.displayTitle ?? fallbackTitle }

    var body: some View {
        ScrollView {
          ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 0) {
                heroHeader
                VStack(alignment: .leading, spacing: 18) {
                    // titleBlock переехал в heroHeader (см. там) — теперь это
                    // overlay поверх фоновой картинки, а не отдельный блок
                    // здесь, чтобы фон мог тянуться ровно до его низа.
                    actionButtons
                    infoRow
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
        // Свой back-button поверх hero (см. heroHeader) вместо системной
        // navigation bar — баннер уходит под статус-бар, как в референсе.
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
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
        .sheet(isPresented: $showLoginForComment) { LoginView() }
        .sheet(isPresented: $showLoginForSimilarVote) { LoginView() }
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
                title: title,
                typeLabel: viewModel.detail?.type?.label ?? listItem?.type?.label,
                chapters: viewModel.chapters
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
                RemoteImage(url: viewModel.detail?.cover?.bestURL ?? coverURL) { image in
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
                        RemoteImage(url: heroURL) { image in
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
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular, in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 54) // ниже статус-бара, баннер уходит под него целиком
        }
        .overlay(alignment: .topTrailing) {
            // Кнопка "..." — стандартное системное Menu (стеклянный список iOS
            // по умолчанию), как попросили. Стеклянный круг вокруг иконки — как
            // у кнопки "назад" слева.
            Menu {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                }
                Button { /* ЗАГЛУШКА */ } label: { Label("Редактирование глав", systemImage: "square.and.pencil") }
                Button { /* ЗАГЛУШКА */ } label: { Label("Добавить главы", systemImage: "plus") }
                Button { /* ЗАГЛУШКА */ } label: { Label("Редактирование тайтла", systemImage: "pencil") }
                Button { showDownloadSheet = true } label: { Label("Скачать тайтл", systemImage: "arrow.down.circle") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular, in: Circle())
            }
            .padding(.trailing, 16)
            .padding(.top, 54)
        }
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
        let rating = (viewModel.detail?.rating ?? listItem?.rating)?.value
        let views = viewModel.detail?.views
        let hasRating = (rating ?? 0) > 0
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
    private var infoRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                infoBlock("Тип", value: (viewModel.detail?.type ?? listItem?.type)?.label)
                infoBlock("Статус", value: (viewModel.detail?.status ?? listItem?.status)?.label)
                infoBlock("Год выпуска", value: viewModel.detail?.yearString)
                // Просмотры — теперь 4-е место (сразу после года), как попросили.
                infoBlock("Просмотры", value: viewModel.detail?.viewsString)
                infoBlock("Формат", value: formatValue)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var formatValue: String? {
        let labels = viewModel.detail?.formatLabels ?? []
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    // Фиксированная высота (вместо .padding(.vertical)) — гарантирует, что
    // все плашки одинаковой высоты независимо от длины текста, как попросили.
    private static let infoBlockHeight: CGFloat = 50

    @ViewBuilder
    private func infoBlock(_ heading: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            // Было 12, потом 16 — с Capsule() скруглённые торцы "съедали"
            // пространство у коротких значений (16+, Манга и т.п.), из-за
            // чего внутренний текст выглядел прижатым к краю/неровным.
            // 20 — ещё шире и ровнее, как попросили "чуть увеличить".
            .padding(.horizontal, 20)
            .frame(height: Self.infoBlockHeight, alignment: .leading)
            // Capsule вместо RoundedRectangle(10) — чтобы скругление совпадало
            // с остальными кнопками карточки (actionButtons ниже используют
            // системные .bordered/.borderedProminent, которые в этом
            // приложении везде рендерятся как полностью скруглённые пилюли —
            // тот же Capsule-стиль уже используется по всему приложению для
            // подобных чипов/бэйджей). Высоту (Self.infoBlockHeight) НЕ трогаю.
            .background(Theme.surfaceElevated, in: Capsule())
        }
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

    private static func shortCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1f M", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1f K", Double(n) / 1_000)
        default:           return "\(n)"
        }
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
    /// Ширина обложки при этой высоте — та же пропорция 80:112 (~5:7), что
    /// была раньше, просто отмасштабированная под новую высоту.
    private static let similarCoverWidth: CGFloat = similarCardHeight * 80 / 112
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
            preferredBranchId: branchId
        )
    }

    // MARK: Tabs
    //
    // Плоские текстовые вкладки с подчёркиванием у активной вместо
    // стеклянных капсул — как просили.

    private var tabBar: some View {
        // Центрируем группу вкладок (было left-aligned + Spacer в конце).
        HStack(spacing: 24) {
            Spacer(minLength: 0)
            tabButton("О тайтле", .about)
            tabButton(displayChapters.isEmpty ? "Главы" : "Главы \(max(viewModel.totalChapters, displayChapters.count))", .chapters)
            tabButton("Комментарии", .comments)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
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
                .padding(.bottom, 10)
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
            if viewModel.detail == nil && viewModel.isLoading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }

            if isBlockedByLicenseOrModeration {
                // "Нет глав" + подтверждённые маркеры (is_licensed/moderated,
                // см. MangaDetail.isBlockedByLicenseOrModeration) — вместо
                // обычного описания объясняем ПОЧЕМУ глав нет, как попросили.
                blockTitle("Описание")
                Label(
                    "Главы удалены по требованию правообладателя или роскомнадзора, либо тайтл находится на проверке.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
            } else if let summary = viewModel.detail?.summary, !summary.isEmpty {
                blockTitle("Описание")
                // Максимум 4 строки + оранжевая "Подробнее.../Свернуть" —
                // см. ExpandableDescription (показывается только если текст
                // реально длиннее 4 строк).
                ExpandableDescription(text: summary)
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
                blockTitle("Жанры и теги")
                CollapsibleChips(items: chipItems)
            }

            // Порядок ниже — как явно попросили: Связанное ВСЕГДА выше
            // Похожего, оба опциональны и просто скрываются (см.
            // relatedSection/similarSection), если списки пустые.
            relatedSection
            similarSection
            charactersSection
            statsSection

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
                // Команды перевода тайтла — чипы сверху (аватар + имя + колокол).
                let teams = allTeams
                if !teams.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(teams) { teamChip($0) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                // Строка «Сортировать» (слева) + «К главе» (справа, если есть закладка).
                sortAndJumpRow(count: chapters.count)

                // Пока идёт скачивание — показываем прогресс над списком.
                if let p = activeDownloadProgress {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text("Главы качаются… \(p.completed)/\(p.total)")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Порядок: по умолчанию новые сверху; «Сортировать» переключает.
                let sorted = chaptersNewestFirst ? Array(chapters.reversed()) : chapters
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, chapter in
                        chapterBlock(chapter)
                            .id(chapter.id) // для прокрутки по «К главе»
                        if index < sorted.count - 1 {
                            Divider().overlay(Theme.separator).padding(.leading, 14)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

            if bookmarks.readingProgress(forSlug: viewModel.slug) != nil {
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

            // Колокольчик — подписка на уведомления команды (ЗАГЛУШКА, API позже).
            Image(systemName: "bell")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surfaceElevated, in: Capsule())
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
                Spacer().frame(height: 6)
            }
        } else {
            compactChapterRow(chapter, branchId: branches.first?.branchId)
        }
    }

    /// Заголовок главы (глазок + название) — без скачивания, оно у веток.
    private func chapterHeaderRow(_ chapter: ChapterItem) -> some View {
        HStack(spacing: 10) {
            Button { markReadUpTo(chapter) } label: {
                Image(systemName: isRead(chapter) ? "bookmark.fill" : "eye")
                    .font(.system(size: 15))
                    .foregroundStyle(isRead(chapter) ? Theme.accent : Theme.textSecondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(chapter.displayTitle)
                .font(.system(size: 14))
                .foregroundStyle(chapterColor(chapter))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.separator)
                    .frame(width: 2, height: 20)
                    .frame(width: 26, alignment: .center)

                RemoteImage(url: branch.teamAvatarURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.surfaceElevated)
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())

                Text(branch.teamName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let date = branch.dateString {
                    Text(date)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                chapterDownloadControl(chapter, branchId: branch.branchId)
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Компактная строка главы (одна ветка/офлайн): глазок + название + дата + скачать.
    private func compactChapterRow(_ chapter: ChapterItem, branchId: Int?) -> some View {
        Button {
            readerOpen = ReaderOpen(chapter: chapter, branchId: branchId)
        } label: {
            HStack(spacing: 10) {
                Button { markReadUpTo(chapter) } label: {
                    Image(systemName: isRead(chapter) ? "bookmark.fill" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(isRead(chapter) ? Theme.accent : Theme.textSecondary)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(chapter.displayTitle)
                    .font(.system(size: 14))
                    .foregroundStyle(chapterColor(chapter))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if let date = chapter.dateString {
                    Text(date)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                chapterDownloadControl(chapter, branchId: branchId)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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

    /// Глазок слева: отметить прочитанными все главы ДО этой включительно
    /// (прогресс чтения). Тайтл при этом добавляется в «Читаю», если его ещё
    /// нет в закладках (иначе прогресс некуда писать).
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
            readCount: pos, total: displayChapters.count
        )
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

            Button { showCommentSettings = true } label: {
                Label("Настройки", systemImage: "slider.horizontal.3")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.pillControlHeight)
                    .background(Theme.surfaceElevated, in: Capsule())
            }

            Spacer(minLength: 0)
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

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Написать комментарий...", text: $commentDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    let trimmed = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button {
                        let text = commentDraft
                        let parent = replyingTo
                        commentDraft = ""
                        replyingTo = nil
                        Task {
                            let ok = await viewModel.postComment(text: text, replyingTo: parent)
                            if !ok { commentDraft = text }
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(trimmed.isEmpty ? Theme.textSecondary : Theme.accent)
                    }
                    .disabled(trimmed.isEmpty || viewModel.isPostingComment)
                }
            }
        } else {
            Button { showLoginForComment = true } label: {
                Label("Войдите, чтобы оставить комментарий", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.surfaceElevated, in: Capsule())
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
    private func commentNode(_ comment: Comment, grouped: [Int: [Comment]]) -> AnyView {
        // Было children.sort{...} (мутирующий вызов, возвращает Void) — внутри
        // @ViewBuilder-контекста это ломало компиляцию отдельно от проблемы
        // выше; заменено на .sorted (не мутирует, обычное присваивание).
        let children: [Comment] = {
            let arr = grouped[comment.id] ?? []
            return viewModel.commentSort == .popular ? arr.sorted { $0.score > $1.score } : arr
        }()

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                commentRow(comment)

                if !children.isEmpty {
                    // Сворачиваем ответы по умолчанию, если их СОБСТВЕННЫЙ уровень
                    // вложенности достиг порога из настроек (см. collapseFromLevel) —
                    // если пользователь уже разворачивал ЭТУ ветку вручную, не
                    // сворачиваем снова (см. expandedThreads).
                    if let firstLevel = children.first?.commentLevel,
                       Double(firstLevel) >= collapseFromLevel, !expandedThreads.contains(comment.id) {
                        Button {
                            expandedThreads.insert(comment.id)
                        } label: {
                            Label("Показать ответы (\(children.count))", systemImage: "chevron.down")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.leading, 28)
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
                                commentNode(child, grouped: grouped)
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

                if !comment.text.isEmpty {
                    Text(comment.text).font(.subheadline).foregroundStyle(Theme.textPrimary)
                }

                // Низ сообщения: "Ответить" слева, "Жалоба" + счётчик
                // голосов (▲ число ▼) справа — как попросили.
                HStack(spacing: 16) {
                    Button { replyingTo = comment } label: {
                        Text("Ответить").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button { showReportComingSoon = true } label: {
                        Text("Жалоба").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

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

    /// Чип возрастного рейтинга для блока "Жанры и теги" — как попросили:
    /// 18+ красным (текст + обводка), 16+ таким же образом оранжевым, а
    /// 12+/6+/"Нет"/отсутствие рейтинга вообще не показываются (nil).
    /// Показывается ПЕРВЫМ в списке — см. aboutTab, где он идёт перед
    /// genres+tags.
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

#Preview {
    NavigationStack {
        MangaDetailView(slug: "example", fallbackTitle: "Пример манги")
    }
    .preferredColorScheme(.dark)
}
