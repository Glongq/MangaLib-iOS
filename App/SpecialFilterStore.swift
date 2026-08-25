import Foundation
import Combine

/// Настройка уровня приложения (как ThemeManager/SiteSession, а не часть
/// MangaFilter — тот сбрасывается при каждой смене сайта/поиске, см.
/// CatalogViewModel.resetFilters, а спец-фильтр должен пережить и то, и
/// другое) — включён/выключен + выбранные жанры/теги для «Спец фильтра».
///
/// Смысл фичи (по прямой просьбе): сервер по умолчанию требует ТОЧНОГО
/// совпадения ВСЕХ переданных genres[]/tags[] сразу (AND) — никакого
/// настоящего "мягкого"/ранжированного поиска на сервере нет (см. подробный
/// комментарий в MangaNetworkService.fetchCatalog про "Строгое совпадение" —
/// параметр tags_soft_search реальный, но не управляется нами и эффекта на
/// результаты не показал). «Спец фильтр» эмулирует такое ранжирование
/// целиком на клиенте — см. SpecialFilterEngine.
@MainActor
final class SpecialFilterStore: ObservableObject {

    static let shared = SpecialFilterStore()

    @Published var isEnabled: Bool { didSet { persist() } }
    @Published var genres = TriStateSelection() { didSet { persist() } }
    @Published var tags = TriStateSelection() { didSet { persist() } }

    /// Перебор подмножеств в SpecialFilterEngine растёт комбинаторно от
    /// размера выбора — ограничиваем количество включённых пунктов заранее
    /// (см. использование в SpecialFilterSettingsView).
    static let maxSelection = 6

    var selectedCount: Int { genres.included.count + tags.included.count }

    /// Включён и есть смысл ранжировать (с одним пунктом это обычный фильтр
    /// без вариантов "выпадения").
    var isActive: Bool { isEnabled && selectedCount >= 2 }

    private static let key = "specialFilter.v1"

    private struct Snapshot: Codable {
        var isEnabled: Bool
        var includedGenres: [Int]
        var excludedGenres: [Int]
        var includedTags: [Int]
        var excludedTags: [Int]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            isEnabled = snap.isEnabled
            genres = TriStateSelection(included: Set(snap.includedGenres), excluded: Set(snap.excludedGenres))
            tags = TriStateSelection(included: Set(snap.includedTags), excluded: Set(snap.excludedTags))
        } else {
            isEnabled = false
        }
    }

    private func persist() {
        let snap = Snapshot(
            isEnabled: isEnabled,
            includedGenres: Array(genres.included), excludedGenres: Array(genres.excluded),
            includedTags: Array(tags.included), excludedTags: Array(tags.excluded)
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func reset() {
        genres.clear()
        tags.clear()
    }
}
