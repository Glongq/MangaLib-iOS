import SwiftUI

/// Карточка тайтла внешнего сайта (см. план, ЧАСТЬ B) — обложка без фона
/// сверху, тип под названием, рейтинг (только e-hentai, у hitomi такого
/// поля физически нет), метаданные чипами, превью-грид страниц своей
/// пагинацией + переходом в читалку на нужную страницу, Related Galleries,
/// вкладки «О тайтле»/«Комментарии». НЕ переиспользует MangaDetailView —
/// другая форма данных (ExternalGalleryDetail, не MangaItem/MangaDetail).
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

    private enum Tab { case about, comments }

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }
    /// ~20 страниц на "экран" пагинации превью-грида — то же число, что
    /// у e-hentai реально отдаёт своя полоса миниатюр за раз (подтверждено
    /// HAR, см. EHentaiProvider.fetchGalleryDetail), для hitomi точное
    /// число не HAR-подтверждено — берём то же самое, не выдумывая новое.
    private static let previewPageSize = 21
    private static let previewColumns = 3

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
                titleSection(detail)

                readButton(detail)

                // См. план ЧАСТЬ B.5 — у hitomi комментариев как концепции
                // нет вообще (ни одного comment-related запроса ни в одном
                // HAR), вкладка там не показывается совсем, не просто
                // "Недоступно" — весь контент всегда "О тайтле".
                if site == .ehentai {
                    tabPicker
                }

                switch tab {
                case .about:
                    metadataSection(detail)
                    if !detail.pages.isEmpty { previewGridSection(detail) }
                    relatedSection(detail)
                case .comments:
                    commentsSection(detail)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Верх карточки (B.1)

    @ViewBuilder
    private func coverSection(_ detail: ExternalGalleryDetail) -> some View {
        if let cover = detail.coverURL {
            ExternalImage(url: cover) { SkeletonBox() }
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func titleSection(_ detail: ExternalGalleryDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail.type.capitalized)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            if let average = detail.ratingAverage {
                ratingWidget(average: average, count: detail.ratingCount)
            }
        }
    }

    /// Только у e-hentai (`detail.ratingAverage != nil`) — у hitomi поля
    /// рейтинга в galleries/{id}.js нет, честно не показываем (см. план).
    private func ratingWidget(average: Double, count: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.footnote)
                .foregroundStyle(.yellow)
            Text(String(format: "%.2f", average))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let count {
                Text("(\(count))")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func readButton(_ detail: ExternalGalleryDetail) -> some View {
        NavigationLink {
            ExternalReaderView(site: site, detail: detail)
        } label: {
            Text("Читать (\(detail.pages.count) стр.)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.pillControlHeight)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            Text("О тайтле").tag(Tab.about)
            Text("Комментарии").tag(Tab.comments)
        }
        .pickerStyle(.segmented)
    }

    // MARK: Метаданные чипами (B.2)

    private func metadataSection(_ detail: ExternalGalleryDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !detail.groups.isEmpty { chipRow("Группа", detail.groups) }
            if let language = detail.language, !language.isEmpty { chipRow("Язык", [language]) }
            if !detail.series.isEmpty { chipRow("Серия", detail.series) }
            if !detail.characters.isEmpty { chipRow("Персонажи", detail.characters) }
            if !detail.tags.isEmpty { tagsChipRow(detail) }
            chipRow("Инфо", infoFacts(detail))
        }
    }

    /// Posted/Length — общие для обоих сайтов; Parent/Visible/File size/
    /// Favorited — ТОЛЬКО e-hentai (у hitomi таких полей физически нет, см.
    /// план ЧАСТЬ B.2 — не выдумываем, просто не добавляем в список).
    private func infoFacts(_ detail: ExternalGalleryDetail) -> [String] {
        var facts: [String] = []
        if let posted = detail.posted, !posted.isEmpty { facts.append("Опубликовано: \(posted)") }
        facts.append("Длина: \(detail.pages.count) стр.")
        if let parentId = detail.parentId { facts.append("Родитель: #\(parentId)") }
        if let visible = detail.visible, !visible.isEmpty { facts.append("Видимость: \(visible)") }
        if let fileSize = detail.fileSize, !fileSize.isEmpty { facts.append("Размер: \(fileSize)") }
        if let favorited = detail.favoritedCount, !favorited.isEmpty { facts.append("В избранном: \(favorited)") }
        return facts
    }

    private func chipRow(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    chip(value)
                }
            }
        }
    }

    private func tagsChipRow(_ detail: ExternalGalleryDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Теги")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(detail.tags.enumerated()), id: \.offset) { _, tag in
                    chip(tagLabel(tag))
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.surfaceElevated, in: Capsule())
    }

    private func tagLabel(_ tag: ExternalGalleryTag) -> String {
        if tag.female { return "\(tag.name) ♀" }
        if tag.male { return "\(tag.name) ♂" }
        return tag.name
    }

    // MARK: Превью-грид страниц + пагинация + jump-to-page (B.3)

    private func previewGridSection(_ detail: ExternalGalleryDetail) -> some View {
        let pages = detail.pages
        let totalPaginationPages = max(1, Int((Double(pages.count) / Double(Self.previewPageSize)).rounded(.up)))
        let clampedPage = min(max(previewPage, 1), totalPaginationPages)
        let startIndex = (clampedPage - 1) * Self.previewPageSize
        let endIndex = min(startIndex + Self.previewPageSize, pages.count)
        let visiblePages = Array(pages[startIndex..<endIndex])
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.previewColumns)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Предпросмотр страниц")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(visiblePages, id: \.index) { page in
                    NavigationLink {
                        ExternalReaderView(site: site, detail: detail, initialPage: page.index)
                    } label: {
                        previewThumb(page)
                    }
                    .buttonStyle(.plain)
                }
            }

            if totalPaginationPages > 1 {
                paginationRow(total: totalPaginationPages, current: clampedPage)
            }
        }
    }

    private func previewThumb(_ page: ExternalGalleryPage) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = page.thumbnailURL {
                    ExternalImage(url: url) { SkeletonBox() }
                        .scaledToFill()
                } else {
                    SkeletonBox()
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fill)
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

    // MARK: Related Galleries (B.4)

    @ViewBuilder
    private func relatedSection(_ detail: ExternalGalleryDetail) -> some View {
        if !detail.related.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Похожие тайтлы")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                    ForEach(detail.related, id: \.self) { relatedId in
                        RelatedGalleryCard(site: site, id: relatedId)
                    }
                }
            }
        }
    }

    // MARK: Комментарии (B.5)

    @ViewBuilder
    private func commentsSection(_ detail: ExternalGalleryDetail) -> some View {
        if detail.comments.isEmpty {
            StateView(icon: "bubble.left", title: "Пока нет комментариев")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.comments) { comment in
                    commentRow(comment)
                }
            }
        }
    }

    private func commentRow(_ comment: ExternalComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comment.author)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(comment.postedAt)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(comment.text)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(12)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// Одна карточка в Related Galleries (B.4) — визуально копирует стиль
/// карточки каталога (см. ExternalCatalogGridView.card), но переиспользует
/// её КАК КОД нельзя (тот метод private конкретного вью) — по тому же
/// принципу, что и остальные новые вью в этом слое (копипаста стиля, не
/// общий компонент, см. план). Сама грузит свою карточку лениво по
/// `.task` — тот же принцип "подгрузка по мере появления", что и в сетке
/// каталога, но без пагинации (related — обычно короткий список).
private struct RelatedGalleryCard: View {
    let site: ExternalSite
    let id: Int

    @State private var detail: ExternalGalleryDetail?

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }

    var body: some View {
        NavigationLink {
            ExternalGalleryDetailView(site: site, id: id, preloaded: detail)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let cover = detail?.coverURL {
                        ExternalImage(url: cover) { SkeletonBox() }
                            .scaledToFill()
                    } else {
                        SkeletonBox()
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipped()

                Text(detail?.title ?? "…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
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
