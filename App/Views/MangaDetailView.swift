import SwiftUI

/// Экран тайтла: шапка, инфо-строка, кнопки, вкладки (О тайтле / Главы / Комментарии).
struct MangaDetailView: View {

    @StateObject private var viewModel: MangaDetailViewModel
    @ObservedObject private var bookmarks = BookmarksStore.shared
    @Environment(\.dismiss) private var dismiss

    private let fallbackTitle: String
    private let coverURL: URL?
    private let listItem: MangaItem?

    @State private var tab: Tab = .about
    /// Показ sheet со всеми названиями тайтла (по тапу на название в шапке) —
    /// см. TitleNamesSheet.
    @State private var showTitleNames = false
    /// Пространство координат для "переезжающего" индикатора активной вкладки
    /// (см. tabButton/matchedGeometryEffect) — благодаря общему namespace
    /// SwiftUI анимирует подчёркивание как ОДНУ вьюху, плавно перемещая её (и
    /// подгоняя ширину под текст новой вкладки) между "О тайтле"/"Главы"/
    /// "Комментарии", а не гасит одно и зажигает другое.
    @Namespace private var tabIndicator
    @State private var showAddToFolder = false
    @State private var readerChapter: ChapterItem?
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
        .fullScreenCover(item: $readerChapter) { chapter in
            readerView(for: chapter)
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

    /// Фиксированное расстояние от верха баннера до верха обложки (см.
    /// heroHeader) — 400-223-10=167, ниже кнопки "назад" (та занимает
    /// 54...102 сверху) с большим запасом, независимо от того, сколько строк
    /// займёт название под обложкой (см. общий комментарий у heroHeader про
    /// естественный, однопроходный layout — старая схема через @State/
    /// PreferenceKey с задержкой измерения давала ДВЕ разные версии одного и
    /// того же бага: то обложка залезала на кнопку "назад", то, после
    /// первого фикса, название вылезало под кнопками снизу).
    private static let heroCoverTopOffset: CGFloat = heroBaseHeight - heroCoverSize.height - heroCoverTitleSpacing

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
                .overlay(alignment: .topTrailing) { coverRatingBadge }

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
                // Отдельное РОВНОЕ затемнение на 10% по ВСЕЙ картинке целиком (не
                // только у низа, как griдиент ниже) — как явно попросили, и для
                // заблюренной (запасная обложка), и для незаблюренной (настоящий
                // фон) картинки одинаково: применено ДО .blur(), поэтому в
                // заблюренном случае затемнение тоже размывается вместе с
                // картинкой, а не остаётся резким прямоугольником поверх блюра.
                .overlay(Color.black.opacity(0.1))
                .overlay(
                    // По присланному примеру ("фотошоп"-референс) нужен не узкий
                    // тонкий переход у самого низа, а широкий, плавный, заметный
                    // градиент, который начинает темнеть заметно ВЫШЕ (примерно с
                    // 30% высоты баннера) и постепенно усиливается до полностью
                    // сплошного цвета внизу (граница с кнопками "Добавить в"/
                    // "Начать" — там уже сплошной фон, поэтому шов незаметен).
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
                // Блюр — только когда показываем ЗАПАСНУЮ обложку вместо
                // настоящего фона (обложка обычно портретная, растянутая на всю
                // ширину баннера выглядит "разрезанной" без блюра). Если пришёл
                // настоящий background — он уже задуман как широкий баннер,
                // блюр только портил бы детали, поэтому убираем совсем (radius 0).
                .blur(radius: heroIsRealBackground ? 0 : 6)
                .clipped()
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
    private var coverRatingBadge: some View {
        RatingChip(rating: (viewModel.detail?.rating ?? listItem?.rating)?.value)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let eng = viewModel.detail?.name ?? listItem?.name, eng != title {
                Text(eng).font(.footnote).foregroundStyle(Theme.textSecondary)
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
            } else if let first = viewModel.chapters.first {
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
            readerChapter = chapter
        } label: {
            Text(label)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private func readerView(for chapter: ChapterItem) -> some View {
        MangaReaderView(
            slug: viewModel.slug,
            chapters: viewModel.chapters,
            startIndex: max(viewModel.position(of: chapter) - 1, 0),
            // Numeric id тайтла — нужен для реальной отметки главы
            // просмотренной в аккаунте (см. ReaderViewModel.recordProgress).
            mangaId: viewModel.detail?.id ?? listItem?.id,
            mangaTitle: title,
            // Тип тайтла (Манга/Манхва/...) — определяет дефолт вписывания
            // страницы в читалке (см. MangaReaderView.defaultFitWidth).
            mangaTypeName: viewModel.detail?.type?.label ?? listItem?.type?.label,
            coverURL: coverURL?.absoluteString ?? listItem?.coverURLString
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
            tabButton(viewModel.chapters.isEmpty ? "Главы" : "Главы \(viewModel.totalChapters)", .chapters)
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
            let genres = sortedNames(viewModel.detail?.genres)
            let tags = sortedNames(viewModel.detail?.tags)
            let genreItems = genres.map { CollapsibleChips.Item(text: $0) }
            let tagItems = tags.map { CollapsibleChips.Item(text: "#\($0)") }
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
        if viewModel.chapters.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: viewModel.isLoading ? "hourglass" : "book.closed")
                    .font(.title2).foregroundStyle(Theme.textSecondary)
                Text(viewModel.isLoading ? "Загрузка глав…" : "Главы не найдены")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            // Плоская подложка со всеми главами вместо стеклянной карточки.
            VStack(spacing: 0) {
                ForEach(Array(viewModel.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button { readerChapter = chapter } label: {
                        HStack {
                            Text(chapter.displayTitle)
                                // ~1.3х от .subheadline (15pt → 19.5pt), как попросили.
                                .font(.system(size: 19.5))
                                .foregroundStyle(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            if isRead(chapter) {
                                Image(systemName: "checkmark").font(.caption).foregroundStyle(Theme.accent)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < viewModel.chapters.count - 1 {
                        Divider().overlay(Theme.separator).padding(.leading, 14)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func isRead(_ chapter: ChapterItem) -> Bool {
        guard let p = bookmarks.readingProgress(forSlug: viewModel.slug) else { return false }
        return viewModel.position(of: chapter) <= p.readCount
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
        .task { await viewModel.loadCommentsIfNeeded() }
        .sheet(isPresented: $showCommentSettings) {
            CommentSettingsSheet(
                disabledInReader: $commentsDisabledInReader,
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
        var roots = grouped[0] ?? []
        if viewModel.commentSort == .popular {
            roots.sort { $0.score > $1.score }
        }
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

                    HStack(spacing: 3) {
                        Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9))
                        Text("\(comment.score)").font(.caption.weight(.bold))
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                    }
                    .foregroundStyle(commentScoreColor(comment.score))
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
