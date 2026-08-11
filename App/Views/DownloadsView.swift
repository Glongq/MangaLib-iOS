import SwiftUI

/// Экран «Загрузки» — список скачанных тайтлов (как закладки): обложка,
/// название, число скачанных глав, прогресс-бар для активных загрузок. Тап по
/// тайтлу открывает его карточку. Справа снизу — «Отменить» (пока качается) или
/// «Удалить» (когда скачано). Стрелки-шеврона справа нет.
struct DownloadsView: View {

    @ObservedObject private var downloads = DownloadsManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Куда навигируемся по тапу (вместо NavigationLink со стрелкой).
    @State private var selected: DownloadedTitle?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if downloads.titles.isEmpty {
                    ContentUnavailableView(
                        "Нет загрузок",
                        systemImage: "arrow.down.circle",
                        description: Text("Скачанные тайтлы появятся здесь. Открой карточку тайтла → «...» → «Скачать тайтл».")
                    )
                } else {
                    List {
                        ForEach(downloads.titles) { title in
                            row(title)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = title }
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Загрузки")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { title in
                // Оффлайн-список глав скачанного тайтла (из manifest, без сети) —
                // отсюда открывается ридер, читающий локальные файлы.
                DownloadedTitleView(title: title)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ title: DownloadedTitle) -> some View {
        let progress = downloads.progress[title.slug]
        let downloading = progress.map { !$0.finished } ?? false
        let coverURL = downloads.localCoverURL(slug: title.slug) ?? title.coverURLString.flatMap(URL.init(string:))

        return HStack(spacing: 12) {
            RemoteImage(url: coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 56, height: 80)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let typeLabel = title.typeLabel, !typeLabel.isEmpty {
                    Text(typeLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let progress, !progress.finished {
                    ProgressView(value: progress.fraction)
                        .tint(Theme.accent)
                    Text("Скачивание \(progress.completed)/\(progress.total)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }

                // Всегда показываем, сколько глав реально скачано (на всякий).
                Text("Скачано глав: \(title.chapters.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Справа снизу: «Отменить» пока идёт загрузка, «Удалить» — когда готово.
        .overlay(alignment: .bottomTrailing) {
            Button {
                if downloading { downloads.cancel(slug: title.slug) }
                else { downloads.delete(slug: title.slug) }
            } label: {
                Text(downloading ? "Отменить" : "Удалить")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(downloading ? Theme.accent : .red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }
}

/// Оффлайн-экран одного скачанного тайтла: список скачанных глав (из manifest,
/// без сети). Тап открывает ридер, который читает страницы с диска.
struct DownloadedTitleView: View {

    let title: DownloadedTitle
    @ObservedObject private var downloads = DownloadsManager.shared

    private struct ReaderStart: Identifiable { let id = UUID(); let index: Int }
    @State private var readerStart: ReaderStart?

    /// Актуальная запись тайтла из менеджера (чтобы список глав рос по мере
    /// докачивания), с откатом на переданную копию.
    private var current: DownloadedTitle {
        downloads.titles.first(where: { $0.slug == title.slug }) ?? title
    }

    var body: some View {
        let chapters = current.chapters
        ZStack {
            Theme.background.ignoresSafeArea()

            if chapters.isEmpty {
                ContentUnavailableView("Главы качаются…", systemImage: "arrow.down.circle")
            } else {
                List {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            readerStart = ReaderStart(index: index)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.displayTitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Text("\(chapter.pageCount) стр.")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.accent)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.separator)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readerStart) { start in
            MangaReaderView(
                slug: current.slug,
                chapters: current.chapterItems,
                startIndex: start.index,
                mangaTitle: current.title,
                mangaTypeName: current.typeLabel,
                coverURL: current.coverURLString
            )
        }
    }
}

#Preview {
    DownloadsView()
}
