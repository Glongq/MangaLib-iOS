import SwiftUI

/// Экран «Загрузки» — список скачанных тайтлов (как закладки): обложка,
/// название, число скачанных глав, прогресс-бар для активных загрузок. Тап по
/// тайтлу открывает его карточку. Справа снизу — «Отменить» (пока качается) или
/// «Удалить» (когда скачано). Стрелки-шеврона справа нет.
struct DownloadsView: View {

    /// true — открыт PUSH-переходом внутри вкладки «Меню» (без своего
    /// NavigationStack и «Готово», есть системная «назад»).
    var embedded: Bool = false

    @ObservedObject private var downloads = DownloadsManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Куда навигируемся по тапу (вместо NavigationLink со стрелкой).
    @State private var selected: DownloadedTitle?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
                .preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
        }
    }

    private var content: some View {
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
            // Полноценная карточка тайтла (1-в-1 как из каталога). Онлайн —
            // подтянет описание/похожее и т.д.; в разделе «Главы» уже
            // скачанные главы помечаются и читаются офлайн (см.
            // MangaDetailView.displayChapters / downloadedChapterIds).
            MangaDetailView(
                slug: title.slug,
                fallbackTitle: title.title,
                coverURL: title.coverURLString.flatMap(URL.init(string:))
            )
        }
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .background { if embedded { InteractivePopGesture() } }
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
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }
}

#Preview {
    DownloadsView()
}
