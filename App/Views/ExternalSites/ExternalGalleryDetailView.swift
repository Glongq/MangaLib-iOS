import SwiftUI
import UIKit

/// Карточка тайтла внешнего сайта (см. план, ЧАСТЬ B) — визуально КОПИРУЕТ
/// стиль текстов/чипов/вкладок обычной карточки тайтла (MangaDetailView) —
/// по прямой просьбе ("стиль текстов всё как из обычной манги, просто
/// адаптирован под это"): та же плашка "Тип" под названием (как в
/// MangaCardView), тот же infoRow-ряд чипов Тип/Язык/... (см.
/// MangaDetailView.infoRow/infoBlock), те же CollapsibleChips для тегов/
/// персонажей/серии, тот же подчёркнутый tabBar вместо системного
/// Picker(.segmented), тот же RatingChip-подобный бэйдж на обложке, тот же
/// blockTitle/relatedCard стиль для "Похожих тайтлов". НЕ импортирует
/// MangaDetailView (другая форма данных, ExternalGalleryDetail, не
/// MangaItem/MangaDetail, см. план про изоляцию от старого сетевого кода)
/// — стиль скопирован построчно, не переиспользован как код.
struct ExternalGalleryDetailView: View {
    let site: ExternalSite
    let id: Int
    /// Если карточка уже была подгружена в сетке (см. ExternalCatalogGridView),
    /// не грузим её ещё раз — просто используем сразу.
    var preloaded: ExternalGalleryDetail?

    @State private var detail: ExternalGalleryDetail?
    @State private var errorMessage: String?
    @State private var tab: Tab = .about
    @State private var previewPage: Int = 1
    @State private var previewJumpText = ""
    @Namespace private var tabIndicator

    /// Читалка — ТОЛЬКО `.fullScreenCover`, не push через NavigationLink
    /// (1-в-1 MangaDetailView.readerOpen/.fullScreenCover) — раньше была
    /// NavigationLink, из-за чего читалка оставалась ВНУТРИ текущего таба
    /// NavigationStack и таб-бар приложения (Закладки/Каталог/...) не
    /// прятался, торчал поверх интерфейса читалки (по жалобе со скриншотом,
    /// 30.08).
    @State private var readerOpen: ReaderOpen?

    private struct ReaderOpen: Identifiable {
        let id = UUID()
        let initialPage: Int?
    }

    /// Переход по чипу (Группа/Серия/Персонажи/Автор/Женское/Мужское/
    /// Смешанное/Другое, см. aboutTab) — push (не .fullScreenCover, как у
    /// читалки: это обычный каталог, тот же остаётся таб-бар/навигация,
    /// что и при переходе из ExternalTagBrowserView) в
    /// ExternalCatalogGridView, отфильтрованный по ЭТОМУ конкретному
    /// значению НА ТОМ ЖЕ сайте, откуда открыта карточка (по прямой
    /// просьбе 31.08 — "по сайту сразу", т.е. свой namespace/провайдер
    /// именно этого сайта, не общий/угаданный).
    // Hashable (не только Identifiable) — .navigationDestination(item:)
    // требует именно Hashable (в отличие от .sheet(item:)/.fullScreenCover
    // (item:), которым достаточно Identifiable) — без этого сборка падает
    // ("requires that 'TagCatalogTarget' conform to 'Hashable'", CI).
    private struct TagCatalogTarget: Identifiable, Hashable {
        let id = UUID()
        let namespace: ExternalTagNamespace
        let value: String
        let title: String
    }

    @State private var tagCatalogTarget: TagCatalogTarget?

    private func openTagCatalog(namespace: ExternalTagNamespace, value: String, title: String) {
        tagCatalogTarget = TagCatalogTarget(namespace: namespace, value: value, title: title)
    }

