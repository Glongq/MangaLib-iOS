import SwiftUI

/// "Данные и память" — реализован ПОЛНОСТЬЮ (не StubView, в отличие от
/// большинства остальных пунктов Настроек, см. AppSettingsView) по прямой
/// просьбе, со скриншотом официального приложения-референса как образцом
/// раскладки, но с честными числами под РЕАЛЬНУЮ архитектуру кэширования
/// именно этого приложения — местами это не 1-в-1 копия референса:
///
/// - "Другие приложения" — ОЦЕНКА, не настоящее число: сторонние приложения
///   в песочнице iOS физически не видят размер других приложений. Считается
///   как остаток (весь диск − свободно − то, что реально занимает ЭТО
///   приложение) — так же поступает и большинство других приложений с таким
///   виджетом хранилища.
/// - "Кеш изображений" (RemoteImageLoader.diskCache — обложки, страницы
///   читалки, всё, что грузится через RemoteImage) и "Кеш запросов"
///   (URLCache.shared — JSON-ответы API: карточки тайтлов, списки глав и
///   т.д.) — в референсе это "Кеш изображений"/"Кеш страниц"; здесь
///   переименовано во второе честно, чтобы не создавать впечатление, что
///   очищаются именно страницы манги (в этом приложении картинки читалки
///   уже покрыты первым пунктом).
/// - "История поиска" — в этом приложении история поиска пока не ведётся
///   вообще, поэтому честно 0, без работающей кнопки очистки заглушки ради
///   заглушки.
/// - "Кеш данных" — очищает ВСЁ кэшированное (оба URLCache + случайные
///   временные файлы в Caches/), реальный "может помочь при проблемах".
/// - "Путь загрузки" — на iOS нет альтернативного места хранения (SD-карта
///   и т.п. недоступны приложениям), поэтому строка информационная, без
///   перехода — переход подразумевал бы функциональность, которой тут
///   физически не может быть.
/// - "Скачивать только через Wi-Fi" — реальный переключатель, блокирует
///   СТАРТ новой загрузки на сотовой сети (см. DownloadsManager.
///   canStartDownload); не отслеживает переключение сети посреди уже идущей
///   загрузки — отдельная, более сложная доработка.
/// - "Кеш загрузки" — папки-сироты в Downloads/ от отменённых/недокачанных
///   загрузок (см. DownloadsManager.orphanedDownloadPaths) — реальный мусор,
///   безопасно чистится, не трогая ничего из списка "Загрузки".
struct StorageSettingsView: View {
    @ObservedObject private var downloads = DownloadsManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var stats = Stats()
    @State private var showClearAllCachesConfirm = false

    struct Stats {
        var totalCapacity: Int64 = 0
        var availableCapacity: Int64 = 0
        var downloadsBytes: Int64 = 0
        var imageCacheBytes: Int64 = 0
        var apiCacheBytes: Int64 = 0
        var miscCacheBytes: Int64 = 0
        var orphanedDownloadBytes: Int64 = 0

        var cacheBytes: Int64 { imageCacheBytes + apiCacheBytes + miscCacheBytes }
        var usedByApp: Int64 { downloadsBytes + cacheBytes }
        var otherAppsBytes: Int64 { max(0, totalCapacity - availableCapacity - usedByApp) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    storageCard
                    downloadsCard
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Данные и память")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
    }

    // MARK: Хранилище устройства

    private var storageCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Хранилище устройства")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("Доступно \(Self.byteString(stats.availableCapacity))")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                storageBar

                VStack(alignment: .leading, spacing: 8) {
                    legendRow(color: .blue, title: "Другие приложения", bytes: stats.otherAppsBytes)
                    legendRow(color: .green, title: "Скачанные тайтлы", bytes: stats.downloadsBytes)
                    legendRow(color: Theme.textSecondary, title: "Кеш", bytes: stats.cacheBytes)
                }
            }
            .padding(16)

            Divider().overlay(Theme.separator).padding(.horizontal, 16)

