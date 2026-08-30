import SwiftUI

/// Карточка тайтла внешнего сайта (см. план, Часть 6) — название, теги (с
/// ♀/♂ по female/male), автор/группа/серия/персонажи, превью первых
/// страниц, кнопка «Читать». НЕ переиспользует MangaDetailView — другая
/// форма данных (ExternalGalleryDetail, не MangaItem/MangaDetail), см. план.
struct ExternalGalleryDetailView: View {
    let site: ExternalSite
    let id: Int
    /// Если карточка уже была подгружена в сетке (см. ExternalCatalogGridView),
    /// не грузим её ещё раз — просто используем сразу.
    var preloaded: ExternalGalleryDetail?

    @State private var detail: ExternalGalleryDetail?
    @State private var errorMessage: String?

    private var provider: any ExternalSiteProvider { ExternalSiteRegistry.provider(for: site) }

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
                if let firstHash = detail.pages.first?.hash {
                    ExternalImage(url: provider.thumbnailURL(hash: firstHash)) { SkeletonBox() }
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Text(detail.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)

                metaRow(detail)

                if !detail.tags.isEmpty { tagsSection(detail) }

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
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func metaRow(_ detail: ExternalGalleryDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !detail.series.isEmpty {
                metaLine("Серия", detail.series.joined(separator: ", "))
            }
            if !detail.artists.isEmpty {
                metaLine("Автор", detail.artists.joined(separator: ", "))
            }
            if !detail.groups.isEmpty {
                metaLine("Группа", detail.groups.joined(separator: ", "))
            }
            if !detail.characters.isEmpty {
                metaLine("Персонажи", detail.characters.joined(separator: ", "))
            }
            if let language = detail.language {
                metaLine("Язык", language)
            }
            metaLine("Тип", detail.type)
        }
    }

    private func metaLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title + ":")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func tagsSection(_ detail: ExternalGalleryDetail) -> some View {
        // Оборачивающийся ряд чипов — простой LazyVGrid с адаптивной
        // колонкой вместо самодельного wrap-layout (в проекте такого
        // компонента нет, не заводим ради одного экрана).
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(detail.tags.enumerated()), id: \.offset) { _, tag in
                Text(tagLabel(tag))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
        }
    }

    private func tagLabel(_ tag: ExternalGalleryTag) -> String {
        if tag.female { return "\(tag.name) ♀" }
        if tag.male { return "\(tag.name) ♂" }
        return tag.name
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
