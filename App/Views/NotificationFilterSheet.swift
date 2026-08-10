import SwiftUI

/// Sheet сортировки/фильтра уведомлений (открывается кнопкой внизу слева на
/// NotificationsView) — два независимых блока с круглыми чек-боксами
/// (радио-поведение — можно выбрать только ОДИН пункт в каждом блоке),
/// разделённые тонкой полосой, как попросили:
///   1) Прочитанность: Непрочитанные (по умолчанию) / Прочитанные / Все —
///      реально уходит на сервер как read_type (см. NotificationReadFilter).
///   2) Порядок: Сначала новые / Сначала старые — уходит как sort_type (см.
///      NotificationSortOrder).
/// Выбор применяется СРАЗУ по тапу (не нужна отдельная кнопка "Применить") —
/// Binding напрямую в NotificationsViewModel.readFilter/sortOrder, чьи
/// didSet уже сами перезапускают refresh() (см. NotificationsViewModel).
struct NotificationFilterSheet: View {
    @Binding var readFilter: NotificationReadFilter
    @Binding var sortOrder: NotificationSortOrder

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(NotificationReadFilter.allCases) { option in
                        radioRow(title: option.title, isSelected: readFilter == option) {
                            readFilter = option
                        }
                    }

                    Divider().overlay(Theme.separator).padding(.vertical, 8)

                    ForEach(NotificationSortOrder.allCases) { option in
                        radioRow(title: option.title, isSelected: sortOrder == option) {
                            sortOrder = option
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("Сортировка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .tint(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
    }

    /// Один пункт-радиокнопка: пустой/заполненный кружок + подпись, весь ряд кликабелен.
    private func radioRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NotificationFilterSheet(readFilter: .constant(.unread), sortOrder: .constant(.desc))
        .preferredColorScheme(.dark)
}
