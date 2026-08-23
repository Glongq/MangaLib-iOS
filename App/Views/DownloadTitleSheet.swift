import SwiftUI

/// Sheet «Скачать тайтл» — открывается из меню "..." в шапке карточки (см.
/// MangaDetailView). Сервер картинок реально влияет на загрузку (см.
/// serverChoice), переводчик и объём («Все»/«Непрочитанное») — тоже реальные
/// фильтры (см. chaptersToDownload/activeTranslator), а не заглушки: кнопка
/// «Скачать» ставит отфильтрованные главы в очередь DownloadsManager, который
/// реально качает страницы и складывает их структурировано на устройство.
/// Прогресс и список скачанного видно в разделе «Загрузки» (см. DownloadsView).
struct DownloadTitleSheet: View {

    let slug: String
    let coverURL: URL?
    /// «Хиро»-фон карточки тайтла (MangaDetail.backgroundURL) — качается вместе
    /// с обычной обложкой, чтобы офлайн-карточка тайтла выглядела 1-в-1.
    var heroURL: URL? = nil
    let title: String
    let typeLabel: String?
    let chapters: [ChapterItem]
    /// Сколько глав уже прочитано (позиция, см. MangaDetailView.isRead) — нужно
    /// для фильтра «Непрочитанное»: глава на позиции i (1-based) считается
    /// прочитанной, если i <= readCount.
    let readCount: Int

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    private var chaptersCount: Int { chapters.count }

    // MARK: Выбор параметров

    /// Сервер картинок (Первый/Второй/Сжатия) — общий с читалкой (см.
    /// ImageServerChoice/ReaderSettingsSheet). Реально влияет на то, откуда
    /// качаются страницы (MangaImageURL.pageURLs).
    @AppStorage(ImageServerChoice.defaultsKey) private var serverChoice = 0
    @State private var serverExpanded = false

    private enum ChapterScope: String, CaseIterable, Identifiable {
        case all = "Все"
        case unread = "Непрочитанное"
        var id: String { rawValue }
    }
    @State private var chapterScope: ChapterScope = .all
    @State private var chapterScopeExpanded = false

    /// Главы, отфильтрованные по chapterScope (без учёта переводчика).
    private var scopedChapters: [ChapterItem] {
        switch chapterScope {
        case .all: return chapters
        case .unread:
            return chapters.enumerated().filter { $0.offset + 1 > readCount }.map(\.element)
        }
    }

    /// Один переводчик тайтла: id — id команды (nil — «Все переводчики»,
    /// т.е. без фильтра по команде, качаем каждую главу её первой веткой),
    /// branchId — стабильный branch_id этой команды (см. ChapterListSheet.
    /// branchId(forTeam:) в MangaReaderView — тот же приём).
    private struct Translator: Identifiable, Hashable {
        let id: Int?
        let name: String
        let chapters: Int
        let branchId: Int?
    }

    /// Реальный список переводчиков тайтла — из branches/teams всех глав (та
    /// же информация, что использует читалка для смены переводчика, см.
    /// MangaReaderView.ChapterListSheet.allTeams), а НЕ отдельный API-запрос.
    /// Первый элемент — всегда «Все переводчики».
    private var translators: [Translator] {
        var seen = Set<Int>()
        var teams: [(team: ChapterTeam, branchId: Int?)] = []
        for chapter in chapters {
            for branch in chapter.branches ?? [] {
                for team in branch.teams ?? [] where !seen.contains(team.id) {
                    seen.insert(team.id)
                    teams.append((team, branch.branchId))
                }
            }
        }
        let all = Translator(id: nil, name: "Все переводчики", chapters: chaptersCount, branchId: nil)
        let named = teams.map { pair -> Translator in
            let count = chapters.filter { ch in
                (ch.branches ?? []).contains { b in (b.teams ?? []).contains { $0.id == pair.team.id } }
            }.count
            return Translator(id: pair.team.id, name: pair.team.name, chapters: count, branchId: pair.branchId)
        }
        return [all] + named
    }

    /// Показывать выбор переводчика только когда их реально ≥2 — при одном
    /// (или отсутствии данных о ветках) выбирать нечего, поле скрываем целиком.
    private var hasMultipleTranslators: Bool { translators.count > 2 }

    @State private var selectedTranslator: Translator?
    @State private var translatorListExpanded = false

    private var activeTranslator: Translator { selectedTranslator ?? translators.first! }

    /// Итоговый список глав к скачиванию: скоуп («Все»/«Непрочитанное») +
    /// фильтр по выбранному переводчику (если не «Все переводчики» — только
    /// главы, где реально есть его ветка).
    private var chaptersToDownload: [ChapterItem] {
        guard let teamId = activeTranslator.id else { return scopedChapters }
        return scopedChapters.filter { ch in
            (ch.branches ?? []).contains { b in (b.teams ?? []).contains { $0.id == teamId } }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider().overlay(Theme.separator)
                serverSection
                chapterScopeSection
                if hasMultipleTranslators {
                    translatorSection
                }
                downloadButton
            }
            // Больше отступ сверху (от «шапки» листа).
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 28)
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
            // Обложка увеличена в 1.5× (74×104 → 111×156).
            .frame(width: 111, height: 156)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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
            // Раскрывающийся вниз список — тот же паттерн, что и «Главы».
            VStack(spacing: 0) {
                expandHeaderRow(text: ImageServerChoice(rawValue: serverChoice)?.title ?? "Первый",
                                expanded: serverExpanded) {
                    withAnimation(.easeInOut(duration: 0.2)) { serverExpanded.toggle() }
                }
                if serverExpanded {
                    ForEach(ImageServerChoice.allCases) { choice in
                        rowDivider
                        optionRow(text: choice.title, selected: choice.rawValue == serverChoice) {
                            serverChoice = choice.rawValue
                            withAnimation(.easeInOut(duration: 0.2)) { serverExpanded = false }
                        }
                    }
                }
            }
            .modifier(BlockContainer())
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
            // Ставим отфильтрованные (скоуп + переводчик) главы в реальную
            // очередь загрузки, все — выбранной веткой переводчика.
            DownloadsManager.shared.download(
                slug: slug,
                title: title,
                typeLabel: typeLabel,
                coverURLString: coverURL?.absoluteString,
                heroURLString: heroURL?.absoluteString,
                chapters: chaptersToDownload,
                branchId: activeTranslator.branchId
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
                    countChip("\(chaptersToDownload.count)", background: .white.opacity(0.25), foreground: .white)
                }
                .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(chaptersToDownload.isEmpty)
        .opacity(chaptersToDownload.isEmpty ? 0.5 : 1)
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
