import SwiftUI

/// Sheet «Скачать тайтл» — открывается из меню "..." в шапке карточки (см.
/// MangaDetailView). Выбор сервера/сжатия и переводчика — пока ЗАГЛУШКА (на
/// эти параметры реальная загрузка не завязана), но сама загрузка настоящая:
/// кнопка «Скачать» ставит ВСЕ главы тайтла в очередь DownloadsManager, который
/// реально качает страницы и складывает их структурировано на устройство.
/// Прогресс и список скачанного видно в разделе «Загрузки» (см. DownloadsView).
struct DownloadTitleSheet: View {

    let slug: String
    let coverURL: URL?
    let title: String
    let typeLabel: String?
    let chapters: [ChapterItem]

    @Environment(\.dismiss) private var dismiss

    private var chaptersCount: Int { chapters.count }

    // MARK: Выбор параметров

    /// Сервер картинок (Первый/Второй/Сжатия) — общий с читалкой (см.
    /// ImageServerChoice/ReaderSettingsSheet). Реально влияет на то, откуда
    /// качаются страницы (MangaImageURL.pageURLs).
    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0

    private enum ChapterScope: String, CaseIterable, Identifiable {
        case all = "Все"
        case unread = "Непрочитанное"
        var id: String { rawValue }
    }
    @State private var chapterScope: ChapterScope = .all
    @State private var chapterScopeExpanded = false

    /// Заглушка списка переводчиков: пара «команд» + ВСЕГДА «Неизвестный» с 0
    /// глав в самом низу (как попросили).
    private struct Translator: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let chapters: Int
    }
    private let translators: [Translator] = [
        .init(name: "Команда перевода", chapters: 34),
        .init(name: "Solo Scans", chapters: 12),
        .init(name: "Неизвестный", chapters: 0)
    ]
    @State private var selectedTranslator: Translator?
    @State private var translatorListExpanded = false

    private var activeTranslator: Translator { selectedTranslator ?? translators.first! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider().overlay(Theme.separator)
                serverSection
                chapterScopeSection
                translatorSection
                downloadButton
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
        .presentationDragIndicator(.visible)
    }

    // MARK: Шапка — обложка + название/тип/кол-во глав

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 74, height: 104)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let typeLabel, !typeLabel.isEmpty {
                    Text(typeLabel)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("\(chaptersCount) глав")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: «Сервер» — выпадающий выбор сжатия (остался системным Menu)

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Сервер")
            Menu {
                Picker("Сервер", selection: $serverChoice) {
                    ForEach(ImageServerChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } label: {
                selectorLabel(ImageServerChoice(rawValue: serverChoice)?.title ?? "Первый")
            }
        }
    }

    // MARK: «Главы» — раскрывающийся вниз список (как переводчик)

    private var chapterScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Главы")
            // Единый цельный блок: шапка + (если раскрыт) варианты внутри той
            // же скруглённой подложки, разделители во всю ширину.
            VStack(spacing: 0) {
                expandHeaderRow(text: chapterScope.rawValue, expanded: chapterScopeExpanded) {
                    withAnimation(.easeInOut(duration: 0.2)) { chapterScopeExpanded.toggle() }
                }
                if chapterScopeExpanded {
                    ForEach(ChapterScope.allCases) { scope in
                        rowDivider
                        optionRow(text: scope.rawValue, selected: scope == chapterScope) {
                            chapterScope = scope
                            withAnimation(.easeInOut(duration: 0.2)) { chapterScopeExpanded = false }
                        }
                    }
                }
            }
            .modifier(BlockContainer())
        }
    }

    // MARK: «Переводчик» — раскрывающийся вниз список, единым блоком

    private var translatorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Переводчик")
            VStack(spacing: 0) {
                translatorRow(activeTranslator, isHeader: true, selected: false) {
                    withAnimation(.easeInOut(duration: 0.2)) { translatorListExpanded.toggle() }
                }
                if translatorListExpanded {
                    ForEach(translators) { t in
                        rowDivider
                        translatorRow(t, isHeader: false, selected: t.id == activeTranslator.id) {
                            selectedTranslator = t
                            withAnimation(.easeInOut(duration: 0.2)) { translatorListExpanded = false }
                        }
                    }
                }
            }
            .modifier(BlockContainer())
        }
    }

    private func translatorRow(_ t: Translator, isHeader: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.footnote)
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 22)

                Text(t.name)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                countChip("\(t.chapters)", background: Theme.surface, foreground: Theme.textSecondary)

                if isHeader {
                    Image(systemName: translatorListExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Кнопка «Скачать» + чип кол-ва глав

    private var downloadButton: some View {
        Button {
            // Ставим ВСЕ главы тайтла в реальную очередь загрузки. Параметры
            // сервера/переводчика/объёма — пока не влияют (заглушка), качаем всё.
            DownloadsManager.shared.download(
                slug: slug,
                title: title,
                typeLabel: typeLabel,
                coverURLString: coverURL?.absoluteString,
                chapters: chapters
            )
            dismiss()
        } label: {
            ZStack {
                Text("Скачать")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)

                HStack {
                    Spacer()
                    // Чип чуть светлее самой кнопки — как попросили.
                    countChip("\(chaptersCount)", background: .white.opacity(0.25), foreground: .white)
                }
                .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(chapters.isEmpty)
        .opacity(chapters.isEmpty ? 0.5 : 1)
        .padding(.top, 4)
    }

    // MARK: Общие строки/хелперы

    /// Скруглённая подложка для «единого» раскрывающегося блока + clip, чтобы
    /// разделители внутри не вылезали за скругления.
    private struct BlockContainer: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.separator)
    }

    private func expandHeaderRow(text: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func optionRow(text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
    }

    private func selectorLabel(_ value: String) -> some View {
        HStack {
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .frame(maxWidth: .infinity)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func countChip(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }
}
