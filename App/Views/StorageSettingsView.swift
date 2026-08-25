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
///   виджетом хранилища. Полоска показывает РЕАЛЬНУЮ пропорцию от всей
///   ёмкости диска (включая свободное место — отдельным серым сегментом,
///   без строки в легенде, по прямой просьбе), а не только занятую часть.
/// - "Кеш изображений" (RemoteImageLoader.diskCache — обложки, страницы
///   читалки, всё, что грузится через RemoteImage) и "Кеш страниц"
///   (по прямой просьбе — то же название, что и в референсе; технически
///   это URLCache.shared, JSON-ответы API — карточки тайтлов, списки глав
///   и т.д., а не картинки страниц читалки, они уже покрыты первым пунктом).
/// - "История поиска" — в этом приложении история поиска пока не ведётся
///   вообще, поэтому честно "Нет данных" вместо кнопки очистки.
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
///   безопасно чистится, не трогая ничего из списка "Загрузки". Пока их
///   нет — честно "Нет данных" вместо кнопки очистки нуля байт.
struct StorageSettingsView: View {
    @ObservedObject private var downloads = DownloadsManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var stats = Stats()
    @State private var showClearAllCachesConfirm = false
    @State private var showClearDownloadsCacheConfirm = false

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
                cardHeader(title: "Хранилище устройства", value: "Доступно \(Self.byteString(stats.availableCapacity))")

                storageBar

