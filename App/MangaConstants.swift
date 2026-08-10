import Foundation
import Combine

// MARK: - Decoding

/// Универсальная сущность справочника: id + имя (в JSON бывает `name` или `label`) + список сайтов.
struct ConstantEntity: Decodable {
    let id: Int
    let name: String
    let siteIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, name, label
        case siteIds = "site_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .id) {
            id = i
        } else if let s = try? c.decode(String.self, forKey: .id), let i = Int(s) {
            id = i
        } else {
            id = 0
        }
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        self.name = name ?? label ?? ""
        siteIds = try? c.decodeIfPresent([Int].self, forKey: .siteIds)
    }

    /// Доступна ли сущность для указанного сайта.
    func isAvailable(onSite site: Int) -> Bool {
        guard let siteIds, !siteIds.isEmpty else { return true }
        return siteIds.contains(site)
    }

    func asOption() -> FilterOption { FilterOption(id: id, title: name) }
}

/// Ответ `/api/constants` с нужными нам справочниками.
struct ConstantsResponse: Decodable {
    let data: Payload

    struct Payload: Decodable {
        let genres: [ConstantEntity]?
        let tags: [ConstantEntity]?
        let types: [ConstantEntity]?
        let format: [ConstantEntity]?
        let status: [ConstantEntity]?
        let scanlateStatus: [ConstantEntity]?
        let ageRestriction: [ConstantEntity]?
        /// Серверы картинок — точная форма поля НЕ подтверждена перехватом
        /// реального запроса (в отличие от genres/tags/etc, которые видим в
        /// работе годами), поэтому декодируется максимально защитно: сервер
        /// может отдать как простой массив строк-URL, так и массив объектов
        /// с полем url/link. Если формат не совпал ни с одним вариантом —
        /// просто nil, и приложение продолжает работать на захардкоженном
        /// списке (см. MangaImageURL.imageServers).
        let imageServers: [String]?

        enum CodingKeys: String, CodingKey {
            case genres, tags, types, format, status, scanlateStatus, ageRestriction, imageServers
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            genres = try? c.decodeIfPresent([ConstantEntity].self, forKey: .genres)
            tags = try? c.decodeIfPresent([ConstantEntity].self, forKey: .tags)
            types = try? c.decodeIfPresent([ConstantEntity].self, forKey: .types)
            format = try? c.decodeIfPresent([ConstantEntity].self, forKey: .format)
            status = try? c.decodeIfPresent([ConstantEntity].self, forKey: .status)
            scanlateStatus = try? c.decodeIfPresent([ConstantEntity].self, forKey: .scanlateStatus)
            ageRestriction = try? c.decodeIfPresent([ConstantEntity].self, forKey: .ageRestriction)

            let rawStrings = try? c.decodeIfPresent([String].self, forKey: .imageServers)
            if let rawStrings, !rawStrings.isEmpty {
                imageServers = rawStrings
            } else {
                let rawObjects = try? c.decodeIfPresent([ImageServerObject].self, forKey: .imageServers)
                imageServers = rawObjects?.compactMap { $0.url }
            }
        }

        /// Запасной вариант формы поля — объект вместо голой строки.
        private struct ImageServerObject: Decodable {
            let url: String?
            enum CodingKeys: String, CodingKey { case url, link }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                url = (try? c.decodeIfPresent(String.self, forKey: .url))
                    ?? (try? c.decodeIfPresent(String.self, forKey: .link))
            }
        }
    }
}

// MARK: - Store

/// Загружает и хранит справочники фильтров с реальными серверными id.
/// До загрузки отдаёт резервные значения из `FilterCatalog`.
@MainActor
final class ConstantsStore: ObservableObject {

    static let shared = ConstantsStore()

    @Published var genres: [FilterOption] = FilterCatalog.genres
    @Published var tags: [FilterOption] = FilterCatalog.tags
    @Published var types: [FilterOption] = FilterCatalog.types
    @Published var formats: [FilterOption] = FilterCatalog.formats
    @Published var titleStatuses: [FilterOption] = FilterCatalog.titleStatuses
    @Published var translationStatuses: [FilterOption] = FilterCatalog.translationStatuses
    @Published var ageRatings: [FilterOption] = FilterCatalog.ageRatings

