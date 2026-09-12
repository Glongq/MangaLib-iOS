import SwiftUI

/// ВРЕМЕННЫЙ debug-экран (по просьбе, на время тестирования) — живой журнал
/// ВСЕХ сетевых запросов приложения (см. NetworkLogger.swift). Доступен из
/// Настроек (см. AppSettingsView.debugAuthCard рядом). Убрать перед релизом.
struct NetworkLogsView: View {
    @ObservedObject private var logger = NetworkLogger.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var showErrorsOnly = false
    @State private var expandedID: UUID?
    @State private var showCopiedToast = false
    /// Укороченные логи — при копировании (и всё, и одной записи) берём
    /// только заголовок (метод/путь/статус/время), без тел запроса/ответа —
    /// по просьбе, полные тела при большом количестве записей весят слишком
    /// много для вставки в чат.
    @State private var compactLogs = false

    private var filteredEntries: [NetworkLogger.Entry] {
        showErrorsOnly ? logger.entries.filter(\.isError) : logger.entries
    }

    /// Текст одной записи для копирования — с телами или без, в зависимости
    /// от тумблера "Короткие логи" выше.
    private func copyText(for entry: NetworkLogger.Entry) -> String {
        compactLogs ? entry.summaryOnlyText : entry.fullText
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $showErrorsOnly) {
                    Text("Все (\(logger.entries.count))").tag(false)
                    Text("Только ошибки (\(logger.entries.filter(\.isError).count))").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Toggle("Короткие логи (только заголовки)", isOn: $compactLogs)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                if filteredEntries.isEmpty {
                    Spacer()
                    Text(showErrorsOnly ? "Ошибок пока нет" : "Запросов пока нет")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredEntries) { entry in
                                entryRow(entry)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }

            if showCopiedToast {
                VStack {
                    Text("Скопировано")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceElevated, in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("Логи сети (debug)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        copyToClipboard(text: filteredEntries.map(copyText(for:)).joined(separator: "\n\n---\n\n"))
                    } label: {
                        Label("Скопировать всё (\(showErrorsOnly ? "ошибки" : "всё"))", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        logger.clear()
                    } label: {
                        Label("Очистить журнал", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func entryRow(_ entry: NetworkLogger.Entry) -> some View {
        let isExpanded = expandedID == entry.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedID = isExpanded ? nil : entry.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.method)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(entry.isError ? .red : Theme.accent)
                        Text(entry.pathOnly)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(isExpanded ? nil : 1)
                        Spacer(minLength: 0)
                        if let statusCode = entry.statusCode {
                            Text("\(statusCode)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(entry.isError ? .red : .green)
                        } else {
                            Text("нет ответа")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                    HStack {
                        Text(entry.dateString)
                        Text("·")
                        Text(String(format: "%.0f мс", entry.duration * 1000))
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let errorText = entry.errorText {
                        detailBlock(title: "Ошибка", text: errorText)
                    }
                    if let body = entry.prettyRequestBody {
                        detailBlock(title: "Тело запроса", text: body)
                    }
                    if let body = entry.prettyResponseBody {
                        detailBlock(title: "Тело ответа", text: body)
                    }
                    Button {
                        copyToClipboard(text: copyText(for: entry))
                    } label: {
                        Label("Скопировать эту запись", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        // Тап по карточке МИМО текста лога (заголовок — свой Button на
        // схлопывание, тело лога — .textSelection(.enabled) в detailBlock,
        // сам перехватывает тап на себе) — копирует запись целиком.
        // Вложенные жесты (Button/textSelection) перехватывают тап раньше,
        // чем он дойдёт досюда, поэтому конфликта с ними нет — сработает
        // только там, где под пальцем ничего кликабельного/выделяемого нет
        // (паддинги, подписи блоков).
        .onTapGesture {
            copyToClipboard(text: copyText(for: entry))
        }
        // Долгое нажатие — то же самое, но привычным жестом (было раньше).
        .contextMenu {
            Button {
                copyToClipboard(text: copyText(for: entry))
            } label: {
                Label("Скопировать эту запись", systemImage: "doc.on.doc")
            }
        }
    }

    /// По уточнению: именно текст ЛОГА (тело запроса/ответа/ошибки) должен
    /// выделяться как обычный текст (драг + системное меню «Скопировать»),
    /// а не копироваться целиком одним тапом — .textSelection(.enabled), а
    /// не Button. Тап "мимо текста, но внутри карточки" (см. entryRow.
    /// onTapGesture) по-прежнему копирует запись целиком.
    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func copyToClipboard(text: String) {
        UIPasteboard.general.string = text
        withAnimation(.easeInOut(duration: 0.15)) { showCopiedToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.15)) { showCopiedToast = false }
        }
    }
}

#Preview {
    NavigationStack { NetworkLogsView() }
        .preferredColorScheme(.dark)
}
