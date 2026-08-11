import SwiftUI

/// Экран «Загрузки» — список скачанных тайтлов (как закладки): обложка,
/// название, число скачанных глав, прогресс-бар для активных загрузок. Тап по
/// тайтлу открывает его карточку, свайп влево удаляет загрузку с устройства.
struct DownloadsView: View {

    @ObservedObject private var downloads = DownloadsManager.shared
    @Environment(\.dismiss) private var dismiss

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
                            NavigationLink {
                                MangaDetailView(
                                    slug: title.slug,
                                    fallbackTitle: title.title,
                                    coverURL: title.coverURLString.flatMap(URL.init(string:))
                                )
                            } label: {
                                row(title)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloads.delete(slug: title.slug)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Загрузки")
            .navigationBarTitleDisplayMode(.inline)
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
                    // Активная загрузка — прогресс-бар + счётчик.
                    ProgressView(value: progress.fraction)
                        .tint(Theme.accent)
                    Text("Скачивание \(progress.completed)/\(progress.total)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(title.chapters.count) глав скачано")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    DownloadsView()
}
