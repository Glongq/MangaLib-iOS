import SwiftUI

/// Sheet со всеми названиями тайтла — открывается по тапу на название в шапке
/// карточки (см. MangaDetailView.titleBlock). Показывает: название на русском,
/// оригинальное, на английском и список альтернативных названий.
///
/// Альтернативные названия — пока по сути заглушка: реального подтверждённого
/// поля API нет (см. MangaDetail.otherNames), поэтому если сервер их не прислал,
/// секция показывает "Нет данных", но сам sheet и его структура уже на месте.
struct TitleNamesSheet: View {

    let rusName: String?
    let originalName: String?
    let engName: String?
    let otherNames: [String]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                nameSection("Название на русском", value: rusName, showClose: true)
                nameSection("Оригинальное название", value: originalName)
                nameSection("Название на английском", value: engName)
                alternativeSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
        .presentationDragIndicator(.visible)
    }

    /// Одна секция «подпись + значение + разделитель». Значение показывается
    /// только если непустое (например, у тайтла может не быть отдельного
    /// английского названия). У самой первой секции справа — кнопка-крестик.
    @ViewBuilder
    private func nameSection(_ label: String, value: String?, showClose: Bool = false) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    if showClose {
                        Button { dismiss() } label: {
                            // 16→15 — тот же размер, что у CreditsSheet/
                            // TeamMembersSheet/AdditionalInfoSheet и т.д.,
                            // по прямой просьбе выровнять.
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider().overlay(Theme.separator).padding(.top, 10)
            }
            .padding(.top, 16)
        }
    }

    /// Список альтернативных названий — каждое на своей строке. Если данных нет
    /// (частый случай, пока поле API не подтверждено) — показываем "Нет данных".
    private var alternativeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Альтернативное название")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 6)

            if otherNames.isEmpty {
                Text("Нет данных")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(otherNames.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        TitleNamesSheet(
            rusName: "Поднятие уровня в одиночку",
            originalName: "Na Honjaman Lebel-eob",
            engName: "Solo Leveling",
            otherNames: [
                "I Alone Level-Up", "I Level Up Alone", "Only I Level Up",
                "Соло Левелинг", "Я один повышаю свой уровень"
            ]
        )
        .presentationDetents([.medium, .large])
    }
}
