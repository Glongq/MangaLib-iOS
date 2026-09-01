import SwiftUI

/// «Спец фильтр» — раздел настроек, но САМ выбор жанров/тегов здесь не
/// делается (по прямой просьбе — не плодить второй выбор отдельно от
/// каталога): это просто вкл/выкл-флаг (см. SpecialFilterStore). Жанры/теги
/// как выбирались, так и выбираются в обычной шторке "Фильтры" каталога —
/// флаг только меняет, как каталог их применяет (см. CatalogViewModel/
/// SpecialFilterEngine).
struct SpecialFilterSettingsView: View {

    @ObservedObject private var store = SpecialFilterStore.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    explanationCard
                    toggleCard
                }
                .padding(16)
            }
        }
        .navigationTitle("Спец фильтр")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Как это работает")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Обычные Фильтры каталога ищут тайтлы, у которых совпали ВСЕ выбранные жанры/теги сразу — если хоть один не подошёл, тайтл вообще не покажется. Этот флаг ничего не меняет в самом выборе — жанры/теги вы выбираете там же, в Фильтрах каталога, — а меняет то, как каталог их применяет.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("Включите — и каталог сначала покажет тайтлы с максимальным числом совпадений из выбранного, затем с чуть меньшим. Если какой-то из выбранных пунктов не нашёлся у тайтла, это не страшно, главное — общее попадание. Имеет смысл при 2 и более выбранных жанрах/тегах сразу.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var toggleCard: some View {
        HStack {
            Text("Спец фильтр в каталоге")
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: $store.isEnabled)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        SpecialFilterSettingsView()
    }
    .preferredColorScheme(.dark)
}