    private let service: MangaNetworkService
    private var loaded = false
    /// Последний успешно загруженный payload — справочники (жанры/теги/etc)
    /// приходят СРАЗУ для всех сайтов экосистемы (у каждой сущности есть
    /// site_ids), поэтому при переключении активного сайта в меню не нужен
    /// повторный сетевой запрос — достаточно перефильтровать уже полученные
    /// данные под новый сайт (см. reapply()).
    private var lastPayload: ConstantsResponse.Payload?
    private var siteCancellable: AnyCancellable?

    init(service: MangaNetworkService = .shared) {
        self.service = service
        siteCancellable = SiteSession.shared.$activeSite
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reapply()
            }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task { await load() }
    }

    private func load() async {
        do {
            let payload = try await service.fetchConstants()
            lastPayload = payload
            reapply()
            // Не подтверждено перехватом реального запроса — но безопасно:
            // если payload.imageServers пуст/nil, updateServers ничего не
            // меняет и остаётся захардкоженный список.
            if let servers = payload.imageServers {
                MangaImageURL.updateServers(fromAccount: servers)
            }
        } catch {
            loaded = false // разрешаем повторную попытку позже
        }
    }

    /// Перефильтровать уже загруженный payload под ТЕКУЩИЙ активный сайт
    /// (см. mapped(_:order:) ниже, теперь принимает site вместо хардкода 1).
    private func reapply() {
        guard let payload = lastPayload else { return }
        let site = SiteSession.shared.activeSite.rawValue
        // Жанры и теги — по алфавиту (удобно искать).
        if let g = mapped(payload.genres, order: .alphabetical, site: site) { genres = g }
        if let t = mapped(payload.tags, order: .alphabetical, site: site) { tags = t }
        // Тип — в заданном порядке по популярности.
        if let ty = mapped(payload.types, order: .priority(Self.typePriority), site: site) { types = ty }
        // Возраст — по убыванию (18+ → 6+).
        if let a = mapped(payload.ageRestriction, order: .ageDescending, site: site) { ageRatings = a }
        // Остальное — в порядке сервера.
        if let f = mapped(payload.format, order: .serverOrder, site: site) { formats = f }
        if let s = mapped(payload.status, order: .serverOrder, site: site) { titleStatuses = s }
        if let sc = mapped(payload.scanlateStatus, order: .serverOrder, site: site) { translationStatuses = sc }
    }

    /// Желаемый порядок типов (по количеству тайтлов).
    static let typePriority = ["Манга", "Манхва", "Маньхуа", "OEL-манга", "Руманга", "Комикс", "Неизвестный"]

    private enum Order {
        case alphabetical
        case serverOrder
        case ageDescending
        case priority([String])
    }

    /// Фильтрует по активному сайту (см. SiteSession.activeSite — раньше был
    /// захардкожен на 1/MangaLib, теперь честно следует переключателю сайта
    /// в меню), убирает пустые имена и упорядочивает.
    private func mapped(_ entities: [ConstantEntity]?, order: Order, site: Int) -> [FilterOption]? {
        guard let entities, !entities.isEmpty else { return nil }
        let base = entities
            .filter { $0.isAvailable(onSite: site) && !$0.name.isEmpty }
            .map { $0.asOption() }
        guard !base.isEmpty else { return nil }

        switch order {
        case .serverOrder:
            return base
        case .alphabetical:
            return base.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .ageDescending:
            return base.sorted { numericPrefix($0.title) > numericPrefix($1.title) }
        case .priority(let names):
            let rank: (String) -> Int = { title in
                names.firstIndex(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) ?? names.count
            }
            return base.sorted { rank($0.title) < rank($1.title) }
        }
    }

    /// Число в начале строки («18+» → 18, «Нет» → -1).
    private func numericPrefix(_ s: String) -> Int {
        let digits = s.prefix { $0.isNumber }
        return Int(digits) ?? -1
    }
}
