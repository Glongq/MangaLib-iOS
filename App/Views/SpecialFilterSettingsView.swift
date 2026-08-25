import SwiftUI

/// «Спец фильтр» — раздел настроек (не шторка каталога, по прямой просьбе):
/// выбираешь желаемые жанры/теги, каталог сам ищет сначала тайтлы с
/// максимальным числом совпадений, потом чуть меньше — вместо строгого
/// "всё сразу или ничего", как в обычных Фильтрах каталога (см.
/// SpecialFilterStore/SpecialFilterEngine — сервер такого сам не умеет,
/// эмулируется полностью на клиенте несколькими запросами).
struct SpecialFilterSettingsView: View {

    @ObservedObject private var store = SpecialFilterStore.shared
    @ObservedObject private var constants = ConstantsStore.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    explanationCard
                    toggleCard
                    multiSelectSection
                    resetRow
                }
                .padding(16)
            }
        }
        .navigationTitle("Спец фильтр")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        // Экран может быть первым, где нужны реальные жанры/теги (открыт
        // прямо из Настроек, минуя Каталог) — без этого список был бы на
        // резервных id из FilterCatalog вместо настоящих серверных.
        .task { ConstantsStore.shared.loadIfNeeded() }
    }

    // MARK: Пояснение

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Как это работает")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Обычные Фильтры каталога ищут тайтлы, у которых совпали ВСЕ выбранные жанры/теги сразу — если хоть один не подошёл, тайтл вообще не покажется. Здесь наоборот: сначала показываются тайтлы с максимальным числом совпадений, затем — с чуть меньшим. Если какой-то из выбранных пунктов не нашёлся у тайтла, это не страшно, главное — общее попадание.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Text("Работает вместо обычного выбора жанров/тегов в Фильтрах каталога, остальные фильтры (год, статус и т.д.) применяются как обычно.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Включение

    private var toggleCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Спец фильтр в каталоге")
                    .foregroundStyle(Theme.textPrimary)
                if store.isEnabled && store.selectedCount < 2 {
                    Text("Выберите хотя бы 2 пункта ниже")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: $store.isEnabled)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Жанры и теги

    private var multiSelectSection: some View {
        VStack(spacing: 0) {
            NavigationLink {
                TriStateFilterView(title: "Жанры", options: constants.genres, selection: genresBinding)
            } label: {
                selectRow(title: "Жанры", selection: store.genres)
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.separator)

            NavigationLink {
                TriStateFilterView(title: "Теги", options: constants.tags, selection: tagsBinding)
            } label: {
                selectRow(title: "Теги", selection: store.tags)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Не даём набрать больше SpecialFilterStore.maxSelection включённых
    /// пунктов суммарно (жанры + теги) — перебор подмножеств в
    /// SpecialFilterEngine растёт комбинаторно с их числом. Снимать выбор
    /// (уменьшать included) и переключать в исключения — всегда можно, лимит
    /// блокирует только ДОБАВЛЕНИЕ сверху.
    private var genresBinding: Binding<TriStateSelection> {
        Binding(
            get: { store.genres },
            set: { newValue in
                let adding = newValue.included.count > store.genres.included.count
                let total = newValue.included.count + store.tags.included.count
                guard !adding || total <= SpecialFilterStore.maxSelection else { return }
                store.genres = newValue
            }
        )
    }

    private var tagsBinding: Binding<TriStateSelection> {
        Binding(
            get: { store.tags },
            set: { newValue in
                let adding = newValue.included.count > store.tags.included.count
                let total = newValue.included.count + store.genres.included.count
                guard !adding || total <= SpecialFilterStore.maxSelection else { return }
                store.tags = newValue
            }
        )
    }

    private func selectRow(title: String, selection: TriStateSelection) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if selection.count == 0 {
                Text("Не выбрано").font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                if !selection.included.isEmpty {
                    countBadge(selection.included.count, color: .green, icon: "plus")
                }
                if !selection.excluded.isEmpty {
                    countBadge(selection.excluded.count, color: .red, icon: "minus")
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private func countBadge(_ n: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text("\(n)").font(.caption2.weight(.bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var resetRow: some View {
        Button {
            store.reset()
        } label: {
            Text("Сбросить выбор")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        SpecialFilterSettingsView()
    }
    .preferredColorScheme(.dark)
}