    private enum Tab: Hashable { case about, comments }

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    /// ~20 страниц на "экран" пагинации превью-грида — то же число, что
    /// у e-hentai реально отдаёт своя полоса миниатюр за раз (подтверждено
    /// HAR, см. EHentaiProvider.fetchGalleryDetail), для hitomi точное
    /// число не HAR-подтверждено — берём то же самое, не выдумывая новое.
    private static let previewPageSize = 21
    private static let previewColumns = 3
    /// Высота чипа infoRow — 1-в-1 MangaDetailView.metaChipHeight (аватар/
    /// заголовок+значение в два ряда), см. infoBlock ниже.
    private static let metaChipHeight: CGFloat = 44
    /// Карточка "Похожих тайтлов" — 1-в-1 MangaDetailView.similarCardHeight/
    /// similarCoverWidth/similarCardWidthFraction.
    fileprivate static let relatedCardHeight: CGFloat = 132
    fileprivate static let relatedCoverWidth: CGFloat = relatedCardHeight * 2 / 3
    private static let relatedCardWidthFraction: CGFloat = 0.72

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background.ignoresSafeArea())
            .task {
                if let preloaded { detail = preloaded; return }
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            detailBody(detail)
        } else if let errorMessage {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: errorMessage, retry: { Task { await load() } }, fillScreen: true)
        } else {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailBody(_ detail: ExternalGalleryDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                coverSection(detail)
                titleBlock(detail)
                readButton(detail)

                // См. план ЧАСТЬ B.5 — у hitomi/3hentai комментариев как
                // концепции нет вообще (ни одного comment-related запроса
                // ни в одном HAR ни того, ни другого), вкладка там не
                // показывается совсем, весь контент всегда "О тайтле".
                // capabilities.hasComments, не хардкод конкретного сайта
                // (`site == .ehentai`, как было раньше) — иначе каждый
                // новый сайт без комментариев требовал бы правки именно
                // этой строки.
                if provider.capabilities.hasComments {
                    tabBar
                }

                switch tab {
                case .about:
                    aboutTab(detail)
                case .comments:
                    commentsTab(detail)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .fullScreenCover(item: $readerOpen) { open in
            ExternalReaderView(site: site, detail: detail, initialPage: open.initialPage)
        }
        .navigationDestination(item: $tagCatalogTarget) { target in
            ExternalCatalogGridView(site: site, query: .tag(namespace: target.namespace, value: target.value), title: target.title)
        }
    }

    // MARK: Верх карточки (B.1) — 1-в-1 MangaDetailView.heroHeader/titleBlock

    @ViewBuilder
    private func coverSection(_ detail: ExternalGalleryDetail) -> some View {
        if let cover = detail.coverURL {
            ExternalImage(url: cover) { SkeletonBox() }
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Рейтинг — на самой обложке, снизу слева (см.
                // MangaDetailView.coverRatingBadge) — только у e-hentai, у
                // hitomi такого поля нет.
                .overlay(alignment: .bottomLeading) { ratingBadge(detail) }
        }
    }

    @ViewBuilder
    private func ratingBadge(_ detail: ExternalGalleryDetail) -> some View {
        if let average = detail.ratingAverage {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                Text(String(format: "%.2f", average))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                if let count = detail.ratingCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }

    /// Название + тип строкой под ним — 1-в-1 стиль карточки в каталоге
    /// (см. MangaCardView.body: название, сразу под ним типом вторым
    /// текстом секондари-цветом), по прямой просьбе адаптировать этот же
    /// стиль сюда.
    private func titleBlock(_ detail: ExternalGalleryDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.type.isEmpty {
                Text(detail.type.capitalized)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// «Начать» — 1-в-1 MangaDetailView.readerLink (native
    /// .borderedProminent + Theme.accent, не самодельная Capsule). Кнопка,
    /// не NavigationLink — открывает `.fullScreenCover` (см. readerOpen).
    private func readButton(_ detail: ExternalGalleryDetail) -> some View {
        Button {
            readerOpen = ReaderOpen(initialPage: nil)
        } label: {
            Text("Читать (\(detail.pages.count) стр.)")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    // MARK: Вкладки «О тайтле»/«Комментарии» — 1-в-1 MangaDetailView.tabBar/
    // tabButton (подчёркнутые плоские вкладки, matchedGeometryEffect), без
    // третьей "Главы" (по прямой просьбе — "такого понятия как Главы тут
    // не будет").

    private var tabBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                tabButton("О тайтле", .about)
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
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { tab = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.bottom, 13)
                .overlay(alignment: .bottom) {
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

    // MARK: Tab «О тайтле»

    private func aboutTab(_ detail: ExternalGalleryDetail) -> some View {
        let categories = tagsByCategory(detail)
        return VStack(alignment: .leading, spacing: 18) {
            infoRow(detail)
            // Тап по чипу — сразу каталог ЭТОГО сайта, отфильтрованный по
            // конкретному значению (см. TagCatalogTarget/openTagCatalog,
            // прямая просьба 31.08 "по нажатию на чип сразу открывается
            // этот тег/жанр, по сайту сразу"). Namespace — свой на каждую
            // категорию (см. ExternalTagNamespace); значение — чистое
            // отображаемое имя, КАЖДЫЙ провайдер сам приводит его к
            // своему реальному query (у hitomi это уже готовый формат, у
            // 3hentai — слагификация + приписывание пола, см.
            // ThreeHentaiProvider.slugify/withGenderSuffix).
            if !detail.groups.isEmpty {
                chipsBlock("Группа", detail.groups.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .group, value: name, title: name) })
                })
            }
            // Порядок и разбивка ниже — по прямой просьбе (30.08): теги
            // делятся ПОЛНОСТЬЮ на отдельные подкатегории со своим
            // заголовком каждая (не одним общим блоком "Теги"), в этом же
            // порядке — Серия(parody)/Персонажи(character)/Язык(language)/
            // Автор(artist)/Женское(female)/Мужское(male)/Смешанное(mixed)/
            // Другое(other), каждый тег в своей отдельной чипе.
            if !detail.series.isEmpty {
                chipsBlock("Серия", detail.series.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .series, value: name, title: name) })
                })
            }
            if !detail.characters.isEmpty {
                chipsBlock("Персонажи", detail.characters.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .character, value: name, title: name) })
                })
            }
            // Язык — БЕЗ перехода: ни у одного провайдера нет
            // подтверждённого namespace под язык как отдельный кит
            // (ExternalTagNamespace такого не знает вовсе) — честно
            // некликабельно, а не угаданный (наверняка неверный) переход.
            if let language = detail.language, !language.isEmpty { chipsBlock("Язык", [.init(text: language)]) }
            if !detail.artists.isEmpty {
                chipsBlock("Автор", detail.artists.map { name in
                    .init(text: name, onTap: { openTagCatalog(namespace: .artist, value: name, title: name) })
                })
            }
            if !categories.female.isEmpty {
                chipsBlock("Женское", categories.female.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .female, value: tag.name, title: tag.name) })
                })
            }
            if !categories.male.isEmpty {
                chipsBlock("Мужское", categories.male.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .male, value: tag.name, title: tag.name) })
                })
            }
            // "Смешанный" тег (female И male оба true) — неоднозначно, к
            // какому из двух реальных namespace он относится (сайт не
            // даёт отдельного "смешанного" кита) — берём .female как
            // разумное приближение (первый из двух реально существующих
            // вариантов), не выдумывая несуществующий третий.
            if !categories.mixed.isEmpty {
                chipsBlock("Смешанное", categories.mixed.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .female, value: tag.name, title: tag.name) })
                })
            }
            if !categories.other.isEmpty {
                chipsBlock("Другое", categories.other.map { tag in
                    .init(text: tag.name, onTap: { openTagCatalog(namespace: .tag, value: tag.name, title: tag.name) })
                })
            }
            if !detail.pages.isEmpty { previewGridSection(detail) }
            relatedSection(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// female/male оба true — "смешанный" тег (подтверждено реальным
    /// `galleries/{id}.js` у hitomi: `tags[]` там имеет ОБА поля
    /// одновременно у части тегов); ни одного — нейтральный ("Другое").
    /// У e-hentai намеспейс тега строго один (нет одновременно "female" и
    /// "male" на одном теге, см. EHentaiProvider.parseMetadata) — там
    /// "Смешанное" просто никогда не наполнится, секция честно не покажется.
    private func tagsByCategory(_ detail: ExternalGalleryDetail) -> (female: [ExternalGalleryTag], male: [ExternalGalleryTag], mixed: [ExternalGalleryTag], other: [ExternalGalleryTag]) {
        var female: [ExternalGalleryTag] = []
        var male: [ExternalGalleryTag] = []
        var mixed: [ExternalGalleryTag] = []
        var other: [ExternalGalleryTag] = []
        for tag in detail.tags {
            switch (tag.female, tag.male) {
            case (true, true): mixed.append(tag)
            case (true, false): female.append(tag)
            case (false, true): male.append(tag)
            case (false, false): other.append(tag)
            }
        }
        return (female, male, mixed, other)
    }

    // MARK: Info row — 1-в-1 MangaDetailView.infoRow/infoBlock (Тип/Статус/
    // Год/Просмотры/Формат) — здесь Тип/Опубликовано/Длина + то, что есть
    // ТОЛЬКО у e-hentai (Родитель/Видимость/Размер/В избранном); Язык
    // вынесен в свой отдельный чип-блок (см. aboutTab — часть общей
    // разбивки по подкатегориям), не дублируется здесь. У hitomi этих
    // e-hentai-полей физически нет, просто не добавляются в список.

    private func infoRow(_ detail: ExternalGalleryDetail) -> some View {
        let rawItems: [(heading: String, value: String?)] = [
            (heading: "Тип", value: detail.type.isEmpty ? nil : detail.type.capitalized),
            (heading: "Опубликовано", value: detail.posted),
            (heading: "Длина", value: "\(detail.pages.count) стр."),
            (heading: "Родитель", value: detail.parentId.map { "#\($0)" }),
            (heading: "Видимость", value: detail.visible),
            (heading: "Размер", value: detail.fileSize),
            (heading: "В избранном", value: detail.favoritedCount)
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

    private func infoBlock(_ heading: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: Self.metaChipHeight)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    // MARK: Чипы (Группа/Серия/Персонажи/Теги) — 1-в-1 MangaDetailView
    // ("Жанры и теги"/"Франшиза"): blockTitle + переиспользованный
    // CollapsibleChips (тот же общий компонент, что и в MangaDetailView —
    // чистый UI-виджет без зависимости от старых сетевых моделей, как и
    // SkeletonBox/StateView, которые уже переиспользуются в этом слое).

    private func blockTitle(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(Theme.textPrimary)
    }

    private func chipsBlock(_ title: String, _ items: [CollapsibleChips.Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            blockTitle(title)
            CollapsibleChips(items: items)
        }
    }

    // MARK: Превью-грид страниц + пагинация + jump-to-page (B.3) — своего
    // аналога в обычной карточке манги нет (там вместо этого список глав),
    // заголовок/шрифты подогнаны под тот же blockTitle-стиль для консистентности.

    /// Ширина/зазор — ФИКСИРОВАННЫЕ числа (не GeometryReader/.flexible()+
    /// aspectRatio, как было раньше): вся секция сидит внутри одного и того
    /// же `.padding(16)` на весь контент карточки (см. detailBody), поэтому
    /// доступная ширина СЧИТАЕТСЯ заранее, без лишнего слоя геометрии —
    /// тот же приём, что и у MangaReaderView.titleBadgeMaxWidth. Раньше
    /// колонки были `.flexible()` + кропу задавался только aspectRatio БЕЗ
    /// явного .frame() — LazyVGrid в паре мест не мог стабильно посчитать
    /// высоту строки (гонка с асинхронной подгрузкой картинок), из-за чего
    /// сетка "лагала"/тайлы наслаивались друг на друга (жалоба 30.08). Явный
    /// .frame(width:height:) на каждой ячейке убирает саму возможность гонки.
    private static let previewSpacing: CGFloat = 8

    private func previewGridSection(_ detail: ExternalGalleryDetail) -> some View {
        let pages = detail.pages
        let totalPaginationPages = max(1, Int((Double(pages.count) / Double(Self.previewPageSize)).rounded(.up)))
        let clampedPage = min(max(previewPage, 1), totalPaginationPages)
        let startIndex = (clampedPage - 1) * Self.previewPageSize
        let endIndex = min(startIndex + Self.previewPageSize, pages.count)
        let visiblePages = Array(pages[startIndex..<endIndex])

        let availableWidth = UIScreen.main.bounds.width - 32
        let totalSpacing = Self.previewSpacing * CGFloat(Self.previewColumns - 1)
        let cellWidth = ((availableWidth - totalSpacing) / CGFloat(Self.previewColumns)).rounded(.down)
        let cellHeight = (cellWidth * 4 / 3).rounded()
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.previewSpacing), count: Self.previewColumns)

        return VStack(alignment: .leading, spacing: 10) {
            blockTitle("Предпросмотр страниц")

            LazyVGrid(columns: columns, spacing: Self.previewSpacing) {
                ForEach(visiblePages, id: \.index) { page in
                    Button {
                        readerOpen = ReaderOpen(initialPage: page.index)
                    } label: {
                        previewThumb(page, width: cellWidth, height: cellHeight)
                    }
                    .buttonStyle(.plain)
                }
            }

            if totalPaginationPages > 1 {
                paginationRow(total: totalPaginationPages, current: clampedPage)
            }
        }
    }

    private func previewThumb(_ page: ExternalGalleryPage, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = page.thumbnailURL, let offsetX = page.thumbnailSpriteOffsetX {
                    // e-hentai: url — общий спрайт на партию страниц, offsetX
                    // выбирает нужный тайл (см. ExternalGalleryPage.
                    // thumbnailSpriteOffsetX/ExternalSpriteThumbnail) — БЕЗ
                    // этого кропа тут показывался бы один и тот же спрайт
                    // целиком на КАЖДОЙ странице партии.
                    ExternalSpriteThumbnail(
                        url: url, offsetX: offsetX, tileWidth: page.width, tileHeight: page.height
                    ) { SkeletonBox() }
                    .scaledToFill()
                } else if let url = page.thumbnailURL {
                    // hitomi: url уже указывает на отдельную картинку именно
                    // этой страницы — кроп не нужен.
                    ExternalImage(url: url) { SkeletonBox() }
                        .scaledToFill()
                } else {
                    SkeletonBox()
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            Text("\(page.index)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 14)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    private func paginationRow(total: Int, current: Int) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(paginationSequence(total: total, current: current).enumerated()), id: \.offset) { _, item in
                        if let page = item {
                            Button {
                                previewPage = page
                            } label: {
                                Text("\(page)")
                                    .font(.footnote.weight(page == current ? .semibold : .regular))
                                    .foregroundStyle(page == current ? Theme.background : Theme.textPrimary)
                                    .frame(width: 28, height: 28)
                                    .background(page == current ? Theme.accent : Theme.surfaceElevated, in: Circle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("…")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 20, height: 28)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)

            TextField("№", text: $previewJumpText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .frame(width: 44, height: 28)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button {
                if let page = Int(previewJumpText), page > 0 {
                    previewPage = min(page, total)
                    previewJumpText = ""
                }
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Int(previewJumpText) != nil ? Theme.accent : Theme.textSecondary.opacity(0.4))
            }
            .disabled(Int(previewJumpText) == nil)
        }
    }

    /// "1 2 3 … 12" — обрезанная последовательность номеров страниц
    /// пагинации превью-грида, `nil` — место "…". Чисто клиентское
    /// вычисление (все страницы уже загружены в `detail.pages`), в отличие
    /// от ExternalCatalogGridView.pageJumpRow (там реальный сетевой запрос
    /// на курсор) — здесь просто листается уже готовый массив.
    private func paginationSequence(total: Int, current: Int) -> [Int?] {
        guard total > 7 else { return (1...total).map { $0 } }
        var keep: Set<Int> = [1, 2, total - 1, total, current - 1, current, current + 1]
        keep = keep.filter { $0 >= 1 && $0 <= total }
        let sorted = keep.sorted()
        var result: [Int?] = []
        var previous = 0
        for page in sorted {
            if page - previous > 1 { result.append(nil) }
            result.append(page)
            previous = page
        }
        return result
    }

    // MARK: Похожие тайтлы (B.4) — 1-в-1 MangaDetailView.relatedSection/
    // relatedCard (широкая карточка: обложка слева на всю высоту подложки,
    // название+тип справа, горизонтальный слайдер).

    @ViewBuilder
    private func relatedSection(_ detail: ExternalGalleryDetail) -> some View {
        if !detail.related.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                blockTitle("Похожие тайтлы")
                GeometryReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(detail.related, id: \.self) { relatedId in
                                RelatedGalleryCard(site: site, id: relatedId, width: proxy.size.width * Self.relatedCardWidthFraction)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(height: Self.relatedCardHeight)
            }
        }
    }

    // MARK: Комментарии (B.5) — 1-в-1 MangaDetailView.commentRow (аватар +
    // ник/дата, текст ниже, разделитель между соседними комментариями), без
    // веток/голосов/спойлеров — у e-hentai комментарии плоские, без ответов.

    @ViewBuilder
    private func commentsTab(_ detail: ExternalGalleryDetail) -> some View {
        if detail.comments.isEmpty {
            StateView(icon: "bubble.left", title: "Пока нет комментариев")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(detail.comments.enumerated()), id: \.offset) { index, comment in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    commentRow(comment)
                }
            }
        }
    }

    private func commentRow(_ comment: ExternalComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "person.fill").font(.footnote).foregroundStyle(Theme.textSecondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(comment.postedAt)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(comment.text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            detail = try await provider.fetchGalleryDetail(id: id)
        } catch {
            errorMessage = "Проверьте соединение и попробуйте ещё раз."
        }
    }
}

