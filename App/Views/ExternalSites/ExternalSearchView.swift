import SwiftUI

/// Каталог-экран для внешних сайтов со свободным текстовым поиском вместо
/// алфавитного справочника (capabilities.hasSearch && !hasTagBrowser — см.
/// EHentaiProvider; у hitomi наоборот, см. ExternalTagBrowserView). Поле
/// ввода + пилюля «Фильтры» (визуально — 1-в-1 MangaCatalogView.controlsBar/
/// controlLabel, см. по прямой просьбе 30.08 "перенеси фулл вид каталог из
/// обычного каталога") — по-прежнему БЕЗ отдельного перехода: тайтлы
/// появляются сразу под полем (см. ExternalCatalogGridView(embedded: true)),
/// с небольшой задержкой после последнего нажатия клавиши (debounce).
struct ExternalSearchView: View {
    let site: ExternalSite

    @ObservedObject private var filterStore = ExternalCatalogFilterStore.shared
    @State private var query = ""
    /// Запрос, который реально сейчас ищется — отдельно от `query` (что
    /// набрано в поле прямо сейчас), чтобы не дёргать сеть на КАЖДОЕ
    /// нажатие клавиши (см. .task(id: query) ниже — debounce).
    @State private var committedQuery = ""
    @State private var showFilters = false
    @FocusState private var isFocused: Bool

    private var capabilities: ExternalSiteCapabilities { ExternalSiteRegistry.provider(for: site).capabilities }
    private var excludedCategories: Set<EHentaiCategory> {
        get { filterStore.excludedCategories[site] ?? [] }
        nonmutating set { filterStore.excludedCategories[site] = newValue }
    }
    private var excludedCategoryBits: Int { excludedCategories.reduce(0) { $0 | $1.bit } }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if capabilities.hasCategoryFilter {
                controlsBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            // Пустой запрос — не "Введите запрос", а лента "Recently" (см.
            // HitomiProvider/EHentaiProvider.fetchIdsBySearch с пустым query)
            // — тайтлы видны сразу, без необходимости сначала что-то ввести.
            // .id — принудительно НОВЫЙ экземпляр вью на каждое изменение
            // запроса/категорий, чтобы @State сетки (items/cursors/...)
            // сбрасывался и .task заново запускал загрузку — простая смена
            // параметра `query:` этого не делает, SwiftUI считает это ТЕМ ЖЕ
            // вью на том же месте дерева.
            ExternalCatalogGridView(site: site, query: .search(query: committedQuery, excludedCategoryBits: excludedCategoryBits), title: committedQuery.isEmpty ? "Recently" : committedQuery, embedded: true)
                .id("\(committedQuery)#\(excludedCategoryBits)")
        }
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showFilters) {
            filtersSheet
        }
        .onAppear {
            // Восстанавливаем то, что реально набрано/выбрано в прошлый раз
            // (см. ExternalCatalogFilterStore) — экран пересоздаётся при
            // уходе/возврате на вкладку Каталог, query/committedQuery как
            // обычный @State иначе сбрасывались бы каждый раз.
            query = filterStore.queries[site] ?? ""
            committedQuery = query
        }
        .task(id: query) {
            // Debounce — 400мс тишины после последнего нажатия, иначе
            // каждая буква била бы отдельным сетевым запросом. .task(id:)
            // сам отменяет предыдущую попытку, когда query меняется снова
            // раньше, чем истекли эти 400мс.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            committedQuery = query.trimmingCharacters(in: .whitespaces)
            filterStore.queries[site] = committedQuery
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Название, тег, автор…", text: $query)
                .focused($isFocused)
                .foregroundStyle(Theme.textPrimary)
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
    }

    // MARK: Фильтры — 1-в-1 MangaCatalogView.controlsBar/controlLabel
    // (стеклянная пилюля с иконкой + бейдж числа исключённых категорий),
    // тап открывает лист с переключателями (EHentaiCategoryPicker) — раньше
    // сами кнопки категорий были всегда на экране, теперь как и в обычном
    // каталоге: спрятаны за "Фильтры".

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                showFilters = true
            } label: {
                controlLabel(icon: "slider.horizontal.3", text: "Фильтры", badge: excludedCategories.count)
            }
            Spacer(minLength: 0)
        }
    }

    private func controlLabel(icon: String, text: String, badge: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Theme.accent, in: Circle())
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var filtersSheet: some View {
        NavigationStack {
            ScrollView {
                EHentaiCategoryPicker(excluded: Binding(
                    get: { excludedCategories },
                    set: { excludedCategories = $0 }
                ))
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showFilters = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    NavigationStack {
        ExternalSearchView(site: .ehentai)
    }
    .preferredColorScheme(.dark)
}