            clearableRow(
                title: "Кеш изображений",
                bytes: stats.imageCacheBytes
            ) {
                RemoteImageLoader.clearImageCache()
                refresh()
            }
            clearableRow(
                title: "Кеш запросов",
                subtitle: "Ответы сервера — карточки тайтлов, главы и т.п.",
                bytes: stats.apiCacheBytes
            ) {
                URLCache.shared.removeAllCachedResponses()
                refresh()
            }
            searchHistoryRow
            clearableRow(
                title: "Кеш данных",
                subtitle: "Очищает изображения, запросы и временные файлы — может помочь при различных проблемах",
                bytes: nil,
                showDivider: false
            ) {
                showClearAllCachesConfirm = true
            }
        }
        .confirmationDialog("Очистить весь кеш приложения?", isPresented: $showClearAllCachesConfirm, titleVisibility: .visible) {
            Button("Очистить кеш", role: .destructive) {
                Self.clearAllCaches()
                refresh()
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var storageBar: some View {
        let total = max(1, stats.otherAppsBytes + stats.downloadsBytes + stats.cacheBytes)
        return GeometryReader { geo in
            HStack(spacing: 3) {
                Capsule().fill(.blue)
                    .frame(width: geo.size.width * CGFloat(stats.otherAppsBytes) / CGFloat(total))
                Capsule().fill(.green)
                    .frame(width: geo.size.width * CGFloat(stats.downloadsBytes) / CGFloat(total))
                Capsule().fill(Theme.textSecondary.opacity(0.6))
                    .frame(width: geo.size.width * CGFloat(stats.cacheBytes) / CGFloat(total))
            }
        }
        .frame(height: 10)
    }

    private func legendRow(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.footnote).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            Text(Self.byteString(bytes)).font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }

    /// Честно 0 — истории поиска в приложении пока нет вообще, поэтому без
    /// работающей кнопки очистки заглушки ради заглушки (см. комментарий у
    /// структуры выше).
    private var searchHistoryRow: some View {
        VStack(spacing: 0) {
            HStack {
                Text("История поиска").foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("Нет данных").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            Divider().overlay(Theme.separator).padding(.horizontal, 16)
        }
    }

    // MARK: Загрузки

    private var downloadsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Загрузки")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)

            card {
                // На iOS нет альтернативного места хранения — строка
                // информационная, без перехода (переход подразумевал бы
                // выбор, которого тут физически не может быть).
                VStack(spacing: 0) {
                    HStack {
                        Text("Путь загрузки").foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("Хранилище устройства").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    Divider().overlay(Theme.separator).padding(.horizontal, 16)
                }

                Toggle(isOn: $downloads.wifiOnlyDownloads) {
                    Text("Скачивать только через Wi-Fi").foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)

                Divider().overlay(Theme.separator).padding(.horizontal, 16)

                clearableRow(
                    title: "Кеш загрузки",
                    subtitle: "Остатки отменённых/недокачанных глав",
                    bytes: stats.orphanedDownloadBytes,
                    showDivider: false
                ) {
                    downloads.clearOrphanedDownloads()
                    refresh()
                }
            }
        }
    }

    // MARK: Общее

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func clearableRow(title: String, subtitle: String? = nil, bytes: Int64?, showDivider: Bool = true, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 12)
                Button(action: action) {
                    Text(bytes.map { "Очистить \(Self.byteString($0))" } ?? "Очистить")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.surface, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.horizontal, 16)
            }
        }
    }

    private func refresh() {
        let volumeURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? volumeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0

        let imageBytes = Int64(RemoteImageLoader.diskCache?.currentDiskUsage ?? 0)
        let apiBytes = Int64(URLCache.shared.currentDiskUsage)
        let cachesDirBytes = Self.directorySize(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        let miscBytes = max(0, cachesDirBytes - imageBytes - apiBytes)

        stats = Stats(
            totalCapacity: total,
            availableCapacity: available,
            downloadsBytes: downloads.totalDownloadedBytes,
            imageCacheBytes: imageBytes,
            apiCacheBytes: apiBytes,
            miscCacheBytes: miscBytes,
            orphanedDownloadBytes: downloads.orphanedDownloadBytes()
        )
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func clearAllCaches() {
        RemoteImageLoader.clearImageCache()
        URLCache.shared.removeAllCachedResponses()
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        if let items = try? FileManager.default.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil) {
            for url in items { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    NavigationStack { StorageSettingsView() }
        .preferredColorScheme(.dark)
}