/// Одна карточка в "Похожих тайтлах" (B.4) — 1-в-1 MangaDetailView.relatedCard
/// (обложка слева во всю высоту подложки, название+тип справа), но данные
/// свои (ExternalGalleryDetail, не MangaItem) и грузится лениво по `.task`
/// (related — только ID, полные данные тянутся так же, как в сетке каталога,
/// см. ExternalCatalogGridView.loadDetail).
private struct RelatedGalleryCard: View {
    let site: ExternalSite
    let id: Int
    let width: CGFloat

    @State private var detail: ExternalGalleryDetail?

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }

    var body: some View {
        NavigationLink {
            ExternalGalleryDetailView(site: site, id: id, preloaded: detail)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let cover = detail?.coverURL {
                        ExternalImage(url: cover) { SkeletonBox() }
                            .scaledToFill()
                    } else {
                        SkeletonBox()
                    }
                }
                .frame(width: ExternalGalleryDetailView.relatedCoverWidth, height: ExternalGalleryDetailView.relatedCardHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail?.title ?? "…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    if let type = detail?.type, !type.isEmpty {
                        Text(type.capitalized)
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
        .frame(width: width, height: ExternalGalleryDetailView.relatedCardHeight)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            guard detail == nil else { return }
            detail = try? await provider.fetchGalleryDetail(id: id)
        }
    }
}

#Preview {
    NavigationStack {
        ExternalGalleryDetailView(site: .hitomi, id: 3267795)
    }
    .preferredColorScheme(.dark)
}
