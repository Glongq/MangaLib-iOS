import SwiftUI

/// Sheet «Скачать тайтл» — открывается из меню "..." в шапке карточки (см.
/// MangaDetailView). ПОКА ПОЛНОСТЬЮ ЗАГЛУШКА: реального скачивания глав нет,
/// весь UI (выбор сервера/сжатия, объёма глав, переводчика) работает локально
/// на @State и ничего не качает — кнопка «Скачать» просто закрывает sheet.
/// Структура и вид уже на месте, чтобы позже подключить настоящую загрузку.
struct DownloadTitleSheet: View {

    let coverURL: URL?
    let title: String
    let typeLabel: String?
    let chaptersCount: Int

    @Environment(\.dismiss) private var dismiss

    // MARK: Локальный (заглушечный) выбор параметров

    /// Варианты «сервера/сжатия» — имена условные, до подключения реального API.
    private let servers = ["Сжатия первый", "Сжатия второй"]
    @State private var selectedServer = "Сжатия первый"

    private enum ChapterScope: String, CaseIterable, Identifiable {
        case all = "Все"
        case unread = "Непрочитанное"
        var id: String { rawValue }
    }
    @State private var chapterScope: ChapterScope = .all

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

    /// Сколько глав реально «скачается» — заглушка: у выбранного переводчика.
    private var downloadableCount: Int { activeTranslator.chapters }

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

    // MARK: «Сервер» — выпадающий выбор сжатия

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Сервер")
            Menu {
                Picker("Сервер", selection: $selectedServer) {
                    ForEach(servers, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                selectorLabel(selectedServer)
            }
        }
    }

    // MARK: «Главы» — все / непрочитанное

    private var chapterScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Главы")
            Menu {
                Picker("Главы", selection: $chapterScope) {
                    ForEach(ChapterScope.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                selectorLabel(chapterScope.rawValue)
            }
        }
    }

    // MARK: «Переводчик» — разворачивающийся список

    private var translatorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Переводчик")

            // Текущий выбранный переводчик — тап разворачивает/сворачивает список.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { translatorListExpanded.toggle() }
            } label: {
                translatorRow(activeTranslator, showChevron: true)
            }
            .buttonStyle(.plain)

            if translatorListExpanded {
                VStack(spacing: 0) {
                    ForEach(translators) { t in
                        Button {
                            selectedTranslator = t
                            withAnimation(.easeInOut(duration: 0.2)) { translatorListExpanded = false }
                        } label: {
                            translatorRow(t, showChevron: false, selected: t == activeTranslator)
                        }
                        .buttonStyle(.plain)

                        if t.id != translators.last?.id {
                            Divider().overlay(Theme.separator).padding(.leading, 42)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func translatorRow(_ t: Translator, showChevron: Bool, selected: Bool = false) -> some View {
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

            countChip("\(t.chapters)", background: Theme.surfaceElevated, foreground: Theme.textSecondary)

            if showChevron {
                Image(systemName: translatorListExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Кнопка «Скачать» + чип кол-ва глав

    private var downloadButton: some View {
        Button {
            // ЗАГЛУШКА: реального скачивания нет — просто закрываем sheet.
            dismiss()
        } label: {
            ZStack {
                Text("Скачать")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)

                HStack {
                    Spacer()
                    // Чип чуть светлее самой кнопки (белая полупрозрачная
                    // заливка поверх акцента) — как попросили.
                    countChip("\(downloadableCount)", background: .white.opacity(0.25), foreground: .white)
                }
                .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: Helpers

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
        .frame(minHeight: 48)
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

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        DownloadTitleSheet(
            coverURL: nil,
            title: "Игра Абсолютного Бога",
            typeLabel: "Манга",
            chaptersCount: 35
        )
        .presentationDetents([.medium, .large])
    }
}