                VStack(alignment: .leading, spacing: 8) {
                    legendRow(color: .blue, title: "Другие приложения", bytes: stats.otherAppsBytes)
                    legendRow(color: .green, title: "Скачанные тайтлы", bytes: stats.downloadsBytes)
                    legendRow(color: Theme.textSecondary, title: "Кеш", bytes: stats.cacheBytes)
                }
            }
            .padding(16)

            Divider().overlay(Theme.separator).padding(.horizontal, 16)

            dataRow(title: "Кеш изображений", trailing: .clear(bytes: stats.imageCacheBytes) {
                RemoteImageLoader.clearImageCache()
                refresh()
            })
            dataRow(title: "Кеш страниц", trailing: .clear(bytes: stats.apiCacheBytes) {
                URLCache.shared.removeAllCachedResponses()
                refresh()
            })
            dataRow(title: "История поиска", trailing: .empty)
            dataRow(
                title: "Кеш данных",
                subtitle: "Очистка может помочь при различных проблемах",
                trailing: .clear(bytes: nil) { showClearAllCachesConfirm = true },
                showDivider: false
            )
        }
        .confirmationDialog("Очистить весь кеш приложения?", isPresented: $showClearAllCachesConfirm, titleVisibility: .visible) {
            Button("Очистить кеш", role: .destructive) {
                Self.clearAllCaches()
                refresh()
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    /// Полоска — реальная пропорция от ВСЕЙ ёмкости диска, единым цельным
    /// столбиком без единого зазора: сегменты (другие приложения → скачанные
    /// тайтлы → кеш → свободное место) идут строго вплотную друг к другу от
    /// начала до самого конца. Никакой отдельной "палочки"-разделителя между
    /// занятым и свободным нет — граница просто прямой (не скруглённый,
    /// "|"-образный) стык двух цветов: скругление — только у самой полоски
    /// целиком по краям (clipShape(Capsule())), у внутренних сегментов углов
    /// нет вообще. Свободное место — это ОСТАТОК до конца ширины (а не своя
    /// пропорция), чтобы полоска гарантированно доходила до самого конца
    /// без хвоста фона карточки, даже если другие сегменты чуть округлились.
    /// У любого ненулевого сегмента — минимальная видимая ширина: иначе
    /// совсем маленький объём (доли МБ на фоне сотен ГБ ёмкости) при
    /// округлении пропорции пропадал бы совсем, а он должен быть виден хоть
    /// тонкой полоской.
    private var storageBar: some View {
        let total = max(1, stats.totalCapacity)
        return GeometryReader { geo in
            let fullWidth = geo.size.width
            let otherW = barWidth(bytes: stats.otherAppsBytes, total: total, fullWidth: fullWidth)
            let downloadsW = barWidth(bytes: stats.downloadsBytes, total: total, fullWidth: fullWidth)
            let cacheW = barWidth(bytes: stats.cacheBytes, total: total, fullWidth: fullWidth)
            let freeW = max(0, fullWidth - otherW - downloadsW - cacheW)

            HStack(spacing: 0) {
                Rectangle().fill(.blue).frame(width: otherW)
                Rectangle().fill(.green).frame(width: downloadsW)
                Rectangle().fill(Theme.textSecondary.opacity(0.6)).frame(width: cacheW)
                Rectangle().fill(Color.gray.opacity(0.25)).frame(width: freeW)
            }
            .frame(width: fullWidth, height: 10)
            .clipShape(Capsule())
        }
        .frame(height: 10)
    }

    /// Минимум 3pt для любого ненулевого сегмента — гарантированно видимая
    /// тонкая полоска, даже если реальная доля от общей ёмкости диска
    /// округляется до долей пикселя.
    private func barWidth(bytes: Int64, total: Int64, fullWidth: CGFloat) -> CGFloat {
        guard bytes > 0 else { return 0 }
        let raw = fullWidth * CGFloat(bytes) / CGFloat(total)
        return max(raw, 3)
    }

    private func legendRow(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 8) {
            // Та же высота, что и у самой полоски (storageBar) — по просьбе.
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.footnote).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            Text(Self.byteString(bytes)).font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Загрузки

    private var downloadsCard: some View {
        card {
            cardHeader(title: "Загрузки", value: "Занято \(Self.byteString(stats.downloadsBytes))")
                .padding(16)

            Divider().overlay(Theme.separator).padding(.horizontal, 16)

            // На iOS нет альтернативного места хранения — строка
            // информационная, без перехода (переход подразумевал бы выбор,
            // которого тут физически не может быть).
            plainRow(title: "Путь загрузки", value: "Хранилище устройства")

            Toggle(isOn: $downloads.wifiOnlyDownloads) {
                Text("Скачивать только через Wi-Fi").foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(Theme.separator).padding(.horizontal, 16)

            // Байт тут намеренно не показываем (просто "Очистить"/"Нет
            // данных") — это тот же самый объём, что уже показан в легенде
            // хранилища как "Скачанные тайтлы", дублировать цифру незачем.
            dataRow(
                title: "Кеш загрузки",
                subtitle: "Остатки отменённых/недокачанных глав",
                trailing: stats.orphanedDownloadBytes > 0
                    ? .clear(bytes: nil) { showClearDownloadsCacheConfirm = true }
                    : .empty,
                showDivider: false
            )
        }
        .confirmationDialog("Подтвердите действие", isPresented: $showClearDownloadsCacheConfirm, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                downloads.clearOrphanedDownloads()
                refresh()
            }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Вы действительно хотите очистить кеш загрузки? Отменятся все загрузки на паузе")
        }
    }

    // MARK: Общее

    // Радиус — тот же, что и у карточек в разделе "Меню" (см.
    // SideMenuView.cardCornerRadius) — это эталон, под него выравниваем.
    private static let cardCornerRadius: CGFloat = 24

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
    }

    /// Заголовок карточки (первая строка внутри самой card) — один и тот же
    /// стиль что у "Хранилище устройства", что у "Загрузки", а размер
    /// шрифта — как у заголовков разделов в Меню/Настройках (.headline).
    private func cardHeader(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Информационная строка без действия (например "Путь загрузки") — та же
    /// вертикальная сетка (горизонтальный паддинг 16, вертикальный 14), что
    /// и у dataRow ниже, чтобы разделители по всей карточке шли на равных
    /// расстояниях друг от друга.
    private func plainRow(title: String, value: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(value).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.horizontal, 16)
            }
        }
    }

    /// Правая часть dataRow: либо рабочая кнопка-чип "Очистить [X]", либо
    /// такой же по размеру, но неактивный чип "Нет данных" — для разделов,
    /// где показывать нечего (История поиска — функциональность пока не
    /// реализована; Кеш загрузки — мусора реально нет).
    private enum RowTrailing {
        case clear(bytes: Int64?, action: () -> Void)
        case empty
    }

    /// Строка "название [+ подпись] — чип справа" — единая вертикальная
    /// сетка (горизонтальный паддинг 16, вертикальный 14) для ВСЕХ строк с
    /// чипом (Кеш изображений/Кеш страниц/История поиска/Кеш данных/Кеш
    /// загрузки), чтобы разделители между ними были на равных расстояниях
    /// друг от друга независимо от того, есть ли у конкретной строки
    /// подпись вторым слоем — раньше из-за смешения minHeight с
    /// одно-/двухстрочным содержимым текст в блоках "плавал".
    private func dataRow(title: String, subtitle: String? = nil, trailing: RowTrailing, showDivider: Bool = true) -> some View {
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
                trailingPill(trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if showDivider {
                Divider().overlay(Theme.separator).padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func trailingPill(_ trailing: RowTrailing) -> some View {
        switch trailing {
        case .clear(let bytes, let action):
            Button(action: action) {
                Text(bytes.map { "Очистить \(Self.byteString($0))" } ?? "Очистить")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.surface, in: Capsule())
            }
        case .empty:
            // Тот же размер чипа, что и у "Очистить [X]" — просто
            // неактивная надпись "Нет данных" (ждёт появления данных).
            Button {} label: {
                Text("Нет данных")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.surface, in: Capsule())
            }
            .disabled(true)
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
