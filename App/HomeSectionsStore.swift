import Foundation

/// Разделы вкладки «Читают» (см. HomeView.content) — идентификатор для
/// порядка/видимости, настраиваемых в Персонализации (см.
/// PersonalizationSettingsView.homeSectionsCard). Сток-порядок и подписи —
/// по прямой просьбе пользователя.
enum HomeSectionKind: String, CaseIterable, Identifiable {
    case popular, continueReading, currentlyReading, collections, topActiveWeek, newest, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular:          return "Обновление популярных тайтлов"
        case .continueReading:  return "История"
        case .currentlyReading: return "Сейчас читают"
        case .collections:      return "Последние коллекции"
        case .topActiveWeek:    return "Топ активных недели"
        case .newest:           return "Новинки"
        case .updates:          return "Последние обновления"
        }
    }

    static let stockOrder: [HomeSectionKind] = [
        .popular, .continueReading, .currentlyReading, .collections, .topActiveWeek, .newest, .updates
    ]
}

/// Порядок и видимость разделов главной — настраивается в Персонализации
/// (см. PersonalizationSettingsView.homeSectionsCard), реально применяется
/// на вкладке «Читают» (см. HomeView.content). Локальное хранилище
/// (UserDefaults), тот же общий приём, что и BookmarksStore.folders —
/// массив id-строк + set скрытых id-строк.
@MainActor
final class HomeSectionsStore: ObservableObject {
    static let shared = HomeSectionsStore()

    @Published private(set) var order: [HomeSectionKind]
    @Published private(set) var hidden: Set<HomeSectionKind>

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let order = "home_sections_order"
        static let hidden = "home_sections_hidden"
    }

    init() {
        if let saved = defaults.array(forKey: Keys.order) as? [String] {
            let restored = saved.compactMap(HomeSectionKind.init(rawValue:))
            let known = Set(restored)
            // Новые разделы, добавленные ПОСЛЕ того, как пользователь уже
            // сохранил свой порядок (например, этим самым обновлением) —
            // дописываем в конец, а не теряем молча.
            let missing = HomeSectionKind.stockOrder.filter { !known.contains($0) }
            order = restored + missing
        } else {
            order = HomeSectionKind.stockOrder
        }
        if let savedHidden = defaults.array(forKey: Keys.hidden) as? [String] {
            hidden = Set(savedHidden.compactMap(HomeSectionKind.init(rawValue:)))
        } else {
            hidden = []
        }
    }

    func isVisible(_ kind: HomeSectionKind) -> Bool { !hidden.contains(kind) }

    func toggleVisibility(_ kind: HomeSectionKind) {
        if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) }
        persistHidden()
    }

    func moveSections(fromOffsets: IndexSet, toOffset: Int) {
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistOrder()
    }

    /// "Сбросить до стоковых положений" — кнопка возле заголовка блока в
    /// Персонализации.
    func resetToDefaults() {
        order = HomeSectionKind.stockOrder
        hidden = []
        persistOrder()
        persistHidden()
    }

    private func persistOrder() {
        defaults.set(order.map(\.rawValue), forKey: Keys.order)
    }
    private func persistHidden() {
        defaults.set(hidden.map(\.rawValue), forKey: Keys.hidden)
    }
}
