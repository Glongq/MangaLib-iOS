import Foundation

// MARK: - API Envelopes

/// Обёртка ответа API MangaLib для списков: `{ "data": [ ... ], "meta": { ... } }`.
struct APIListResponse<T: Decodable>: Decodable {
    let data: [T]
    let meta: APIMeta?
}

/// Обёртка ответа API MangaLib для одиночного объекта: `{ "data": { ... } }`.
struct APIObjectResponse<T: Decodable>: Decodable {
    let data: T
}

/// Ленивое декодирование массива — один "сломанный" элемент не роняет чтение
/// ВСЕГО массива. Обычный `[T]` в Decodable атомарен: если ХОТЬ ОДИН элемент
/// не смог декодироваться, весь массив целиком бросает ошибку. Это критично
/// для `GET /bookmarks` (см. MangaNetworkService.fetchBookmarksAccountList) —
/// на аккаунте с историей за 1.5-2 года почти гарантированно найдётся хотя бы
/// одна закладка на снятый с публикации/удалённый тайтл, у которого "media"
/// не той формы, что MangaItem ожидает — раньше это тихо валило ВЕСЬ синк
/// закладок (через try? в цикле), и serverId не проставлялся вообще ни для
/// одной закладки, отсюда и "удаление всё равно не работает".
struct LossyArray<T: Decodable>: Decodable {
    let elements: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [T] = []
        // container.decode(_:) продвигает курсор массива независимо от того,
        // успешно ли декодировался элемент, поэтому try? здесь просто
        // пропускает битый элемент, не зацикливаясь и не роняя остальные.
        //
        // currentIndex-предохранитель: баг из фидбека ("Закладки бесконечно
        // грузит") завёлся именно на элементе, ронявшем decode глубоко
        // вложенным тип-мисматчем (см. MangaChapterMetadata.volume) — сам
        // тип-мисматч уже исправлен там, но точно ли JSONDecoder ВСЕГДА
        // продвигает курсор при ошибке на такой глубине вложенности —
        // недокументированное поведение, а не гарантия. Если курсор
        // когда-нибудь не продвинется, while остался бы бесконечным
        // (зависший спиннер навсегда) — явно проверяем это и прерываемся,
        // а не полагаемся молча на недокументированное поведение JSONDecoder.
        var lastIndex = -1
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                result.append(value)
            }
            guard container.currentIndex != lastIndex else { break }
            lastIndex = container.currentIndex
        }
        elements = result
    }
}

/// Как APIListResponse<T>, но "data" — LossyArray (см. выше). Используем там,
/// где отдельные элементы реально могут быть "битыми" (закладки старых/
/// удалённых тайтлов), в отличие от обычного каталога, где такого не бывает.
struct LossyListResponse<T: Decodable>: Decodable {
    let data: [T]
    let meta: APIMeta?

    private enum CodingKeys: String, CodingKey { case data, meta }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? c.decode(LossyArray<T>.self, forKey: .data))?.elements ?? []
        meta = try? c.decodeIfPresent(APIMeta.self, forKey: .meta)
    }
}

/// Профиль текущего пользователя — `GET /auth/me` (только с валидным токеном
/// сессии, см. AuthSession). `avatar.url` — уже готовый абсолютный URL картинки,
/// в отличие от относительных путей обложек/страниц, которые собираются через
/// MangaImageURL.
struct CurrentUser: Decodable {
    let id: Int
    let username: String
    let avatar: Avatar?

    struct Avatar: Decodable {
        let url: String?
    }
}

// MARK: - Профиль пользователя

/// Профиль — ПОДТВЕРЖДЕНО перехватом `GET /user/{id}?fields[]=background&
/// roles&points&ban_info&gender&created_at&about&teams&
/// premium_background_id&login_streak&previous_usernames` (proxypin,
/// 2026-08-26, полный набор полей): `{id, username, avatar{url},
/// background{url,filename}, about, gender{id,label}, last_online_at,
/// created_at, ban_info, points_info{level,total_points,
/// current_level_points,max_level_points,point_percent_progress,top},
/// teams[], roles[], login_streak{last_login_at,login_streak,
/// max_login_streak}, previous_usernames[], premium{enabled}, …}`.
struct UserProfile: Decodable {
    let id: Int
    let username: String
    let avatarURL: URL?
    let backgroundURL: URL?
    /// "Сырые" имена файлов (не полный URL) — то, что сервер ждёт обратно в
    /// PATCH /user/{id} при сохранении (см. ProfileInfoEditView). nil у
    /// avatar/backgroundFilename при выставленной "заглушке" placeholder —
    /// значит "аватара/фона реально нет" (ПОДТВЕРЖДЕНО пользователем).
    let avatarFilename: String?
    let backgroundFilename: String?
    let about: String?
    let genderLabel: String?
    /// Числовой id пола (1=Женский, 2=Мужской — ПОДТВЕРЖДЕНО перехватом) —
    /// нужен для редактирования (genderLabel — только для отображения).
    let genderId: Int?
    let level: Int?
    let totalPoints: Int?
    /// Очки внутри ТЕКУЩЕГО уровня и порог для следующего — те же ключи
    /// points_info.{current_level_points,max_level_points}, что ПОДТВЕРЖДЕНО
    /// перехватом у TopActiveUserPoints (агрегат главной, «Топ активных
    /// недели») — там это тот же points_info у другого пользовательского
    /// ресурса. Здесь для /user/{id} отдельно НЕ перехватывались, но раз это
    /// тот же вложенный объект под тем же именем — пробуем те же ключи
    /// (decodeIfPresent, как и everywhere в этом файле): если сервер их не
    /// отдаёт на этом эндпоинте, оба останутся nil и блок прогресса просто
    /// не покажется, ничего не сломается.
    let currentLevelPoints: Int?
    let maxLevelPoints: Int?
    /// Готовый процент прогресса до следующего уровня — ПОДТВЕРЖДЕНО
    /// перехватом (`point_percent_progress`), считать самим по
    /// current/max не нужно.
    let pointPercentProgress: Double?
    /// Дата регистрации — ПОДТВЕРЖДЕНО перехватом (proxypin, 2026-08-26).
    let createdAt: Date?
    /// Последняя активность ("online") — ПОДТВЕРЖДЁН перехватом ключ
    /// "last_online_at" на этом же ресурсе — обновляется намного чаще
    /// login_streak.lastLoginAt (в реальном перехвате отличались на
    /// несколько часов), это скорее "последний раз что-то делал", а не
    /// "последний раз логинился". См. lastLoginAt ниже — для UI "Последний
    /// вход" используем именно его.
    let lastOnlineAt: Date?
    /// Последний ВХОД (не активность) — ПОДТВЕРЖДЕНО перехватом
    /// `login_streak.last_login_at` (формат "yyyy-MM-dd HH:mm:ss", БЕЗ "T" —
    /// другой формат даты, чем everywhere else в этом файле, отдельный
    /// парсер ниже). Это и есть смысловой ответ на "когда был последний вход".
    let lastLoginAt: Date?
    /// Команды, в которых состоит пользователь — ПОДТВЕРЖДЕНО перехватом
    /// (ключ "teams" в /user/{id} реально есть), но у перехваченного
    /// пользователя массив был пуст — форма НЕПУСТОГО элемента не
    /// подтверждена отдельно для ЭТОГО эндпоинта. Переиспользуем
    /// ChapterTeam (та же форма ресурса "команда" — {id,name,cover,
    /// slug_url} — подтверждена в /teams, у главы, в уведомлениях).
    let teams: [ChapterTeam]
    /// Закрытый профиль/статистика — сервер отдаёт эти флаги; если профиль
    /// закрыт, показываем заглушку вместо содержимого.
    let canViewProfile: Bool
    let canViewStatistics: Bool

    private struct ImageRef: Decodable { let url: String?; let filename: String? }
    private struct Labeled: Decodable { let id: Int?; let label: String? }
    private struct PointsInfo: Decodable {
        let total_points: Int?
        let level: Int?
        let current_level_points: Int?
        let max_level_points: Int?
        let point_percent_progress: Double?
    }
    private struct LoginStreak: Decodable { let last_login_at: String? }

    private enum CodingKeys: String, CodingKey {
        case id, username, avatar, background, about, gender, teams
        case pointsInfo = "points_info"
        case canViewProfile = "can_view_profile"
        case canViewStatistics = "can_view_statistics"
        case createdAt = "created_at"
        case lastOnlineAt = "last_online_at"
        case loginStreak = "login_streak"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        let avatarRef = (try? c.decodeIfPresent(ImageRef.self, forKey: .avatar)) ?? nil
        let backgroundRef = (try? c.decodeIfPresent(ImageRef.self, forKey: .background)) ?? nil
        avatarURL = Self.absoluteURL(avatarRef?.url)
        backgroundURL = Self.absoluteURL(backgroundRef?.url)
        avatarFilename = avatarRef?.filename
        backgroundFilename = backgroundRef?.filename
        about = (try? c.decodeIfPresent(String.self, forKey: .about)) ?? nil
        let genderRef = (try? c.decodeIfPresent(Labeled.self, forKey: .gender)) ?? nil
        genderLabel = genderRef?.label
        genderId = genderRef?.id
        let p = (try? c.decodeIfPresent(PointsInfo.self, forKey: .pointsInfo)) ?? nil
        level = p?.level
        totalPoints = p?.total_points
        currentLevelPoints = p?.current_level_points
        maxLevelPoints = p?.max_level_points
        pointPercentProgress = p?.point_percent_progress
        teams = ((try? c.decodeIfPresent([ChapterTeam].self, forKey: .teams)) ?? nil) ?? []
        canViewProfile = ((try? c.decodeIfPresent(Bool.self, forKey: .canViewProfile)) ?? nil) ?? true
        canViewStatistics = ((try? c.decodeIfPresent(Bool.self, forKey: .canViewStatistics)) ?? nil) ?? true
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil), !raw.isEmpty {
            createdAt = APIISODate.parse(raw)
        } else {
            createdAt = nil
        }
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .lastOnlineAt)) ?? nil), !raw.isEmpty {
            lastOnlineAt = APIISODate.parse(raw)
        } else {
            lastOnlineAt = nil
        }
        let streak = (try? c.decodeIfPresent(LoginStreak.self, forKey: .loginStreak)) ?? nil
        if let raw = streak?.last_login_at, !raw.isEmpty {
            lastLoginAt = Self.loginDateFormatter.date(from: raw)
        } else {
            lastLoginAt = nil
        }
    }

    /// "2026-08-25 06:49:46" — ПОДТВЕРЖДЁН формат СТРОКИ login_streak.
    /// last_login_at (пробел вместо "T", без миллисекунд/зоны — отличается
    /// от ISO8601 остального API, свой форматтер). Часовой пояс этой строки
    /// НЕ подтверждён (в отличие от остальных дат API, которые всегда
    /// ISO8601 с явным "Z"=UTC) — предполагаем UTC как наиболее вероятный
    /// вариант (общее соглашение для остального этого же API), но это
    /// именно предположение: если после реального теста дата "Последний
    /// вход" будет на несколько часов не совпадать с ожиданием — дело в
    /// этом часовом поясе.
    private static let loginDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Относительные пути (плейсхолдер `/static/…` или кастомный) дополняем
    /// хостом обложек; абсолютные — как есть.
    static func absoluteURL(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: "https://cover.cdnlibs.org" + (s.hasPrefix("/") ? s : "/" + s))
    }
}

/// Ответ загрузки картинки во временное хранилище — ПОДТВЕРЖДЕНО перехватом
/// `POST /upload/image/avatar` → `{data:{name, extension, filename, url,
/// path}}`. `filename` — то самое значение, которое потом уходит в PATCH
/// /user/{id} как поле avatar/cover, чтобы реально привязать картинку к
/// профилю (см. MangaNetworkService.uploadAvatarImage/updateProfileInfo).
struct UploadedImage: Decodable {
    let filename: String
    let url: String?
}

/// Статистика профиля — ПОДТВЕРЖДЕНО перехватом `GET /user/{id}/stats`:
/// `{manga_added{value,label:"Создано тайтлов"}, chapters_added{value,
/// label:"Загружено глав"}, comments{value,label}, genres[], tags[], …}`.
/// Один пункт статистики жанров/тегов профиля: `{label, value, percent}`.
struct UserStatEntry: Decodable, Identifiable, Hashable {
    let label: String
    let value: Int
    let percent: Double
    var id: String { label }

    private enum CodingKeys: String, CodingKey { case label, name, value, percent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // У жанров ключ label, у тегов может быть name — берём оба.
        let byLabel = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil) ?? ""
        let byName = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        label = !byLabel.isEmpty ? byLabel : byName
        value = ((try? c.decodeIfPresent(Int.self, forKey: .value)) ?? nil) ?? 0
        if let d = try? c.decodeIfPresent(Double.self, forKey: .percent) { percent = d ?? 0 }
        else { percent = 0 }
    }
}

struct UserStats: Decodable {
    let mangaCreated: Int
    let chaptersUploaded: Int
    let comments: Int
    let genres: [UserStatEntry]
    let tags: [UserStatEntry]

    private struct Stat: Decodable { let value: Int? }
    private enum CodingKeys: String, CodingKey {
        case manga_added, chapters_added, comments, genres, tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mangaCreated = (((try? c.decodeIfPresent(Stat.self, forKey: .manga_added)) ?? nil)?.value) ?? 0
        chaptersUploaded = (((try? c.decodeIfPresent(Stat.self, forKey: .chapters_added)) ?? nil)?.value) ?? 0
        comments = (((try? c.decodeIfPresent(Stat.self, forKey: .comments)) ?? nil)?.value) ?? 0
        genres = ((try? c.decodeIfPresent([UserStatEntry].self, forKey: .genres)) ?? nil) ?? []
        tags = ((try? c.decodeIfPresent([UserStatEntry].self, forKey: .tags)) ?? nil) ?? []
    }
}

/// Комментарий пользователя из списка «Мои комментарии» — ПОДТВЕРЖДЕНО
/// перехватом `GET /user/{id}/comments?page=&sort_by=id&sort_type=desc`. Тело
/// `comment` приходит как HTML (`<p>…</p>`), а не ProseMirror. `relation`/`media`
/// описывают, к чему комментарий (глава/тайтл/обсуждение).
struct UserComment: Decodable, Identifiable {
    let id: Int
    let html: String
    let createdAt: Date?
    let up: Int
    let down: Int
    let relationType: String
    let title: String?
    let coverURL: URL?
    let slugURL: String?
    let subtitle: String?

    /// Грубая очистка HTML в читаемый текст (теги/сущности).
    var plainText: String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct MangaRef: Decodable {
        let name: String?; let rusName: String?; let slugURL: String?; let cover: MangaCover?
        enum CodingKeys: String, CodingKey { case name; case rusName = "rus_name"; case slugURL = "slug_url"; case cover }
    }
    private struct Relation: Decodable {
        let volume: String?; let number: String?; let manga: MangaRef?
        let name: String?; let rusName: String?; let slugURL: String?; let cover: MangaCover?
        enum CodingKeys: String, CodingKey {
            case volume, number, manga, name, cover
            case rusName = "rus_name"; case slugURL = "slug_url"
        }
    }
    private struct Votes: Decodable { let up: Int?; let down: Int? }

    enum CodingKeys: String, CodingKey {
        case id, comment, votes, media, relation
        case createdAt = "created_at"
        case relationType = "relation_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        html = (try? c.decode(String.self, forKey: .comment)) ?? ""

        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil), !raw.isEmpty {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else { createdAt = nil }

        let v = (try? c.decodeIfPresent(Votes.self, forKey: .votes)) ?? nil
        up = v?.up ?? 0
        down = v?.down ?? 0
        relationType = ((try? c.decodeIfPresent(String.self, forKey: .relationType)) ?? nil) ?? ""

        let media = (try? c.decodeIfPresent(MangaRef.self, forKey: .media)) ?? nil
        let rel = (try? c.decodeIfPresent(Relation.self, forKey: .relation)) ?? nil
        let mangaRef = media ?? rel?.manga

        if let m = mangaRef {
            title = (m.rusName?.isEmpty == false ? m.rusName : m.name)
            coverURL = m.cover?.bestURL
            slugURL = m.slugURL
        } else if let rel, (rel.slugURL != nil || rel.name != nil) {
            title = (rel.rusName?.isEmpty == false ? rel.rusName : rel.name)
            coverURL = rel.cover?.bestURL
            slugURL = rel.slugURL
        } else {
            title = nil; coverURL = nil; slugURL = nil
        }

        if relationType == "chapter", let rel {
            let parts = [rel.volume.map { "Том \($0)" }, rel.number.map { "Гл. \($0)" }].compactMap { $0 }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            subtitle = nil
        }
    }
}

// MARK: - Дружба (вкладка «Друзья» в профиле)

/// Пользователь внутри записи дружбы — ПОДТВЕРЖДЕНО перехватом (proxypin,
/// 2026-08-25): `GET /friendship/{userId}` и `GET /friendship?user_id=&
/// status=1` отдают `user:{id,username,avatar{filename,url},last_online_at,
/// can_view_profile,...}`.
struct FriendUser: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    let avatarURL: URL?

    /// Заглушка — на случай, если запись дружбы вдруг не прислала вложенного
    /// "user" (см. FriendshipEntry.init), чтобы декодирование самой записи
    /// не падало целиком.
    init(id: Int, username: String, avatarURL: URL?) {
        self.id = id; self.username = username; self.avatarURL = avatarURL
    }

    private struct ImageRef: Decodable { let url: String? }
    private enum CodingKeys: String, CodingKey { case id, username, avatar }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        username = ((try? c.decodeIfPresent(String.self, forKey: .username)) ?? nil) ?? ""
        let avatarRef = (try? c.decodeIfPresent(ImageRef.self, forKey: .avatar)) ?? nil
        avatarURL = UserProfile.absoluteURL(avatarRef?.url)
    }

    static func == (l: FriendUser, r: FriendUser) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Статус дружбы между текущим аккаунтом и `user` записи — ПОДТВЕРЖДЕНО
/// перехватом: `status:{is_requested,is_awaiting_confirmation,is_friend}`.
struct FriendshipStatus: Decodable, Hashable {
    let isRequested: Bool
    let isAwaitingConfirmation: Bool
    let isFriend: Bool

    enum CodingKeys: String, CodingKey {
        case isRequested = "is_requested"
        case isAwaitingConfirmation = "is_awaiting_confirmation"
        case isFriend = "is_friend"
    }
}

/// Запись дружбы — ПОДТВЕРЖДЕНО перехватом на `GET /friendship/{userId}`,
/// `GET /friendship?user_id=&status=1` (список друзей) и `PUT
/// /friendship/{id}`: `{id, user, comment, created_at, status}`. `id` —
/// id самой записи (нужен для PUT), НЕ id пользователя. Список «Общие
/// друзья» (`GET /friendship/{userId}/mutual`) в перехваченной капче был
/// пуст ("data":[]) — форма непустого элемента НЕ подтверждена отдельно,
/// декодируем той же моделью (тот же ресурс "дружба", тот же путь
/// /friendship/... — по конвенции этого API остальные его пути отдают
/// ровно эту форму).
struct FriendshipEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let user: FriendUser
    let comment: String?
    let createdAt: Date?
    let status: FriendshipStatus?

    enum CodingKeys: String, CodingKey { case id, user, comment, status, createdAt = "created_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        user = (try? c.decode(FriendUser.self, forKey: .user)) ?? FriendUser(id: 0, username: "", avatarURL: nil)
        comment = (try? c.decodeIfPresent(String.self, forKey: .comment)) ?? nil
        status = (try? c.decodeIfPresent(FriendshipStatus.self, forKey: .status)) ?? nil
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil), !raw.isEmpty {
            createdAt = APIISODate.parse(raw)
        } else {
            createdAt = nil
        }
    }

    static func == (l: FriendshipEntry, r: FriendshipEntry) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Папки закладок другого пользователя («Списки тайтлов» в профиле)

/// Папка закладок — ПОДТВЕРЖДЕНО перехватом `GET /bookmarks/folder/{userId}`:
/// `{id,name,public,notify,color,textColor,order,count,site_ids}`. Та же
/// форма и у ответа `POST /bookmarks/folder` (создание своей папки) —
/// используется и как decode-target для MangaNetworkService.
/// createBookmarkFolder. У ответа `PUT /bookmarks/folder/{id}` (переименование)
/// поле `count` уже ОТСУТСТВУЕТ — для него этот тип НЕ подходит, см.
/// updateBookmarkFolder (тело ответа там просто не разбирается).
struct UserBookmarkFolder: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let count: Int
    let colorHex: String?
    /// Тумблер "уведомлять о новых главах в этой папке" — используется
    /// экраном настроек уведомлений (см. NotificationSettingsView), сам
    /// список закладок пользователя (UserBookmarksView) это поле не читает.
    var notify: Bool
    /// Приватность папки — ПОДТВЕРЖДЕНО перехватом: у 5 стандартных папок
    /// всегда `true`, у ЛЮБОЙ новой кастомной (`POST /bookmarks/folder`) —
    /// `false` по умолчанию. Нужно для BookmarksStore.updateFolder — `PUT
    /// /bookmarks/folder/{id}` шлёт этот флаг ВМЕСТЕ с именем/цветом (весь
    /// объект целиком), терять его при простом переименовании нельзя.
    var isPublic: Bool
    /// На каких сайтах сети видна эта папка — ПОДТВЕРЖДЕНО перехватом
    /// (`GET /bookmarks/folder/{userId}` отдаёт ПОЛНЫЙ список аккаунта СРАЗУ
    /// по всем сайтам, без учёта Site-Id запроса; фильтрация "какие папки
    /// показывать" — целиком на фронтенде, по этому полю). 5 стандартных
    /// папок — `[0,1,2,3,4]`; кастомные — сайт, на котором их создали. Нужно
    /// BookmarksStore.syncFoldersFromServer(), чтобы вкладка «Закладки»
    /// тоже фильтровала по активному сайту, как настоящий сайт.
    var siteIds: [Int]
    /// Позиция папки в общем порядке — ПОДТВЕРЖДЕНО перехватом (тот же
    /// объект, что и в `PUT /bookmarks/folder/order`, см. BookmarksStore.
    /// syncFoldersFromServer/moveFolders). Прямая жалоба: "не
    /// синхронизируется порядок (номер) списка" — раньше это поле вообще не
    /// читалось, локальный видимый порядок был просто "как в массиве"
    /// (хардкод для 5 стандартных + порядок обнаружения для кастомных), не
    /// РЕАЛЬНЫЙ порядок с сервера.
    var order: Int

    enum CodingKeys: String, CodingKey {
        case id, name, count, colorHex = "color", notify, isPublic = "public", siteIds = "site_ids", order
    }
}

// MARK: - Настройки уведомлений аккаунта

/// `GET/PUT /user/settings/notifications` — ПОДТВЕРЖДЕНО реальным
/// перехватом (несколько десятков пар запрос/ответ, все 17 полей
/// присутствуют всегда). PUT шлёт ВЕСЬ объект целиком, не частичный патч —
/// значит поля, не показанные в UI настроек (notify_anime,
/// disable_card_drop_notif, push_*, reading/plan_read/on_hold/completed/
/// favourites), нужно сохранять НЕИЗМЕНЁННЫМИ, взятыми из последнего GET
/// (см. NotificationSettingsView).
struct NotificationSettings: Codable, Equatable {
    let userId: Int
    var manga: Bool
    var disableFriendsNotif: Bool
    var mediaStatusFinished: Bool
    var disableOldCommentsNotif: OldCommentsThreshold
    var disableChapterEarlyAccessNotif: Bool
    var disableCardDropNotif: Bool
    var reading: Bool
    var planRead: Bool
    var onHold: Bool
    var completed: Bool
    var favourites: Bool
    var pushChapter: Bool
    var pushComments: Bool
    var pushEpisode: Bool
    var pushForum: Bool
    var pushMessages: Bool
    var notifyAnime: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case manga
        case disableFriendsNotif = "disable_friends_notif"
        case mediaStatusFinished = "media_status_finished"
        case disableOldCommentsNotif = "disable_old_comments_notif"
        case disableChapterEarlyAccessNotif = "disable_chapter_early_access_notif"
        case disableCardDropNotif = "disable_card_drop_notif"
        case reading
        case planRead = "plan_read"
        case onHold = "on_hold"
        case completed
        case favourites
        case pushChapter = "push_chapter"
        case pushComments = "push_comments"
        case pushEpisode = "push_episode"
        case pushForum = "push_forum"
        case pushMessages = "push_messages"
        case notifyAnime = "notify_anime"
    }
}

/// `disable_old_comments_notif` — ЕДИНСТВЕННОЕ поле объекта со смешанным
/// типом на проводе: на ЧТЕНИЕ (`GET`, значение только что созданного
/// аккаунта/никогда не тронутая настройка) перехвачено как `false`; на
/// ЗАПИСЬ (`PUT`, реальный клиент) — ТОЛЬКО `0` (Int, явно выключено) ИЛИ
/// строка-число дней — `"7"`/`"14"`/`"30"`/`"180"`/`"360"` (выбран порог в
/// Picker'е); `PUT` с буквальным `false` НИ РАЗУ не перехвачен, поэтому
/// при сохранении шлём именно `0` для "выключено" — так делает реальный
/// клиент.
enum OldCommentsThreshold: Equatable, Codable {
    case off
    case days(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = intValue > 0 ? .days(intValue) : .off
            return
        }
        if let stringValue = try? container.decode(String.self), let intValue = Int(stringValue) {
            self = intValue > 0 ? .days(intValue) : .off
            return
        }
        // Bool(false, дефолт непотроганного аккаунта) или что-то
        // непредвиденное — трактуем как "выключено".
        self = .off
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .off: try container.encode(0)
        case .days(let days): try container.encode(String(days))
        }
    }
}

// MARK: - История чтения (реальный аккаунт)

/// Одна запись реальной истории просмотров аккаунта —
/// `GET /user/chapters/history?page=N`. Подтверждено перехватом реального
/// запроса сайта (см. чат) — `media` по форме совпадает с MangaItem, `item` —
/// отдельная, более простая форма главы (плоский branch_id, а не вложенный
/// массив branches, как в ChapterItem).
struct HistoryEntry: Decodable, Identifiable, Hashable {
    let viewAt: Date
    let media: MangaItem
    let item: HistoryChapterRef

    /// Составной id — своего id у записи истории нет, только у media/item.
    var id: String { "\(media.id)-\(item.id)" }

    enum CodingKeys: String, CodingKey {
        case viewAt = "view_at"
        case media, item
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decode(MangaItem.self, forKey: .media)
        item = try c.decode(HistoryChapterRef.self, forKey: .item)
        // "2026-07-26T21:15:10.000000Z" — ISO8601 с микросекундами.
        // ISO8601DateFormatter с .withFractionalSeconds не всегда переваривает
        // 6 знаков дробной части одинаково на всех версиях iOS — на случай
        // расхождения есть резервный DateFormatter с явным форматом.
        let raw = try c.decode(String.self, forKey: .viewAt)
        viewAt = Self.parseDate(raw) ?? Date()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return f
    }()

    private static func parseDate(_ raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
    }
}

/// Глава внутри записи истории — своя, более простая форма (в отличие от
/// ChapterItem: тут branch_id — плоское поле, а не вложенный массив branches).
struct HistoryChapterRef: Decodable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let branchId: Int?
    let mangaId: Int?

    enum CodingKeys: String, CodingKey {
        case id, volume, number
        case branchId = "branch_id"
        case mangaId = "manga_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        volume = try Self.flexibleString(c, .volume) ?? "1"
        number = try Self.flexibleString(c, .number) ?? "0"
        branchId = try? c.decodeIfPresent(Int.self, forKey: .branchId)
        mangaId = try? c.decodeIfPresent(Int.self, forKey: .mangaId)
    }

    // Та же защита, что и в ChapterItem — volume/number иногда приходят числом.
    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        return nil
    }
}

/// Метаинформация пагинации.
struct APIMeta: Decodable {
    let page: Int?
    let hasNextPage: Bool?

    enum CodingKeys: String, CodingKey {
        case page
        case hasNextPage = "has_next_page"
    }
}

/// Страница каталога: элементы + признак наличия следующей страницы.
struct CatalogPage {
    let items: [MangaItem]
    let hasNextPage: Bool
}

// MARK: - Cover

/// Набор ссылок на обложку. Сервер возвращает разные размеры.
struct MangaCover: Decodable {
    let filename: String?
    let thumbnail: String?
    let `default`: String?
    let md: String?
    /// Полноразмерный оригинал — есть ТОЛЬКО в ответе /covers (доп. обложки,
    /// см. MangaCoverGalleryItem ниже), у обычной MangaItem.cover его нет,
    /// поэтому optional и не участвует в bestURL (не ломает остальные места).
    let orig: String?

    /// Наиболее подходящий URL обложки для отображения в карточке.
    var bestURL: URL? {
        for candidate in [md, `default`, thumbnail, filename] {
            if let string = candidate, let url = URL(string: string) {
                return url
            }
        }
        return nil
    }

    /// Маленькая, заранее сжатая версия (суффикс `_thumb` в реальных URL) —
    /// для мелких превью в лентах (см. HomeView), где полноразмерная
    /// default/md обложка (обычно = то же самое, что и md, см. комментарий
    /// у bestURL) не нужна и только тратит трафик/время загрузки.
    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }

    /// Максимальное качество — для полноэкранной листалки (см.
    /// MangaDetailView.coverGalleryViewer): orig, а если его нет — то же,
    /// что и bestURL.
    var fullResURL: URL? {
        if let orig, let url = URL(string: orig) { return url }
        return bestURL
    }
}

// MARK: - Доп. обложки тайтла (GET /manga/{slug}/covers)

/// Галерея пользовательских обложек — ПОДТВЕРЖДЕНО реальным перехваченным
/// запросом (пользователь прислал полное тело ответа): `GET
/// /manga/{slug}/covers` → `{"data":[{"id","cover":{...MangaCover-форма,
/// включая "orig"...},"info","order","user":{...}}]}`. `user` (кто добавил
/// обложку) в ответе есть, но пока нигде не отображается — если понадобится
/// атрибуция ("добавил: ник"), можно добавить, декодер её просто
/// проигнорирует, раз поле не описано здесь. `info` — судя по примеру,
/// просто порядковый номер строкой (не подтверждённая содержательная
/// подпись), не показываем как текст.
struct MangaCoverGalleryItem: Decodable, Identifiable {
    let id: Int
    let cover: MangaCover
    let info: String?
    let order: Int
}

/// Фоновая картинка тайтла (MangaDetail.background) — ПОДТВЕРЖДЕНО реальным
/// перехваченным JSON: форма ДРУГАЯ, чем у обложки — `{"filename":"...",
/// "url":"https://cover.cdnlibs.org/uploads/cover/{slug}/background/{filename}"}`,
/// без thumbnail/default/md, зато с готовым абсолютным "url". Раньше здесь
/// по ошибке использовалась MangaCover (форма обложки) — ключи не совпадали,
/// поэтому background всегда декодировался в nil и картинка не подгружалась,
/// даже когда реально была на сервере.
struct MangaBackgroundImage: Decodable {
    let filename: String?
    let url: String?

    var bestURL: URL? { url.flatMap(URL.init(string:)) }
}

// MARK: - Status & Rating

struct MangaStatus: Decodable {
    let id: Int?
    let label: String?
}

struct MangaRating: Decodable {
    let average: String?
    let averageFormated: String?
    let votes: Int?
    /// Оценка ТЕКУЩЕГО пользователя (1-10) — ПОДТВЕРЖДЕНО перехватом ответа
    /// `POST /manga/rate` (`{"data":{"average","averageFormated","votes",
    /// "user":8}}`), используется чтобы предзаполнить выбор в RatingSheet.
    let user: Int?

    /// Числовое значение рейтинга (например, 8.5).
    var value: Double? {
        if let average, let d = Double(average) { return d }
        if let averageFormated, let d = Double(averageFormated) { return d }
        return nil
    }

    /// `user`, нормализованный под "реально оценил или нет". На карточке
    /// тайтла (GET /manga/{slug}) сервер, судя по всему, присылает
    /// `"user":0` дефолтом для ЕЩЁ НЕ оценённых тайтлов (не null и не
    /// отсутствие поля) — сама шкала оценок 1-10 (см. RatingSheet), 0 в
    /// принципе невозможно поставить руками. Без этой нормализации `if let
    /// myScore = rating?.user` считал 0 "ты поставил 0" и рисовал звезду/
    /// сохранял 0 в закладки, хотя пользователь ничего не оценивал —
    /// используем ВЕЗДЕ вместо сырого `user`, где показываем/кэшируем
    /// личную оценку.
    var myScore: Int? {
        guard let user, user > 0 else { return nil }
        return user
    }
}

// MARK: - Stats (оценки пользователей + распределение по спискам)

/// Статистика тайтла — ПОДТВЕРЖДЕНО перехватом `GET /manga/{slug}/stats`:
/// `{data:{bookmarks:{count, stats:[{label,value,percent,meta}]},
/// rating:{count, stats:[{label,value,percent,meta}]}}}`. У рейтинга `label` —
/// число (10…1), у закладок — строка ("Читаю"/"Прочитано"/…).
struct MangaStats: Decodable {
    let bookmarks: StatGroup?
    let rating: StatGroup?
}

struct StatGroup: Decodable {
    let count: Int?
    let stats: [StatEntry]?
}

struct StatEntry: Decodable, Identifiable {
    let label: String
    let value: Int
    let percent: Double
    var id: String { label }

    private enum CodingKeys: String, CodingKey { case label, value, percent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // label бывает строкой ("Читаю") или числом (10) — берём оба.
        if let s = try? c.decode(String.self, forKey: .label) { label = s }
        else if let i = try? c.decode(Int.self, forKey: .label) { label = String(i) }
        else { label = "" }

        if let i = try? c.decode(Int.self, forKey: .value) { value = i }
        else if let d = try? c.decode(Double.self, forKey: .value) { value = Int(d) }
        else { value = 0 }

        if let d = try? c.decode(Double.self, forKey: .percent) { percent = d }
        else if let i = try? c.decode(Int.self, forKey: .percent) { percent = Double(i) }
        else { percent = 0 }
    }
}

// MARK: - Named entity (жанр, тег, автор)

/// Универсальная сущность со `id` и `name` (жанры, теги, авторы).
struct NamedEntity: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
}

/// Элемент "Формат" (MangaDetail.format) — подтверждено реальным перехваченным
/// JSON: `[{"id":6,"name":"Веб"}]`, т.е. ключ "name", как у жанров/тегов.
/// Оставляем и запасной ключ "label" на случай другого сайта/варианта ответа.
struct FlexibleLabelEntity: Decodable {
    let label: String?

    private enum CodingKeys: String, CodingKey { case name, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let byName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        let byLabel = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        label = [byName, byLabel].compactMap { $0 }.first { !$0.isEmpty }
    }
}

// MARK: - MangaItem (элемент каталога/поиска)

struct MangaItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let rusName: String?
    let engName: String?
    let slug: String
    let slugURL: String?
    let cover: MangaCover?
    let rating: MangaRating?
    let status: MangaStatus?
    let type: MangaStatus?
    let ageRestriction: MangaStatus?
    /// Сайт тайтла (site_id: 1=манга, 3=новеллы, 4=хентай, …) — приходит в
    /// каталоге/поиске/похожем/связанном. Нужен, чтобы карточку с ДРУГОГО сайта
    /// (напр. из «Похожего») запрашивать с правильным Site-Id, иначе 404.
    let site: Int?
    /// Время последней главы (ISO8601, строкой — см. APIISODate.parse) и
    /// её краткое описание — приходят у элементов главной страницы
    /// (popular/newest/latest_updates, см. HomeFeed) при явном запросе
    /// `fields[]=metadata` (MangaNetworkService.fetchLatestUpdates). В обычном
    /// каталоге/поиске сервер их не присылает — оба поля Optional, остальной
    /// код с MangaItem их не требует.
    let lastItemAt: String?
    let metadata: MangaItemMetadata?

    /// Название для отображения: русское, если есть, иначе оригинальное.
    var displayTitle: String { rusName?.isEmpty == false ? rusName! : name }

    /// Идентификатор для запросов к API (slug_url приоритетнее, т.к. содержит числовой префикс).
    var apiSlug: String { slugURL?.isEmpty == false ? slugURL! : slug }

    /// URL обложки строкой (для сохранения в закладки).
    var coverURLString: String? { cover?.bestURL?.absoluteString }

    /// Последняя глава для строки "Том X Глава Y" (см. HomeView) — сначала
    /// ищет в metadata.latestItems (форма секции "latest_updates"), потом в
    /// metadata.lastItem (форма секции "popular"/"newest").
    var latestChapter: MangaChapterMetadata? { metadata?.latestItems?.items.first ?? metadata?.lastItem }
    /// Сколько ЕЩЁ глав вышло, кроме показанной latestChapter (для "+ ещё N").
    var extraLatestChaptersCount: Int { max(0, (metadata?.latestItems?.count ?? 1) - 1) }
    var lastItemDate: Date? { lastItemAt.flatMap(APIISODate.parse) ?? latestChapter?.createdAt.flatMap(APIISODate.parse) }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, cover, rating, status, type, site, metadata
        case rusName = "rus_name"
        case engName = "eng_name"
        case slugURL = "slug_url"
        case ageRestriction = "ageRestriction"
        case lastItemAt = "last_item_at"
    }

    static func == (lhs: MangaItem, rhs: MangaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// `metadata` у элемента списка тайтлов — ДВЕ РАЗНЫЕ подтверждённые формы
/// в перехваченном дампе агрегата главной страницы (пользователь прислал
/// два файла): у "popular"/"newest" это одиночный `last_item`, у
/// "latest_updates" — `latest_items: {count, items:[...]}`. Оба optional и
/// оба декодируются здесь — MangaItem.latestChapter сам выбирает, какой есть.
struct MangaItemMetadata: Decodable, Hashable {
    let lastItem: MangaChapterMetadata?
    let latestItems: MangaLatestItems?

    enum CodingKeys: String, CodingKey {
        case lastItem = "last_item"
        case latestItems = "latest_items"
    }
}

struct MangaLatestItems: Decodable, Hashable {
    let count: Int
    let items: [MangaChapterMetadata]
}

/// Краткое описание главы внутри metadata (НЕ то же самое, что ChapterItem/
/// HistoryChapterRef/NotificationChapter — своя, третья форма того же
/// понятия "глава", подтверждено тем же дампом).
struct MangaChapterMetadata: Decodable, Hashable {
    let volume: String?
    let number: String?
    let name: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case volume, number, name
        case createdAt = "created_at"
    }

    /// ПОДТВЕРЖДЕНО реальным перехватом (закладки аккаунта, `last_item.volume`):
    /// сервер иногда отдаёт "volume" ЧИСЛОМ (`"volume":1`), а не строкой, как
    /// в остальных местах (`"volume":"1"`). Обычный `String?` в этом случае
    /// бросает DecodingError.typeMismatch — а поскольку MangaChapterMetadata
    /// декодируется ВНУТРИ LossyArray (см. BookmarkListEntry/MangaItem), эта
    /// одна нетипичная закладка тихо выкидывала из результата ВЕСЬ элемент
    /// массива; на аккаунте, где так размечено большинство/все закладки,
    /// itemы «Все обновления»/«Закладки» приходили пустым списком целиком.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try Self.flexibleString(c, .volume)
        number = try Self.flexibleString(c, .number)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        if let value = try? c.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

// MARK: - "Похожее" (GET /manga/{slug}/similar)

/// Один элемент раздела "Похожее" — ПОДТВЕРЖДЕНО реальным перехваченным
/// запросом (пользователь прислал полное тело): `GET /manga/{slug}/similar`
/// → `{"data":[{"id":Int,"similar":"Схож по жанрам и сюжету","user_id":Int,
/// "media":{...та же форма, что MangaItem: id/name/rus_name/eng_name/slug/
/// slug_url/cover/status/type/ageRestriction...},"votes":{"up":Int,"down":Int,
/// "user":Int?}}]}`. "media" по форме СОВПАДАЕТ с MangaItem (как и у
/// BookmarkListEntry/HistoryEntry) — переиспользуем его напрямую.
struct SimilarItem: Decodable, Identifiable, Hashable {
    let id: Int
    /// Текст-объяснение, ПОЧЕМУ похоже — "Схож по жанрам и сюжету", "Схож по
    /// рисовке" и т.п., свободный текст с сервера.
    let similar: String?
    let media: MangaItem
    var votes: SimilarVotes

    static func == (lhs: SimilarItem, rhs: SimilarItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Голоса за "похожесть" — ПОДТВЕРЖДЕНО перехватом `POST /similar/{id}/vote`:
/// `user` — именно `Int?`, НЕ Bool. Реальные ответы из перехвата: после
/// голоса "+" (тело запроса `{"vote":1}`) → `{"up":1095,"down":28,"user":1}`;
/// после голоса "-" (тело `{"vote":0}`) → `{"up":1094,"down":29,"user":0}`.
/// Т.е. user:1 = голосовал "+", user:0 = голосовал "-", user:null = не
/// голосовал вовсе. Поведение "снять голос полностью" (вернуть user:null)
/// НЕ подтверждено ни одним перехватом — переключение между "+"/"-"
/// поддержано, отдельная кнопка "отменить голос" не добавлена, чтобы не
/// гадать про неподтверждённое поведение.
struct SimilarVotes: Decodable, Hashable {
    let up: Int
    let down: Int
    let user: Int?
}

// MARK: - "Связанное" (GET /manga/{slug}/relations)

/// Один элемент раздела "Связанное" — ПОДТВЕРЖДЕНО реальным перехваченным
/// запросом (пользователь прислал полное тело): `GET /manga/{slug}/relations`
/// → `{"data":[{"order":Int,"related_type":{"id":Int,"label":"Источник"},
/// "media":{...та же форма, что MangaItem}}]}`. В отличие от "Похожего" (см.
/// SimilarItem) — БЕЗ голосов и без своего "id" у самого элемента связи
/// (только order + related_type + media), поэтому Identifiable — по
/// media.id (гарантированно уникален, в отличие от order, который может
/// повторяться).
struct RelatedItem: Decodable, Identifiable, Hashable {
    var id: Int { media.id }
    let order: Int
    /// "Источник", "Сиквел", "Спин-офф" и т.п. — тип связи с сервера.
    let relatedType: MangaStatus?
    let media: MangaItem

    enum CodingKeys: String, CodingKey {
        case order, media
        case relatedType = "related_type"
    }

    static func == (lhs: RelatedItem, rhs: RelatedItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Реальные "мои закладки" аккаунта (GET /bookmarks)

/// Один элемент настоящего эндпоинта "мои закладки" — `GET /bookmarks?page=&
/// sort_by=name&sort_type=desc&status=N&user_id=<id>` (подтверждено реальным
/// перехваченным запросом, см. чат/файл "Релализация ЗАКЛАДОК норм.txt").
/// В отличие от старого предположения ("отдельного эндпоинта нет, это /manga
/// с фильтром bookmarks[]="), это НАСТОЯЩИЙ эндпоинт закладок, и его "id"
/// верхнего уровня — это id САМОЙ ЗАПИСИ закладки, ровно тот, что нужен для
/// `DELETE /bookmarks/{id}` (см. MangaNetworkService.removeBookmark(id:)).
/// "media" по форме совпадает с MangaItem (id/name/rus_name/slug/slug_url/
/// cover/status/type/ageRestriction — все ключи есть и называются так же),
/// поэтому переиспользуем MangaItem напрямую вместо отдельной модели.
struct BookmarkListEntry: Decodable {
    let id: Int
    /// Числовой статус папки — совпадает с BookmarkFolder.apiId
    /// (1=Читаю, 2=В планах, 3=Брошено, 4=Прочитано, 5=Любимые).
    let status: Int?
    let media: MangaItem
    /// ТВОЯ личная оценка тайтла — ПОДТВЕРЖДЕНО перехватом `GET /bookmarks`:
    /// поле лежит прямо в объекте закладки (рядом с id/status/media), НЕ
    /// внутри media, `null` у неоценённых тайтлов (не 0-заглушка, как у
    /// `GET /manga/{slug}`, см. MangaRating.myScore) — сервер уже отдаёт
    /// актуальную оценку для ВСЕХ закладок одним запросом при синхронизации,
    /// используем вместо того, чтобы ждать, пока пользователь сам откроет
    /// карточку тайтла (см. BookmarksStore.syncFromServer).
    let rating: Int?

    /// На всякий случай та же нормализация 0→nil, что и у MangaRating.myScore
    /// (сама шкала оценок 1-10) — здесь API уже подтверждённо шлёт null для
    /// неоценённых, но 0 тоже не может быть настоящей оценкой.
    var myScore: Int? {
        guard let rating, rating > 0 else { return nil }
        return rating
    }

    /// "Прочитано/перечитано N раз" + личный комментарий к закладке —
    /// ПОДТВЕРЖДЕНО перехватом `POST /bookmarks` (то же тело, что и смена
    /// папки — meta шлётся ВМЕСТЕ со status, целиком). Optional — старые
    /// перехваченные ответы этот ключ вообще не содержали, если история
    /// пуста (см. BookmarkMeta).
    let meta: BookmarkMeta?
}

/// meta-объект закладки — ПОДТВЕРЖДЕНО перехватом двумя формами:
/// `{"comment":false,"rewatches":null,"item_number":null}` (пусто) и
/// `{"item_number":119,"rewatches":3,"rewatches_history":[{"start":
/// "2026-08-01","end":"2026-08-07"},...,{"start":"2026-08-28","end":null}],
/// "comment":"текст","notes":0}` (заполнено). `rewatches` — просто
/// count(rewatches_history), сервер сам не хранит отдельно — мы его вообще
/// не читаем, копируем только сам массив. `comment` — смешанный тип:
/// `false` у пустых, строка у заполненных.
struct BookmarkMeta: Decodable {
    let comment: String?
    let rewatchHistory: [RewatchPeriod]

    private enum CodingKeys: String, CodingKey { case comment, rewatchHistory = "rewatches_history" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .comment), !text.isEmpty {
            comment = text
        } else {
            comment = nil
        }
        rewatchHistory = (try? container.decode([RewatchPeriod].self, forKey: .rewatchHistory)) ?? []
    }
}

/// Один период перечитывания — ПОДТВЕРЖДЕНО перехватом:
/// `{"start":"yyyy-MM-dd","end":"yyyy-MM-dd"|null}`. `end == nil` — период
/// ещё не закрыт ("сейчас перечитывает"). Реального id у периода на
/// сервере нет — это просто элемент массива, не отдельная сущность.
struct RewatchPeriod: Codable, Identifiable, Hashable {
    var start: String
    var end: String?

    var id: String { start + "_" + (end ?? "open") }
}

// MARK: - Summary rich-text (ProseMirror/TipTap)

/// Описание тайтла (MangaDetail.summary) приходит НЕ обычной строкой, а
/// деревом rich-текста в формате ProseMirror/TipTap — подтверждено реальным
/// перехваченным JSON: `{"type":"doc","content":[{"type":"paragraph",
/// "content":[{"type":"text","text":"..."}]}]}`. SummaryDoc/SummaryNode
/// рекурсивно собирают из этого дерева чистый текст для отображения в UI.
struct SummaryDoc: Decodable {
    let content: [SummaryNode]?

    var plainText: String {
        (content ?? [])
            .map(\.plainText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

struct SummaryNode: Decodable {
    let text: String?
    let content: [SummaryNode]?

    var plainText: String {
        if let text, !text.isEmpty { return text }
        return (content ?? []).map(\.plainText).joined()
    }
}

/// Полностью универсальное JSON-значение — на случай, если реальная форма
/// "summary" всё-таки хоть немного отличается от SummaryDoc/SummaryNode
/// (другие имена узлов, лишняя обёртка и т.п.). Раз три попытки угадать
/// точную структуру не помогли — этот разбор вообще не завязан на структуру:
/// он декодирует ЛЮБОЙ JSON и сам ищет по нему читаемый текст.
enum AnyJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        self = .null
    }

    /// Сначала ищет строки под ключом "text" (конвенция ProseMirror/TipTap,
    /// сохраняет порядок, т.к. массивы всегда упорядочены). Если таких нет
    /// вообще — берёт любые строковые "листья" дерева длиннее нескольких
    /// символов (пропуская короткие однословные технические значения вроде
    /// "doc"/"paragraph"), чтобы не потерять текст даже при незнакомой форме.
    func extractReadableText() -> String {
        var textNodes: [String] = []
        collect(key: nil, into: &textNodes, targetKey: "text")
        if !textNodes.isEmpty {
            return textNodes.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        var anyStrings: [String] = []
        collectAnyStrings(into: &anyStrings)
        return anyStrings.joined(separator: "\n\n")
    }

    private func collect(key: String?, into result: inout [String], targetKey: String) {
        switch self {
        case .string(let s):
            if key == targetKey, !s.isEmpty { result.append(s) }
        case .object(let dict):
            for (k, v) in dict { v.collect(key: k, into: &result, targetKey: targetKey) }
        case .array(let arr):
            for v in arr { v.collect(key: key, into: &result, targetKey: targetKey) }
        default:
            break
        }
    }

    private func collectAnyStrings(into result: inout [String]) {
        switch self {
        case .string(let s):
            // Пропускаем короткие однословные значения без пробелов — это,
            // скорее всего, служебные теги вроде "type": "paragraph", а не
            // читаемый текст описания.
            if s.count > 3, s.contains(" ") || s.count > 20 {
                result.append(s)
            }
        case .object(let dict):
            for (_, v) in dict { v.collectAnyStrings(into: &result) }
        case .array(let arr):
            for v in arr { v.collectAnyStrings(into: &result) }
        default:
            break
        }
    }
}

// MARK: - MangaDetail (детальная карточка)

struct MangaDetail: Decodable, Identifiable {
    let id: Int
    let name: String
    let rusName: String?
    let engName: String?
    let slug: String
    let slugURL: String?
    let cover: MangaCover?
    /// Отдельная фоновая картинка тайтла (шире/выше обложки, для шапки
    /// экрана) — ПОДТВЕРЖДЕНО реальным перехваченным JSON (запрос с
    /// `fields[]=background`): `{"background":{"filename":"...","url":"https://
    /// cover.cdnlibs.org/uploads/cover/{slug}/background/{filename}"}}` — форма
    /// ДРУГАЯ, чем у обложки (см. MangaBackgroundImage), поэтому раньше (когда
    /// декодировалось как MangaCover) поле всегда получалось nil. Также
    /// подтверждено, что "background" нужно явно запрашивать через
    /// fields[]=background (см. fetchMangaDetail) — без этого сервер его не
    /// присылает вообще, как summary/genres/tags и т.п.
    let background: MangaBackgroundImage?
    /// `var`, а не `let` — единственное поле, которое мутируется ПОСЛЕ
    /// декодирования: `MangaDetailViewModel.submitRating` подставляет сюда
    /// свежий агрегат прямо из ответа `POST /manga/rate`, не дожидаясь
    /// отдельного `GET /manga/{slug}` (см. там же — раньше "моя оценка"
    /// появлялась с заметной задержкой именно из-за этого ожидания).
    var rating: MangaRating?
    let status: MangaStatus?
    let type: MangaStatus?
    /// Возрастной рейтинг («18+»/«16+»/«12+»/«6+»/«Нет») — та же форма
    /// (id+label), что и у MangaItem.ageRestriction (см. там), декодируется
    /// точно так же, без fields[] (это, судя по каталогу, поле по умолчанию,
    /// а не одно из "опциональных" типа summary/genres/tags/format/views/
    /// background, которые сервер отдаёт ТОЛЬКО по явному запросу). См.
    /// MangaDetailView.ageRatingChip — 18+/16+ показываются цветным чипом
    /// первыми в списке жанров/тегов, 12+/6+/"Нет" не показываются вовсе.
    let ageRestriction: MangaStatus?
    /// Сайт тайтла (site_id) — приходит в ответе карточки, используем как
    /// «истинный» сайт для последующих запросов (главы/страницы читалки).
    let site: Int?
    let summary: String?
    let genres: [NamedEntity]?
    let tags: [NamedEntity]?
    /// Авторы/художники/издательство — ПОДТВЕРЖДЕНО перехватом: те же
    /// объекты, что и в списках /people и /publisher (см. DirectoryEntity),
    /// просто embedded прямо в ответ тайтла. artists/publisher требуют
    /// явного fields[]=artists/fields[]=publisher (см. fetchMangaDetailRawData).
    let authors: [DirectoryEntity]?
    let artists: [DirectoryEntity]?
    let publisher: [DirectoryEntity]?
    /// Альтернативные названия ("I Alone Level-Up", "Соло Левелинг", ...) —
    /// показываются в sheet по тапу на название (см. TitleNamesSheet).
    /// ЗАГЛУШКА/на будущее: точный ключ реальным перехватом НЕ подтверждён,
    /// поэтому "otherNames" СОЗНАТЕЛЬНО НЕ добавлен в fields[] запроса
    /// (fetchMangaDetail) — одно неизвестное серверу значение fields[] валит
    /// весь /manga/{slug} с 422. Разбираем, только если сервер сам пришлёт его
    /// по умолчанию; иначе nil — sheet покажет "Нет данных".
    let otherNames: [String]?
    let releaseDate: String?
    let views: Int?
    let format: [FlexibleLabelEntity]?
    /// Тайтл официально лицензирован (главы в связи с этим скрыты/удалены с
    /// сайта) — ПОДТВЕРЖДЕНО реальным перехваченным JSON (см. файл "проверка
    /// на лицензирование.txt"): `"is_licensed": true` у тайтла с
    /// `"items_count":{"uploaded":15,"total":0}` (главы загружены, но не
    /// видны). Поле по умолчанию, БЕЗ fields[] (как и ageRestriction/status/
    /// type/cover) — в перехваченном запросе его нет в списке fields[], но
    /// оно всё равно пришло в ответе.
    let isLicensed: Bool
    /// Статус модерации — ПОДТВЕРЖДЕНО тем же перехватом: `"moderated":
    /// {"id":1,"label":"Принято модерацией"}`, требует ЯВНОГО fields[]=moderated
    /// (есть в списке query у перехваченного запроса, см. fetchMangaDetail).
    /// См. MangaDetailView.isBlockedByLicenseOrModeration — вместе с
    /// isLicensed определяет, показывать ли вместо описания текст про
    /// удаление глав правообладателем/РКН.
    let moderated: MangaStatus?
    /// Франшиза тайтла (чип-подкатегория на карточке, см.
    /// MangaDetailView.franchiseChip) — ПОДТВЕРЖДЕНО перехватом, требует
    /// явного fields[]=franchise (см. FranchiseRef/fetchMangaDetailRawData).
    let franchise: FranchiseRef?

    var displayTitle: String { rusName?.isEmpty == false ? rusName! : name }
    var apiSlug: String { slugURL?.isEmpty == false ? slugURL! : slug }

    /// Год выпуска в формате «2009г.».
    var yearString: String? {
        guard let releaseDate, !releaseDate.isEmpty else { return nil }
        let year = String(releaseDate.prefix(4))
        return year.count == 4 ? "\(year)г." : nil
    }

    /// Просмотры в формате «7.1тыс.» / «1.2млн».
    var viewsString: String? {
        guard let v = views, v > 0 else { return nil }
        switch v {
        case 1_000_000...:
            return String(format: "%.1fмлн", Double(v) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fтыс.", Double(v) / 1_000)
        default:
            return "\(v)"
        }
    }

    var formatLabels: [String] { (format ?? []).compactMap(\.label).filter { !$0.isEmpty } }

    /// true — есть подтверждённые маркеры, что глав нет НЕ потому что их
    /// просто ещё не залили, а потому что тайтл лицензирован (главы скрыты)
    /// или сейчас на проверке модерации. isLicensed — прямой, подтверждённый
    /// перехватом флаг. moderated.label — доп. эвристика (ключевое слово
    /// "проверк*"): у самого подтверждённого примера моdered.label был
    /// "Принято модерацией" (уже одобрено, не блокирует само по себе) — но
    /// для тайтлов, реально ЕЩЁ на проверке, метка, по всей видимости,
    /// другая ("На проверке"/"На модерации" и т.п.), поэтому проверяем ключевое
    /// слово, а не только isLicensed.
    var isBlockedByLicenseOrModeration: Bool {
        isLicensed || (moderated?.label?.localizedCaseInsensitiveContains("проверк") ?? false)
    }

    /// URL фоновой картинки для шапки экрана тайтла — своя (если реально
    /// пришла с сервера), иначе обложка (см. комментарий у background выше;
    /// именно это "если не удаётся — ставь обложку" и попросили).
    var backgroundURL: URL? { background?.bestURL ?? cover?.bestURL }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, cover, background, rating, status, type, site, summary, genres, tags, authors, artists, publisher, views, format, moderated, franchise
        case otherNames = "otherNames"
        case otherNamesSnake = "other_names"
        case ageRestriction = "ageRestriction"
        case isLicensed = "is_licensed"
        case rusName = "rus_name"
        case engName = "eng_name"
        case slugURL = "slug_url"
        case releaseDate = "releaseDate"
        case releaseDateString = "releaseDateString"
        case releaseDateSnake = "release_date"
        case viewsCount = "views_count"
        case description
    }

    // Защитный декодер: неизвестная форма второстепенных полей (год/просмотры/формат
    // отличаются от сайта к сайту) не должна ронять весь разбор карточки.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rusName = try? c.decodeIfPresent(String.self, forKey: .rusName) ?? nil
        engName = try? c.decodeIfPresent(String.self, forKey: .engName) ?? nil
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        slugURL = try? c.decodeIfPresent(String.self, forKey: .slugURL) ?? nil
        cover = try? c.decodeIfPresent(MangaCover.self, forKey: .cover) ?? nil
        background = try? c.decodeIfPresent(MangaBackgroundImage.self, forKey: .background) ?? nil
        rating = try? c.decodeIfPresent(MangaRating.self, forKey: .rating) ?? nil
        status = try? c.decodeIfPresent(MangaStatus.self, forKey: .status) ?? nil
        type = try? c.decodeIfPresent(MangaStatus.self, forKey: .type) ?? nil
        ageRestriction = try? c.decodeIfPresent(MangaStatus.self, forKey: .ageRestriction) ?? nil
        site = (try? c.decodeIfPresent(Int.self, forKey: .site)) ?? nil
        isLicensed = (try? c.decodeIfPresent(Bool.self, forKey: .isLicensed)) ?? false
        moderated = try? c.decodeIfPresent(MangaStatus.self, forKey: .moderated) ?? nil
        franchise = ((try? c.decodeIfPresent([FranchiseRef].self, forKey: .franchise)) ?? nil)?.first
        // "summary"/"description" — оба ключа пробуем, ПЛЮС на случай, если
        // описание приходит не голой строкой, а вложенным объектом (напр.
        // {"ru": "...", "text": "..."}) — тоже не подтверждено перехватом,
        // поэтому декодируем максимально гибко через decodeFlexibleText.
        let summaryValue = Self.decodeFlexibleText(c, .summary)
        let descriptionValue = Self.decodeFlexibleText(c, .description)
        summary = [summaryValue, descriptionValue].compactMap { $0 }.first { !$0.isEmpty }
        genres = try? c.decodeIfPresent([NamedEntity].self, forKey: .genres) ?? nil
        tags = try? c.decodeIfPresent([NamedEntity].self, forKey: .tags) ?? nil
        authors = try? c.decodeIfPresent([DirectoryEntity].self, forKey: .authors) ?? nil
        artists = try? c.decodeIfPresent([DirectoryEntity].self, forKey: .artists) ?? nil
        publisher = try? c.decodeIfPresent([DirectoryEntity].self, forKey: .publisher) ?? nil
        otherNames = Self.decodeStringList(c, .otherNames, .otherNamesSnake)
        // Подтверждено реальным JSON: [{"id":6,"name":"Веб"}] — ключ "name",
        // как у жанров/тегов. FlexibleLabelEntity также пробует "label"
        // запасным вариантом.
        format = try? c.decodeIfPresent([FlexibleLabelEntity].self, forKey: .format) ?? nil

        // Год: releaseDate (строка/число), releaseDateString, либо
        // snake_case release_date — реальный ключ не подтверждён перехватом,
        // пробуем все варианты по очереди.
        if let s = try? c.decodeIfPresent(String.self, forKey: .releaseDate), !s.isEmpty {
            releaseDate = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .releaseDate) {
            releaseDate = String(i)
        } else if let s2 = try? c.decodeIfPresent(String.self, forKey: .releaseDateString), !s2.isEmpty {
            releaseDate = s2
        } else if let s3 = try? c.decodeIfPresent(String.self, forKey: .releaseDateSnake), !s3.isEmpty {
            releaseDate = s3
        } else if let i3 = try? c.decodeIfPresent(Int.self, forKey: .releaseDateSnake) {
            releaseDate = String(i3)
        } else {
            releaseDate = nil
        }

        // views — ПОДТВЕРЖДЕНО реальным JSON: объект `{"total":44819,
        // "short":"44.8 K","formated":"44 819"}`, а не голое число. Берём
        // "total" и форматируем сами по-русски (см. viewsString) — короткая
        // строка от сервера в английском стиле ("K"/"M") нам не подходит.
        // Старые варианты (число/строка/views_count) оставлены как запасные
        // на случай другого сайта.
        struct ViewsObject: Decodable { let total: Int? }
        if let obj = (try? c.decodeIfPresent(ViewsObject.self, forKey: .views)).flatMap({ $0 }), let t = obj.total {
            views = t
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .views) {
            views = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .views), let i = Int(s) {
            views = i
        } else if let i2 = try? c.decodeIfPresent(Int.self, forKey: .viewsCount) {
            views = i2
        } else if let s2 = try? c.decodeIfPresent(String.self, forKey: .viewsCount), let i2 = Int(s2) {
            views = i2
        } else {
            views = nil
        }
    }

    /// Разбор списка альтернативных названий из любого из переданных ключей.
    /// Сервер может отдать их либо простым массивом строк (["Solo Leveling",
    /// ...]), либо массивом объектов вида {"name": "..."} (как жанры/теги) —
    /// пробуем оба варианта. Пустой/отсутствующий → nil.
    private static func decodeStringList(_ c: KeyedDecodingContainer<CodingKeys>, _ keys: CodingKeys...) -> [String]? {
        for key in keys {
            if let arr = (try? c.decodeIfPresent([String].self, forKey: key)) ?? nil {
                let cleaned = arr.filter { !$0.isEmpty }
                if !cleaned.isEmpty { return cleaned }
            }
            if let objs = (try? c.decodeIfPresent([NamedEntity].self, forKey: key)) ?? nil {
                let names = objs.map(\.name).filter { !$0.isEmpty }
                if !names.isEmpty { return names }
            }
        }
        return nil
    }

    /// Гибкое декодирование текстового поля (описания): пробуем по очереди —
    /// 1) обычную строку; 2) ПОДТВЕРЖДЁННОЕ реальным JSON дерево ProseMirror/
    /// TipTap (см. SummaryDoc) — именно так реально приходит "summary";
    /// 3) произвольный вложенный объект с типичными под-ключами (ru/text/
    /// value/en/description) — запасной вариант на случай другого сайта.
    private static func decodeFlexibleText(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let plain = (try? c.decodeIfPresent(String.self, forKey: key)).flatMap({ $0 }), !plain.isEmpty {
            return plain
        }
        if let doc = (try? c.decodeIfPresent(SummaryDoc.self, forKey: key)).flatMap({ $0 }) {
            let text = doc.plainText
            if !text.isEmpty { return text }
        }
        struct NestedText: Decodable {
            let ru: String?
            let en: String?
            let text: String?
            let value: String?
            let description: String?
        }
        if let nested = (try? c.decodeIfPresent(NestedText.self, forKey: key)).flatMap({ $0 }) {
            if let found = [nested.ru, nested.text, nested.value, nested.en, nested.description]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty }) {
                return found
            }
        }
        // Последний рубеж: если ни одна из угаданных структур не подошла —
        // разбираем ЛЮБОЙ JSON под этим ключом и сами ищем в нём читаемый
        // текст (см. AnyJSON.extractReadableText). Это должно сработать,
        // даже если реальная форма чуть отличается от того, что мы уже
        // пробовали (другие имена узлов, лишняя обёртка и т.п.).
        if let generic = (try? c.decodeIfPresent(AnyJSON.self, forKey: key)).flatMap({ $0 }) {
            let text = generic.extractReadableText()
            if !text.isEmpty { return text }
        }
        return nil
    }
}

// MARK: - Character

/// Персонаж в списке персонажей тайтла — ПОДТВЕРЖДЕНО перехватом
/// `GET /character?media_id=&media_type=manga`: `{id, slug, slug_url,
/// model:"character", cover, name (англ), rus_name, details:{order,
/// position:{id:"Main", label:"Главный"}}}`.
struct Character: Decodable, Identifiable {
    let id: Int
    let slugURL: String
    let name: String
    let rusName: String?
    let cover: MangaCover?
    let positionLabel: String?

    var displayName: String { rusName?.isEmpty == false ? rusName! : name }

    private struct Details: Decodable {
        struct Position: Decodable { let label: String? }
        let position: Position?
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, cover, details
        case slugURL = "slug_url"
        case rusName = "rus_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        let su = (try? c.decodeIfPresent(String.self, forKey: .slugURL)) ?? nil
        slugURL = (su?.isEmpty == false ? su : nil) ?? ((try? c.decode(String.self, forKey: .slug)) ?? String(id))
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rusName = (try? c.decodeIfPresent(String.self, forKey: .rusName)) ?? nil
        cover = (try? c.decodeIfPresent(MangaCover.self, forKey: .cover)) ?? nil
        let details = (try? c.decodeIfPresent(Details.self, forKey: .details)) ?? nil
        positionLabel = details?.position?.label
    }
}

/// Детальная страница персонажа — ПОДТВЕРЖДЕНО перехватом
/// `GET /character/{slug_url}`: помимо полей списка есть `alt_name` (оригинал),
/// `dsc` (ProseMirror-описание), `stats[]` (`{value, label, tag:"titles"}`,
/// `{..., tag:"subscribes"}`) и `titles_count_details {site_id: count}`.
struct CharacterDetail: Decodable, Identifiable {
    let id: Int
    let slugURL: String
    let name: String
    let rusName: String?
    let altName: String?
    let cover: MangaCover?
    let description: String?
    let titlesCount: Int?
    let subscribersCount: Int?
    /// site_id → число тайтлов (1=манга, 3=новеллы, 4=хентай, 5=аниме).
    let titlesCountBySite: [Int: Int]

    var displayName: String { rusName?.isEmpty == false ? rusName! : name }

    private struct Stat: Decodable { let value: Int?; let tag: String? }

    enum CodingKeys: String, CodingKey {
        case id, name, cover, dsc, stats
        case slugURL = "slug_url"
        case rusName = "rus_name"
        case altName = "alt_name"
        case titlesCountDetails = "titles_count_details"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        slugURL = ((try? c.decodeIfPresent(String.self, forKey: .slugURL)) ?? nil) ?? String(id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rusName = (try? c.decodeIfPresent(String.self, forKey: .rusName)) ?? nil
        altName = (try? c.decodeIfPresent(String.self, forKey: .altName)) ?? nil
        cover = (try? c.decodeIfPresent(MangaCover.self, forKey: .cover)) ?? nil

        // dsc — тот же ProseMirror/TipTap, что и summary тайтла: сначала
        // SummaryDoc, затем универсальный AnyJSON как запасной вариант.
        var desc: String? = nil
        if let doc = (try? c.decodeIfPresent(SummaryDoc.self, forKey: .dsc)) ?? nil {
            let t = doc.plainText
            if !t.isEmpty { desc = t }
        }
        if desc == nil, let generic = (try? c.decodeIfPresent(AnyJSON.self, forKey: .dsc)) ?? nil {
            let t = generic.extractReadableText()
            if !t.isEmpty { desc = t }
        }
        description = desc

        let stats = ((try? c.decodeIfPresent([Stat].self, forKey: .stats)) ?? nil) ?? []
        titlesCount = stats.first { $0.tag == "titles" }?.value
        subscribersCount = stats.first { $0.tag == "subscribes" }?.value

        if let raw = ((try? c.decodeIfPresent([String: Int].self, forKey: .titlesCountDetails)) ?? nil) {
            var m: [Int: Int] = [:]
            for (k, v) in raw { if let ik = Int(k) { m[ik] = v } }
            titlesCountBySite = m
        } else {
            titlesCountBySite = [:]
        }
    }
}

// MARK: - Команда перевода (детальная страница)

/// Одна метрика в шапке страницы переводчика — ПОДТВЕРЖДЕНО перехватом:
/// сервер сам отдаёт готовые label ("Тайтлов"/"Лайков"/"Глава"/"Глав / мес"/
/// "Подписчика") и короткое отображаемое значение (short, напр. "8.9 M") —
/// в отличие от CharacterDetail (там подписи захардкожены в UI, потому что
/// в перехвате персонажа было только 2 метрики без готовых русских label).
/// Здесь label уже готовы и в том же порядке, что в перехвате, — используем
/// как есть, не дублируя переводы вручную.
struct TeamStat: Decodable, Identifiable {
    let value: Int?
    let short: String?
    let label: String?
    let tag: String?
    var id: String { tag ?? label ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey { case value, short, label, tag }
}

/// Один участник команды с РЕАЛЬНЫМИ данными — ПОДТВЕРЖДЕНО перехватом
/// ОТДЕЛЬНОГО эндпоинта `GET /teams/{slug_url}/users` (не путать с полем
/// "users" внутри GET /teams/{slug_url} — там участники анонимны, только
/// роль, без id/username/аватара вообще — decode того эндпоинта не делаем,
/// раз этот, отдельный, отдаёт то же самое, но с реальными данными):
/// `{data:[{user:{id,username,avatar:{filename,url},avatar_frame:{orig,lg,
/// md,sm}}, roles:[{id,label}], roles_string, order}]}`. avatar_frame —
/// ПОДТВЕРЖДЕНО перехватом (встречается у части участников; относительный
/// путь, как и у плейсхолдера фона, — достраивается тем же
/// UserProfile.absoluteURL) — декоративная рамка поверх аватара, см.
/// TeamView.memberChip.
struct TeamMemberEntry: Decodable, Identifiable {
    let userId: Int
    let username: String
    let avatarURL: URL?
    let avatarFrameURL: URL?
    let rolesString: String?

    private struct UserRef: Decodable {
        let id: Int
        let username: String
        let avatar: AvatarRef?
        let avatarFrame: FrameRef?
        enum CodingKeys: String, CodingKey { case id, username, avatar, avatarFrame = "avatar_frame" }
    }
    private struct AvatarRef: Decodable { let url: String? }
    private struct FrameRef: Decodable { let md: String?; let orig: String? }

    enum CodingKeys: String, CodingKey { case user, rolesString = "roles_string" }

    var id: Int { userId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let user = (try? c.decodeIfPresent(UserRef.self, forKey: .user)) ?? nil
        userId = user?.id ?? 0
        username = user?.username ?? "Без имени"
        avatarURL = UserProfile.absoluteURL(user?.avatar?.url)
        avatarFrameURL = UserProfile.absoluteURL(user?.avatarFrame?.md ?? user?.avatarFrame?.orig)
        rolesString = (try? c.decodeIfPresent(String.self, forKey: .rolesString)) ?? nil
    }
}

/// Ответ подписки/отписки на команду-переводчика — ПОДТВЕРЖДЕНО перехватом
/// `POST /favorites {source_id, source_type:"team"}` →
/// `{data:{is_subscribed,source_type,source_id,relation},
/// meta:{stats:{value,formated,short,label,tag}}}` — toggle подтверждён
/// РАБОЧИМ в ОБЕ стороны новым перехватом (было под сомнением, теперь нет).
/// Тот же тип переиспользован и для `GET /favorites/{source_type}/{id}`
/// (проверка ТЕКУЩЕГО статуса без переключения, ПОДТВЕРЖДЕНО перехватом —
/// ответ той же формы, просто без meta) — см.
/// MangaNetworkService.fetchFavoriteStatus.
struct FavoriteToggleResponse: Decodable {
    let isSubscribed: Bool
    let subscribersStat: TeamStat?

    private struct DataPart: Decodable { let isSubscribed: Bool?; enum CodingKeys: String, CodingKey { case isSubscribed = "is_subscribed" } }
    private struct MetaPart: Decodable { let stats: TeamStat? }

    enum CodingKeys: String, CodingKey { case data, meta }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = (try? c.decodeIfPresent(DataPart.self, forKey: .data)) ?? nil
        let m = (try? c.decodeIfPresent(MetaPart.self, forKey: .meta)) ?? nil
        isSubscribed = d?.isSubscribed ?? false
        subscribersStat = m?.stats
    }
}

/// Детальная страница переводчика (команды) — ПОДТВЕРЖДЕНО реальным
/// перехватом `GET /teams/{slug_url}?fields[]=chaptersPerMonth&
/// fields[]=auto_moderation&fields[]=team_rating&fields[]=ignored_by_user`.
/// team_rating/auto_moderation/ignored_by_user в перехвате ЕСТЬ, но здесь
/// не декодируются — экран пока не реализует оценку/жалобы/модерацию (см.
/// список "что уточнить" в чате), декодер их просто проигнорирует.
struct TeamDetail: Decodable, Identifiable {
    let id: Int
    let slug: String
    let slugURL: String
    let name: String
    let cover: MangaCover?
    let background: MangaBackgroundImage?
    let altName: String?
    let vk: String?
    let discord: String?
    let website: String?
    let description: String?
    let stats: [TeamStat]
    let titlesCountBySite: [Int: Int]

    enum CodingKeys: String, CodingKey {
        case id, slug, name, cover, background, vk, discord, website, stats, description
        case slugURL = "slug_url"
        case altName = "alt_name"
        case titlesCountDetails = "titles_count_details"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        slugURL = ((try? c.decodeIfPresent(String.self, forKey: .slugURL)) ?? nil) ?? slug
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        cover = (try? c.decodeIfPresent(MangaCover.self, forKey: .cover)) ?? nil
        background = (try? c.decodeIfPresent(MangaBackgroundImage.self, forKey: .background)) ?? nil
        altName = (try? c.decodeIfPresent(String.self, forKey: .altName)) ?? nil
        vk = (try? c.decodeIfPresent(String.self, forKey: .vk)) ?? nil
        discord = (try? c.decodeIfPresent(String.self, forKey: .discord)) ?? nil
        website = (try? c.decodeIfPresent(String.self, forKey: .website)) ?? nil

        // "description" — тот же ProseMirror/doc, что и у персонажа/тайтла,
        // но с активным использованием hardBreak между текстовыми узлами
        // (см. реальный перехваченный пример) — SummaryDoc/SummaryNode.plainText
        // склеивает детей БЕЗ разделителя и игнорирует hardBreak, из-за чего
        // текст слипся бы в одну строку. AnyJSON.extractReadableText() же
        // берёт каждый текстовый узел как отдельный абзац (разделяя "\n\n") —
        // для этой формы результат читаемее, поэтому используется он один,
        // без промежуточной попытки через SummaryDoc.
        if let generic = (try? c.decodeIfPresent(AnyJSON.self, forKey: .description)) ?? nil {
            let t = generic.extractReadableText()
            description = t.isEmpty ? nil : t
        } else {
            description = nil
        }

        stats = ((try? c.decodeIfPresent([TeamStat].self, forKey: .stats)) ?? nil) ?? []

        if let raw = ((try? c.decodeIfPresent([String: Int].self, forKey: .titlesCountDetails)) ?? nil) {
            var m: [Int: Int] = [:]
            for (k, v) in raw { if let ik = Int(k) { m[ik] = v } }
            titlesCountBySite = m
        } else {
            titlesCountBySite = [:]
        }
    }
}

// MARK: - Франшиза

/// Франшиза — ПОДТВЕРЖДЕНО перехватом `GET /franchise` (список) и
/// `GET /franchise/{id}--{slug}` (одна) — ОДНА И ТА ЖЕ форма в обоих:
/// `{id, slug, slug_url, model:"franchise", name, alt_name, subscription:
/// {is_subscribed,...}, stats:[{value,formated,short,label,tag}],
/// titles_count_details:{site_id:count}}`. Общий на ВСЮ экосистему
/// справочник (не завязан на активный сайт) — ПОДТВЕРЖДЕНО прямым
/// сравнением перехватов MangaLib/HentaiLib: франшиза id 308 «Оригинальные
/// работы» — с абсолютно тем же id/названием/titles_count_details на обоих
/// сайтах. Без обложки/аватара — только текст и счётчики. stats — та же
/// форма, что и у TeamStat (переиспользуется).
struct Franchise: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: String
    let slugURL: String
    let name: String
    let altName: String?
    var isSubscribed: Bool
    let stats: [TeamStat]
    /// site_id → число тайтлов (1=манга, 2=слэш, 3=новеллы, 4=хентай, 5=аниме).
    let titlesCountBySite: [Int: Int]

    var titlesCount: Int? { stats.first { $0.tag == "titles" }?.value }
    var subscribersCount: Int? { stats.first { $0.tag == "subscribes" }?.value }

    private struct Subscription: Decodable {
        let isSubscribed: Bool?
        enum CodingKeys: String, CodingKey { case isSubscribed = "is_subscribed" }
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, stats, subscription
        case slugURL = "slug_url"
        case altName = "alt_name"
        case titlesCountDetails = "titles_count_details"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        slugURL = ((try? c.decodeIfPresent(String.self, forKey: .slugURL)) ?? nil) ?? slug
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        altName = (try? c.decodeIfPresent(String.self, forKey: .altName)) ?? nil
        let subscription = (try? c.decodeIfPresent(Subscription.self, forKey: .subscription)) ?? nil
        isSubscribed = subscription?.isSubscribed ?? false
        stats = ((try? c.decodeIfPresent([TeamStat].self, forKey: .stats)) ?? nil) ?? []

        if let raw = ((try? c.decodeIfPresent([String: Int].self, forKey: .titlesCountDetails)) ?? nil) {
            var m: [Int: Int] = [:]
            for (k, v) in raw { if let ik = Int(k) { m[ik] = v } }
            titlesCountBySite = m
        } else {
            titlesCountBySite = [:]
        }
    }

    static func == (lhs: Franchise, rhs: Franchise) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Общие "каталожные" сущности (команды/персонажи/люди/издательства)

/// Общая форма для команд/персонажей/людей(авторов)/издательств —
/// ПОДТВЕРЖДЕНО перехватом на списках `GET /teams`, `GET /character`,
/// `GET /people`, `GET /publisher`, А ТАКЖЕ как embedded-поля тайтла
/// (`authors`/`artists`/`publisher` у `GET /manga/{slug}`, та же форма один
/// в один). Не каждое поле есть у каждого вида: teams в списке БЕЗ
/// subscription/titles_count_details/rus_name/alt_name (у них отдельный
/// подтверждённый способ проверки подписки, см. TeamViewModel), publisher
/// без alt_name — всё это Optional и просто отсутствует, где сервер не
/// прислал. Персонаж — единственный, для кого фактическая подписка (POST
/// /favorites) НЕ подтверждена перехватом, хотя поле subscription в его
/// списке ЕСТЬ (см. DirectoryKind.character/sourceType == nil — сознательно
/// не даём переключать то, что не проверено).
struct DirectoryEntity: Decodable, Identifiable, Hashable {
    let id: Int
    let slugURL: String
    let model: String
    let name: String
    let rusName: String?
    let altName: String?
    let coverURL: URL?
    var isSubscribed: Bool
    let stats: [TeamStat]
    /// site_id → число тайтлов, где не пусто (1=манга,2=слэш,3=новеллы,4=хентай,5=аниме).
    let titlesCountBySite: [Int: Int]
    /// Описание ("dsc") — только в детальном ответе, тот же ProseMirror/
    /// TipTap формат, что и у CharacterDetail.description (та же логика
    /// разбора: сперва SummaryDoc, затем универсальный AnyJSON запасным
    /// вариантом).
    let description: String?

    var displayName: String { rusName?.isEmpty == false ? rusName! : name }
    var titlesCount: Int? { stats.first { $0.tag == "titles" }?.value }
    var subscribersCount: Int? { stats.first { $0.tag == "subscribes" }?.value }

    private struct Subscription: Decodable {
        let isSubscribed: Bool?
        enum CodingKeys: String, CodingKey { case isSubscribed = "is_subscribed" }
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, model, name, stats, subscription, cover, dsc
        case slugURL = "slug_url"
        case rusName = "rus_name"
        case altName = "alt_name"
        case titlesCountDetails = "titles_count_details"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        let slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        slugURL = ((try? c.decodeIfPresent(String.self, forKey: .slugURL)) ?? nil) ?? slug
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rusName = (try? c.decodeIfPresent(String.self, forKey: .rusName)) ?? nil
        altName = (try? c.decodeIfPresent(String.self, forKey: .altName)) ?? nil
        coverURL = ((try? c.decodeIfPresent(MangaCover.self, forKey: .cover)) ?? nil)?.bestURL
        let subscription = (try? c.decodeIfPresent(Subscription.self, forKey: .subscription)) ?? nil
        isSubscribed = subscription?.isSubscribed ?? false
        stats = ((try? c.decodeIfPresent([TeamStat].self, forKey: .stats)) ?? nil) ?? []

        if let raw = ((try? c.decodeIfPresent([String: Int].self, forKey: .titlesCountDetails)) ?? nil) {
            var m: [Int: Int] = [:]
            for (k, v) in raw { if let ik = Int(k) { m[ik] = v } }
            titlesCountBySite = m
        } else {
            titlesCountBySite = [:]
        }

        var desc: String? = nil
        if let doc = (try? c.decodeIfPresent(SummaryDoc.self, forKey: .dsc)) ?? nil {
            let t = doc.plainText
            if !t.isEmpty { desc = t }
        }
        if desc == nil, let generic = (try? c.decodeIfPresent(AnyJSON.self, forKey: .dsc)) ?? nil {
            let t = generic.extractReadableText()
            if !t.isEmpty { desc = t }
        }
        description = desc
    }

    static func == (lhs: DirectoryEntity, rhs: DirectoryEntity) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Один аккаунт в справочнике пользователей — ПОДТВЕРЖДЕНО перехватом
/// `GET /user?page=&sort_by=id&sort_type=desc`: `{id, username, avatar:
/// {filename,url}, last_online_at, can_view_profile, created_at,
/// login_streak, premium}`. Совсем другая форма, чем у DirectoryEntity — это
/// учётная запись, а не контент-сущность (нет model/subscription/stats).
struct DirectoryUserEntry: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    let avatarURL: URL?
    let isPremium: Bool

    private struct ImageRef: Decodable { let url: String? }
    private struct PremiumRef: Decodable { let enabled: Bool? }
    private enum CodingKeys: String, CodingKey { case id, username, avatar, premium }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        username = ((try? c.decodeIfPresent(String.self, forKey: .username)) ?? nil) ?? ""
        let avatarRef = (try? c.decodeIfPresent(ImageRef.self, forKey: .avatar)) ?? nil
        avatarURL = UserProfile.absoluteURL(avatarRef?.url)
        isPremium = ((try? c.decodeIfPresent(PremiumRef.self, forKey: .premium)) ?? nil)?.enabled ?? false
    }
}

/// Ссылка на франшизу тайтла — ПОДТВЕРЖДЕНО перехватом `GET /manga/{slug}?
/// fields[]=franchise`: `"franchise":[{"id","slug","slug_url","model":
/// "franchise","name"}]` — массив (на практике из одного элемента), БЕЗ
/// alt_name/подписки/статистики (те есть только в отдельном
/// GET /franchise/{id}--{slug}, см. Franchise/MangaNetworkService.fetchFranchiseDetail).
struct FranchiseRef: Decodable, Identifiable, Hashable {
    let id: Int
    let slugURL: String
    let name: String

    enum CodingKeys: String, CodingKey { case id, name, slugURL = "slug_url" }
}

// MARK: - Chapter

/// Команда перевода (сканлейт-тим) — ПОДТВЕРЖДЕНО перехватом ветки:
/// `{id, slug, slug_url, model:"team", name:"May Days", cover:{thumbnail,default,md}}`.
/// cover — аватар команды (у некоторых плейсхолдер user_avatar.png). slugURL
/// нужен для перехода на страницу переводчика (см. TeamView) — раньше не
/// декодировался, хотя в перехвате есть.
struct ChapterTeam: Decodable, Identifiable {
    let id: Int
    let name: String
    let cover: MangaCover?
    let slugURL: String?
    var avatarURL: URL? { cover?.bestURL }
    enum CodingKeys: String, CodingKey { case id, name, cover, slugURL = "slug_url" }
}

/// Кто залил ветку — `{username, id}`. Запасная подпись, если у ветки нет team.
struct BranchUser: Decodable, Hashable {
    let id: Int
    let username: String
}

/// Ветка перевода (одна команда) внутри главы.
struct ChapterBranch: Decodable, Identifiable, Hashable {
    let id: Int?
    let branchId: Int?
    let teams: [ChapterTeam]?
    let user: BranchUser?
    /// Дата публикации ветки — ПОДТВЕРЖДЕНО перехватом: у главы даты нет, она
    /// лежит здесь ("created_at":"2022-08-12T18:49:13.000000Z").
    let createdAt: String?

    /// Стабильный идентификатор для SwiftUI (id может быть nil).
    var identity: Int { id ?? branchId ?? 0 }
    var idValue: Int { identity }

    /// Подпись ветки: имя команды, иначе — ник заливавшего.
    var teamName: String { teams?.first?.name ?? user?.username ?? "Неизвестно" }
    var teamId: Int? { teams?.first?.id }
    var teamAvatarURL: URL? { teams?.first?.avatarURL }

    /// Дата ветки в формате «дд.мм.гггг».
    var dateString: String? {
        guard let createdAt, createdAt.count >= 10 else { return nil }
        let d = String(createdAt.prefix(10))
        let parts = d.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }

    enum CodingKeys: String, CodingKey {
        case id, teams, user
        case branchId = "branch_id"
        case createdAt = "created_at"
    }

    /// Локальная сборка (для оффлайна / реконструкции из manifest).
    init(id: Int? = nil, branchId: Int?, teams: [ChapterTeam]? = nil,
         user: BranchUser? = nil, createdAt: String? = nil) {
        self.id = id
        self.branchId = branchId
        self.teams = teams
        self.user = user
        self.createdAt = createdAt
    }

    static func == (lhs: ChapterBranch, rhs: ChapterBranch) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

struct ChapterItem: Decodable, Identifiable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let name: String?
    let branches: [ChapterBranch]?
    let createdAt: String?

    /// Заголовок главы для списка: «Том X, Глава Y — Название».
    var displayTitle: String {
        var parts = ["Том \(volume)", "Глава \(number)"]
        if let name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// Короткий заголовок «Том X Глава Y».
    var shortTitle: String { "Том \(volume) Глава \(number)" }

    /// Название главы (или короткий заголовок, если пусто).
    var titleOrShort: String { (name?.isEmpty == false) ? name! : shortTitle }

    /// ISO-дата выпуска главы: сперва верхнеуровневый created_at (если вдруг
    /// есть), иначе — САМАЯ РАННЯЯ ветка перевода (branches[].created_at). Строки
    /// ISO8601 сортируются лексикографически = хронологически, поэтому min = самая
    /// ранняя публикация. Подтверждено перехватом: у главы даты нет, она в ветках.
    var releaseDateISO: String? {
        if let createdAt, !createdAt.isEmpty { return createdAt }
        return (branches ?? []).compactMap { $0.createdAt }.filter { !$0.isEmpty }.min()
    }

    /// Дата в формате «дд.мм.гггг».
    var dateString: String? {
        guard let iso = releaseDateISO, iso.count >= 10 else { return nil }
        let d = String(iso.prefix(10))               // 2022-08-12
        let parts = d.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[2]).\(parts[1]).\(parts[0])"  // 12.08.2022
    }

    /// Первый доступный branch_id (нужен для запроса страниц, если веток несколько).
    var primaryBranchId: Int? { branches?.first?.branchId }

    enum CodingKeys: String, CodingKey {
        case id, volume, number, name, branches
        case createdAt = "created_at"
    }

    static func == (lhs: ChapterItem, rhs: ChapterItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Локальная сборка (для оффлайн-чтения скачанных глав) — без сети/декодера.
    init(id: Int, volume: String, number: String, name: String?,
         branches: [ChapterBranch]? = nil, createdAt: String? = nil) {
        self.id = id
        self.volume = volume
        self.number = number
        self.name = name
        self.branches = branches
        self.createdAt = createdAt
    }

    // Значения volume/number приходят то строкой, то числом — нормализуем к String.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        volume = try Self.flexibleString(c, .volume) ?? "1"
        number = try Self.flexibleString(c, .number) ?? "0"
        name = try c.decodeIfPresent(String.self, forKey: .name)
        branches = try c.decodeIfPresent([ChapterBranch].self, forKey: .branches)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt) ?? nil
    }

    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        return nil
    }
}

// MARK: - Chapter pages

/// Ответ эндпоинта главы: содержит страницы. Иногда сервер отдаёт список серверов картинок.
struct ChapterPagesResponse: Decodable {
    let data: ChapterPagesData
}

struct ChapterPagesData: Decodable {
    let id: Int?
    let pages: [PageItem]
    /// Не подтверждено перехватом реального запроса — предположительное поле
    /// из общего описания API. Optional и по умолчанию false — если сервер
    /// его не пришлёт, ничего не сломается (просто отметка "уже просмотрено"
    /// не сработает как быстрая проверка, и приложение всё равно отправит
    /// markChapterViewed как раньше).
    let isViewed: Bool?
    /// Команда(ы), переводившие ИМЕННО эту главу — ПОДТВЕРЖДЕНО реальным
    /// перехватом ("Над главой работали", см. MangaReaderView.endHeader) —
    /// та же модель, что и у ChapterBranch.teams, просто здесь прямо в
    /// ответе главы, без обёртки веткой.
    let teams: [ChapterTeam]?
    /// "Спасибо" переводчикам (лайк главы, см. MangaNetworkService.
    /// likeChapter) — ПОДТВЕРЖДЕНО реальным перехватом: оба поля уже
    /// приходят прямо в ответе главы, не нужно отдельного запроса, чтобы
    /// узнать текущее состояние при открытии.
    let likesCount: Int?
    let isLiked: Bool?
    /// Оценка перевода (см. MangaNetworkService.rateTranslation) —
    /// ПОДТВЕРЖДЕНО реальным перехватом: агрегат + твоя предыдущая оценка
    /// (если была) приходят прямо в ответе главы.
    let translationRating: TranslationRating?

    enum CodingKeys: String, CodingKey {
        case id, pages, teams
        case isViewed = "is_viewed"
        case likesCount = "likes_count"
        case isLiked = "is_liked"
        case translationRating = "translation_quality_rating"
    }
}

/// Оценка качества перевода главы по 3 категориям — ПОДТВЕРЖДЕНО реальным
/// перехватом `POST /chapters/{id}/translation-rating` (см.
/// MangaNetworkService.rateTranslation) и тем же форматом прямо внутри
/// ответа главы (ChapterPagesData.translationRating). `categories` —
/// средние ОБЩИЕ (всех проголосовавших) по каждой категории, `user` —
/// ТВОИ предыдущие значения (если оценивал).
struct TranslationRating: Decodable {
    let average: String?
    let averageFormated: String?
    let votes: Int?
    let ratedChapters: Int?
    let canRate: Bool?
    let categories: TranslationRatingCategories?
    let user: TranslationRatingUser?

    enum CodingKeys: String, CodingKey {
        case average, averageFormated, votes, categories, user
        case ratedChapters = "rated_chapters"
        case canRate = "can_rate"
    }
}

struct TranslationRatingCategories: Decodable {
    let translationAccuracy: String?
    let readabilityAdaptation: String?
    let editingFormatting: String?

    enum CodingKeys: String, CodingKey {
        case translationAccuracy = "translation_accuracy"
        case readabilityAdaptation = "readability_adaptation"
        case editingFormatting = "editing_formatting"
    }
}

/// Твои предыдущие оценки по 3 категориям — ПОДТВЕРЖДЕНО перехватом: у ещё
/// не оценённой (тобой) главы сервер прислал ровно "0" в каждом поле (та же
/// семантика 0 == "не оценено", что и у MangaRating.myScore — шкала 1-10,
/// 0 руками не поставить), отсюда myScores.
struct TranslationRatingUser: Decodable {
    let translationAccuracy: Int?
    let readabilityAdaptation: Int?
    let editingFormatting: Int?

    enum CodingKeys: String, CodingKey {
        case translationAccuracy = "translation_accuracy"
        case readabilityAdaptation = "readability_adaptation"
        case editingFormatting = "editing_formatting"
    }

    /// nil, если ещё не оценено (0 или отсутствует) — иначе (accuracy,
    /// readability, editing), для предзаполнения RateTranslationSheet.
    var myScores: (accuracy: Int, readability: Int, editing: Int)? {
        guard let translationAccuracy, let readabilityAdaptation, let editingFormatting,
              translationAccuracy > 0 || readabilityAdaptation > 0 || editingFormatting > 0 else { return nil }
        return (translationAccuracy, readabilityAdaptation, editingFormatting)
    }
}

// MARK: - Комментарии (ПОДТВЕРЖДЕНО реальным перехватом)

extension Date {
    /// Относительное время по-русски, ОДНОЙ единицей — "5 дней назад",
    /// "7 часов назад", "2 месяца назад" и т.д., с правильным русским
    /// склонением (1 день/2 дня/5 дней). Раньше использовался системный
    /// Text(date, style: .relative) — он показывал время либо по-английски,
    /// либо КОМБИНИРОВАННО ("3 дня 17 часов назад"), что явно попросили
    /// убрать: нужна только ОДНА, самая крупная подходящая единица.
    var relativeRussianString: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        let minute = 60.0, hour = 3600.0, day = 86400.0, month = 2_592_000.0, year = 31_536_000.0

        func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
            let mod100 = n % 100
            if (11...14).contains(mod100) { return many }
            switch n % 10 {
            case 1: return one
            case 2...4: return few
            default: return many
            }
        }

        switch seconds {
        case ..<minute:
            return "только что"
        case ..<hour:
            let n = Int(seconds / minute)
            return "\(n) \(plural(n, "минуту", "минуты", "минут")) назад"
        case ..<day:
            let n = Int(seconds / hour)
            return "\(n) \(plural(n, "час", "часа", "часов")) назад"
        case ..<month:
            let n = Int(seconds / day)
            return "\(n) \(plural(n, "день", "дня", "дней")) назад"
        case ..<year:
            let n = Int(seconds / month)
            return "\(n) \(plural(n, "месяц", "месяца", "месяцев")) назад"
        default:
            let n = Int(seconds / year)
            return "\(n) \(plural(n, "год", "года", "лет")) назад"
        }
    }
}

/// Комментарий — форма ПОДТВЕРЖДЕНА реальными перехваченными запросами:
/// GET и POST /comments возвращают ОДНУ и ту же плоскую форму объекта,
/// вложенность ответов кодируется через commentLevel/parentComment/rootId, а
/// НЕ вложенным JSON. GET-ответ отдаёт корневые комментарии и ответы ДВУМЯ
/// РАЗНЫМИ массивами — "root" и "replies" (см. CommentsListResponse,
/// подтверждено перехватом из devtools сайта) — дерево строится на клиенте
/// из их объединения, см. Array<Comment>.groupedByParent().
struct Comment: Decodable, Identifiable, Hashable {
    let id: Int
    let rootId: Int?
    let parentComment: Int?
    let commentLevel: Int
    /// Сырой HTML с сервера (напр. "<p>текст</p>") — см. text ниже.
    let commentHTML: String
    /// Миллисекунды с эпохи — подтверждено (13-значное число: 1785142817000).
    let createdAtTS: Double?
    let author: Author?
    /// Счётчики голосов и голос текущего юзера — ИЗМЕНЯЕМЫЕ: после голосования
    /// (см. MangaDetailViewModel.voteComment) обновляем прямо в модели, без
    /// перезагрузки списка. userVote: 1 — плюс, 0 — минус, nil — не голосовал.
    var votesUp: Int
    var votesDown: Int
    var userVote: Int?

    struct Author: Decodable, Hashable {
        let id: Int
        let username: String
        let avatarURL: String?

        private enum CodingKeys: String, CodingKey { case id, username, avatar }
        private enum AvatarKeys: String, CodingKey { case url }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(Int.self, forKey: .id)) ?? 0
            username = (try? c.decode(String.self, forKey: .username)) ?? "Аноним"
            if let avatarC = try? c.nestedContainer(keyedBy: AvatarKeys.self, forKey: .avatar) {
                avatarURL = try? avatarC.decodeIfPresent(String.self, forKey: .url)
            } else {
                avatarURL = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, user, votes
        case rootId = "root_id"
        case parentComment = "parent_comment"
        case commentLevel = "comment_level"
        case commentHTML = "comment"
        case createdAtTS = "created_at_ts"
    }
    private enum VotesKeys: String, CodingKey { case up, down, user }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        rootId = try? c.decodeIfPresent(Int.self, forKey: .rootId) ?? nil
        parentComment = try? c.decodeIfPresent(Int.self, forKey: .parentComment) ?? nil
        commentLevel = (try? c.decodeIfPresent(Int.self, forKey: .commentLevel)) ?? 0
        commentHTML = (try? c.decodeIfPresent(String.self, forKey: .commentHTML)) ?? ""
        createdAtTS = try? c.decodeIfPresent(Double.self, forKey: .createdAtTS) ?? nil
        author = try? c.decodeIfPresent(Author.self, forKey: .user) ?? nil
        if let votesC = try? c.nestedContainer(keyedBy: VotesKeys.self, forKey: .votes) {
            votesUp = (try? votesC.decodeIfPresent(Int.self, forKey: .up)) ?? 0
            votesDown = (try? votesC.decodeIfPresent(Int.self, forKey: .down)) ?? 0
            userVote = (try? votesC.decodeIfPresent(Int.self, forKey: .user)) ?? nil
        } else {
            votesUp = 0
            votesDown = 0
            userVote = nil
        }
    }

    /// Плюсики минус минусики — цвет в UI зависит от знака (см.
    /// MangaDetailView.commentScoreColor): >0 зелёный, <0 красный, 0 нейтральный.
    var score: Int { votesUp - votesDown }

    var date: Date? {
        guard let createdAtTS else { return nil }
        return Date(timeIntervalSince1970: createdAtTS / 1000)
    }

    /// HTML → читаемый плоский текст: сервер оборачивает комментарий в
    /// <p>...</p> (возможно, с <br> внутри для переносов) — простой безопасный
    /// стрип тегов, без NSAttributedString (полноценный rich-text не нужен).
    /// Спойлеры (см. segments) тут тоже разворачиваются в открытый текст —
    /// это поле только для мест, где сегменты не нужны (превью/ссылка и т.п.).
    var text: String {
        Self.htmlToPlainText(commentHTML)
    }

    /// Комментарий, разбитый на обычный текст и спойлеры — ПОДТВЕРЖДЕНО
    /// реальным перехватом (см. MangaNetworkService.ProseMirrorInline):
    /// `<span class="spoiler-node" data-spoiler-type="inline"
    /// data-spoiler-text="<подпись>"><span class="spoiler-node__text">
    /// <скрытый текст></span></span>`. Порядок сегментов сохраняется — так
    /// собирается ряд Text/спойлер-чипов в UI (см. MangaDetailView.
    /// CommentBodyView).
    var segments: [CommentSegment] {
        let html = commentHTML
        guard let regex = Self.spoilerRegex, !html.isEmpty else {
            let plain = Self.htmlToPlainText(html)
            return plain.isEmpty ? [] : [.text(plain)]
        }
        let ns = html as NSString
        var result: [CommentSegment] = []
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let plain = Self.htmlToPlainText(before)
                if !plain.isEmpty { result.append(.text(plain)) }
            }
            let label = Self.htmlToPlainText(ns.substring(with: match.range(at: 1)))
            let content = Self.htmlToPlainText(ns.substring(with: match.range(at: 2)))
            result.append(.spoiler(label: label, text: content))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let after = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            let plain = Self.htmlToPlainText(after)
            if !plain.isEmpty { result.append(.text(plain)) }
        }
        return result
    }

    private static let spoilerRegex = try? NSRegularExpression(
        pattern: #"<span class="spoiler-node"[^>]*data-spoiler-text="([^"]*)"[^>]*><span class="spoiler-node__text">([\s\S]*?)</span></span>"#
    )

    private static func htmlToPlainText(_ html: String) -> String {
        var s = html
        for (tag, replacement) in [("</p><p>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("<br>", "\n")] {
            s = s.replacingOccurrences(of: tag, with: replacement)
        }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Один сегмент разобранного комментария — см. Comment.segments.
enum CommentSegment: Hashable {
    case text(String)
    case spoiler(label: String, text: String)
}

extension Array where Element == Comment {
    /// Группирует плоский список по id родителя (0 — корневые, без родителя)
    /// — нужно для построения дерева ответов на клиенте (сервер отдаёт всё
    /// одним плоским списком, см. Comment). Внутри каждой группы — по
    /// возрастанию даты создания (старые сначала внутри одного треда, как в
    /// подтверждённом примере).
    ///
    /// НАЙДЕНО реальным перехватом (проверка пользователя): GET /comments с
    /// sort_by=id&sort_type=desc отдаёт страницу как плоский список БЕЗ
    /// гарантии, что родитель ответа попал на ту же страницу — например,
    /// пришёл comment_level:1 с parent_comment:303252695, а самого
    /// комментария 303252695 в этой же странице могло не быть (он старше и
    /// уехал на следующую страницу). Раньше группировка строго по
    /// c.parentComment ?? 0 такие "осиротевшие" ответы клала в bucket
    /// (несуществующего локально) родителя — они физически лежали в massив
    /// comments, но узел дерева для них никогда не строился (grouped[0]
    /// оставался пустым, если на странице вообще не было ни одного
    /// НАСТОЯЩЕГО корневого комментария) — отсюда баг "комментарии есть в
    /// ответе сервера, а в интерфейсе пусто". Фикс: родителем считается
    /// parentComment, ТОЛЬКО ЕСЛИ он реально присутствует среди уже
    /// загруженных комментариев — иначе комментарий считается "псевдокорнем"
    /// (bucket 0) и всё равно показывается, а не пропадает молча.
    func groupedByParent() -> [Int: [Comment]] {
        let loadedIDs = Set(map { $0.id })
        var map: [Int: [Comment]] = [:]
        for c in self {
            let effectiveParent: Int
            if let parent = c.parentComment, loadedIDs.contains(parent) {
                effectiveParent = parent
            } else {
                effectiveParent = 0
            }
            map[effectiveParent, default: []].append(c)
        }
        // Только ВЛОЖЕННЫЕ ответы (bucket != 0) сортируем по возрастанию даты —
        // так тред читается как обычная переписка сверху вниз, от старого
        // ответа к новому. КОРНЕВЫЕ комментарии (bucket 0) НЕ трогаем —
        // оставляем в ТОМ ЖЕ порядке, в котором они пришли в исходном
        // массиве, то есть в порядке, который уже выставил СЕРВЕР по
        // sort_type (Новые/Старые, см. MangaDetailViewModel.sortTypeParam);
        // "Популярные" пересортировывает поверх этого сам View (см.
        // MangaDetailView.commentsList).
        //
        // РЕАЛЬНЫЙ БАГ (нашёл пользователь: "внизу списка комментарии
        // новее, чем вверху"): раньше строгая ascending-сортировка
        // применялась ко ВСЕМ бакетам без исключения, включая корневой —
        // сервер честно присылал корневые комментарии по убыванию даты
        // (выбрана сортировка "Новые"), а этот код тут же переворачивал их
        // обратно на возрастание, из-за чего в интерфейсе сверху оказывались
        // САМЫЕ СТАРЫЕ корневые комментарии, а новые — только при прокрутке
        // вниз.
        for key in map.keys where key != 0 {
            map[key]?.sort { ($0.createdAtTS ?? 0) < ($1.createdAtTS ?? 0) }
        }
        return map
    }
}

/// Обёртка ответа GET /comments — РЕАЛЬНАЯ форма (перехвачена пользователем
/// через devtools сайта, а не через приложение — видна структура целиком, без
/// обрезки, в отличие от самого первого перехвата "comments.txt"):
/// `{"data":{"replies":[...], "root":[...]}, "meta":{"has_next_page":bool,
/// "page":Int,"per_page":Int}}`.
///
/// ЭТО ОПРОВЕРГАЕТ мою прежнюю, неподтверждённую гипотезу: "replies" — это
/// НЕ единый плоский список ВСЕХ комментариев (корневых и вложенных вместе),
/// а массив ТОЛЬКО вложенных ответов (comment_level >= 1); корневые
/// комментарии (comment_level: 0) лежат ОТДЕЛЬНО, в массиве "root". Раньше
/// код читал только "replies" — то есть настоящие корневые комментарии
/// ВООБЩЕ никогда не попадали в приложение, а на экране показывались только
/// "осиротевшие" вложенные ответы, притворяющиеся корнями (см.
/// Array.groupedByParent) — отсюда и баг "сортировка ничего не меняет":
/// смена sort_type меняла порядок на сервере, но клиент эти данные попросту
/// не получал, т.к. смотрел не в тот массив.
///
/// Заодно теперь используем НАСТОЯЩИЙ meta.has_next_page вместо прежней
/// эвристики "непустой список = наверное есть страница дальше" (см.
/// MangaNetworkService.fetchComments).
///
/// ВАЖНО: в отличие от большинства других decode-обёрток в этом файле, здесь
/// СТРУКТУРНЫЕ ошибки (нет ключа "data"/"replies"/"root", другая форма) НЕ
/// проглатываются через try? — пусть бросают настоящую ошибку, которая дойдёт
/// до commentsErrorState на экране, а не тихо превратятся в "0 комментариев".
/// LossyArray по-прежнему используется ВНУТРИ каждого массива — один "битый"
/// ОТДЕЛЬНЫЙ комментарий не должен ронять чтение всего списка, это другой случай.
struct CommentsListResponse: Decodable {
    /// Объединённые root + replies — дальше дерево строится одинаково для
    /// обоих через Array.groupedByParent (root уже имеет parentComment==nil,
    /// так что естественно попадает в bucket 0, без всякого спец-кода).
    let comments: [Comment]
    let hasNextPage: Bool

    private enum DataKeys: String, CodingKey { case data, meta }
    private enum RepliesKeys: String, CodingKey { case replies, root }
    private enum MetaKeys: String, CodingKey { case hasNextPage = "has_next_page" }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: DataKeys.self)
        let inner = try outer.nestedContainer(keyedBy: RepliesKeys.self, forKey: .data)
        let replies = try inner.decode(LossyArray<Comment>.self, forKey: .replies).elements
        let root = try inner.decode(LossyArray<Comment>.self, forKey: .root).elements
        comments = root + replies

        if let meta = try? outer.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta),
           let confirmed = try? meta.decode(Bool.self, forKey: .hasNextPage) {
            hasNextPage = confirmed
        } else {
            // Запасной вариант, если meta вдруг не пришла (не должно
            // случаться — подтверждено реальным перехватом) — как и раньше,
            // эвристика "непустой список = вероятно есть ещё".
            hasNextPage = !comments.isEmpty
        }
    }
}

/// Результат fetchPages — страницы + признак "уже просмотрена" (см.
/// ChapterPagesData.isViewed), используется для пропуска повторного
/// markChapterViewed при перечитывании уже отмеченной главы.
struct ChapterPagesResult {
    let pages: [PageItem]
    let isViewed: Bool
    /// Команда(ы)/лайк/оценка перевода ИМЕННО этой главы — см.
    /// ChapterPagesData. nil у офлайн (скачанных) глав — там своего ответа
    /// сервера нет (см. ReaderViewModel.load/fetchSegment, ветка localFiles).
    let teams: [ChapterTeam]
    let likesCount: Int?
    let isLiked: Bool?
    let translationRating: TranslationRating?
}

/// Одна страница главы. `url` — относительный путь, дополняется базовым URL сервера картинок.
struct PageItem: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: Int?
    let image: String?
    let url: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, slug, image, url, width, height
    }

    /// Относительный путь к изображению страницы.
    var relativePath: String? { url ?? image }

    static func == (lhs: PageItem, rhs: PageItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Уведомления (GET /notifications, GET /notifications/count)

/// Общий разбор дат вида "2026-07-26T13:19:36.000000Z" (ISO8601 с
/// микросекундами) — та же пара форматтеров, что уже используется в
/// HistoryEntry.parseDate, вынесена сюда, чтобы не дублировать её ещё раз
/// для NotificationItem.createdAt (см. ниже).
enum APIISODate {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        isoFormatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
    }
}

/// `read_type` для GET /notifications. "unread"/"all" — ПОДТВЕРЖДЕНО реальными
/// перехватами (оба значения реально встречались в URL перехваченных
/// запросов сайта). "read" добавлен по симметрии с ними же (сервер сам
/// использует пару unread/all, "read" — третий, ещё не перехваченный, но
/// логичный вариант того же параметра) — если сервер его не примет, будет
/// видно в NetworkLogsView.
enum NotificationReadFilter: String, CaseIterable, Identifiable {
    case unread, read, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unread: return "Непрочитанные"
        case .read: return "Прочитанные"
        case .all: return "Все"
        }
    }
}

/// `notification_type` для GET /notifications — "all" и "chapter"
/// ПОДТВЕРЖДЕНЫ перехватом прямо в URL (proxypin, 2026-08-26). Остальные
/// значения — та же таксономия категорий, что уже подтверждена на
/// /notifications/count (см. NotificationCategoryCounts: chapter_player/
/// episode/comments/message/card/other) — по аналогии по тому же ресурсу,
/// не перехвачены отдельно как значения ИМЕННО этого параметра.
enum NotificationTypeFilter: String, CaseIterable, Identifiable {
    case all, chapter, chapter_player, episode, comments, message, card, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .chapter: return "Главы"
        case .chapter_player: return "Плеер"
        case .episode: return "Эпизоды"
        case .comments: return "Ответы"
        case .message: return "Личка"
        case .card: return "Карточки"
        case .other: return "Другое"
        }
    }
}

/// `sort_type` для GET /notifications — ПОДТВЕРЖДЕНО перехватом (значение
/// "desc" реально встречалось в URL; "asc" — по той же паре, что и у
/// /comments sort_type, см. MangaNetworkService.fetchComments).
enum NotificationSortOrder: String, CaseIterable, Identifiable {
    case desc, asc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desc: return "Сначала новые"
        case .asc: return "Сначала старые"
        }
    }
}

/// Автор события уведомления — форма ПОДТВЕРЖДЕНА реальным перехватом:
/// `"user":{"id","username","avatar":{"filename","url"}}` внутри
/// NotificationItem.data.
struct NotificationUser: Decodable, Hashable {
    let id: Int
    let username: String
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey { case id, username, avatar }
    private enum AvatarKeys: String, CodingKey { case url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? nil ?? ""
        if let avatarC = try? c.nestedContainer(keyedBy: AvatarKeys.self, forKey: .avatar) {
            let urlString = (try? avatarC.decodeIfPresent(String.self, forKey: .url)) ?? nil
            avatarURL = urlString.flatMap(URL.init(string:))
        } else {
            avatarURL = nil
        }
    }
}

/// Глава внутри уведомления — СВОЯ форма, отличная от ChapterItem/
/// HistoryChapterRef: та же пара volume/number-строк, но с человекочитаемым
/// "name" главы и без branches — ПОДТВЕРЖДЕНО реальным перехватом
/// (`"chapter":{"id","model","volume","number","name","branch_id","manga_id",
/// "expired_at"}`).
struct NotificationChapter: Decodable, Hashable {
    let id: Int?
    let volume: String?
    let number: String?
    let name: String?
}

/// Команда перевода — ПОДТВЕРЖДЕНО реальным перехватом: `"teams":[{"id",
/// "slug","slug_url","model":"team","name","cover":{...},"vk","discord"}]`
/// внутри NotificationItem.data. Массив, а не одиночный объект — у главы
/// может быть НЕСКОЛЬКО команд перевода сразу (подтверждено: во втором
/// перехваченном примере у одной главы две команды — "ImageBoard Team" и
/// "ONIMAI.RU"). Нужны только id/name — остальные поля (cover/vk/discord)
/// пока нигде не отображаются, не декодируем лишнее.
struct NotificationTeam: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String

    private enum CodingKeys: String, CodingKey { case id, name }
}

/// Содержимое уведомления — ProseMirror/TipTap доc, но ОТДЕЛЬНЫЙ парсер от
/// SummaryDoc/SummaryNode (см. выше): реальная форма здесь ПЛОСКАЯ —
/// "content" сразу перечисляет узлы text/hardBreak ОДНИМ уровнем, БЕЗ
/// обёртки в paragraph, как у MangaDetail.summary — подтверждено ВСЕМИ
/// тремя перехваченными файлами уведомлений одинаково. hardBreak → перевод
/// строки; marks (bold/underline на отдельных text-узлах) пока не
/// используются для форматирования — извлекаем только читаемый текст, чтобы
/// не гадать про точный AttributedString рендеринг.
struct NotificationContentDoc: Decodable {
    let content: [NotificationContentNode]?

    var plainText: String {
        (content ?? []).map(\.rendered).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NotificationContentNode: Decodable {
    let type: String?
    let text: String?

    var rendered: String {
        if type == "hardBreak" { return "\n" }
        return text ?? ""
    }
}

/// Один элемент ленты уведомлений — ПОДТВЕРЖДЕНО реальным перехватом (три
/// разных devtools-файла от пользователя, все примеры — category:"chapter"):
/// `{"id","type","category","data":{"user","chapter","media","teams",
/// "is_new"},"yaoi","content":{ProseMirror-доc},"created_at"}`.
///
/// ВАЖНО: статус "прочитано/не прочитано" У САМОГО ЭЛЕМЕНТА НЕ приходит —
/// ни в одном из трёх перехватов нет поля вроде is_read/read_at, форма ответа
/// ОДИНАКОВАЯ при read_type=unread и read_type=all. Значит фильтрация по
/// прочитанности — ПОЛНОСТЬЮ серверная, через read_type в запросе (см.
/// NotificationReadFilter/MangaNetworkService.fetchNotifications) — отдельного
/// булева поля на клиенте нет и быть не может, поэтому у самого элемента
/// нет и не может быть кнопки "отметить прочитанным": такой эндпоинт ни разу
/// не засветился ни в одном перехвате, гадать про него не стали.
///
/// "media"/"chapter" — Optional: категории, отличные от "chapter" (comments/
/// message/card/other — видны только в /notifications/count, но НИ РАЗУ не
/// перехвачены как реальные элементы списка), скорее всего, имеют другую
/// вложенную форму "data" — чтобы один такой "иной" элемент не ронял всю
/// LossyArray-загрузку списка, все поля здесь читаются best-effort (try?).
struct NotificationItem: Decodable, Identifiable, Hashable {
    let id: Int
    let type: String
    let category: String
    let user: NotificationUser?
    let media: MangaItem?
    let chapter: NotificationChapter?
    let teams: [NotificationTeam]
    let isNew: Bool?
    let content: NotificationContentDoc?
    let createdAt: Date

    /// Команды перевода через запятую — "Армия 100 богинь" / "ImageBoard
    /// Team, ONIMAI.RU" и т.п. (см. NotificationTeam). Пусто, если команд нет
    /// совсем (у категорий, отличных от "chapter", teams не подтверждён —
    /// декодируется best-effort и тогда останется пустым массивом).
    var teamNames: String { teams.map(\.name).joined(separator: ", ") }

    /// Текст для строки списка — из ProseMirror content, если распарсился;
    /// иначе best-effort заглушка по номеру/названию главы, чтобы строка не
    /// оставалась пустой.
    var displayText: String {
        if let text = content?.plainText, !text.isEmpty { return text }
        if let chapter {
            let number = [chapter.volume.map { "Том \($0)" }, chapter.number.map { "Глава \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
            return [number, chapter.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        }
        return "Новое уведомление"
    }

    static func == (lhs: NotificationItem, rhs: NotificationItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private enum CodingKeys: String, CodingKey {
        case id, type, category, data, content
        case createdAt = "created_at"
    }
    private enum DataKeys: String, CodingKey {
        case user, media, chapter, teams
        case isNew = "is_new"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil ?? "other"
        category = ((try? c.decodeIfPresent(String.self, forKey: .category)) ?? nil) ?? type
        content = (try? c.decodeIfPresent(NotificationContentDoc.self, forKey: .content)) ?? nil

        if let dataC = try? c.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            user = (try? dataC.decodeIfPresent(NotificationUser.self, forKey: .user)) ?? nil
            media = (try? dataC.decodeIfPresent(MangaItem.self, forKey: .media)) ?? nil
            chapter = (try? dataC.decodeIfPresent(NotificationChapter.self, forKey: .chapter)) ?? nil
            teams = (((try? dataC.decodeIfPresent(LossyArray<NotificationTeam>.self, forKey: .teams)) ?? nil)?.elements) ?? []
            isNew = (try? dataC.decodeIfPresent(Bool.self, forKey: .isNew)) ?? nil
        } else {
            user = nil; media = nil; chapter = nil; teams = []; isNew = nil
        }

        let rawDate = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) ?? ""
        createdAt = APIISODate.parse(rawDate) ?? Date()
    }
}

/// `GET /notifications/count` — ПОДТВЕРЖДЕНО реальным перехватом (три файла,
/// один запрос без query-параметров): счётчики по категориям (all/chapter/
/// chapter_player/episode/comments/message/card/other), отдельными блоками
/// для unread/read/all.
struct NotificationCounts: Decodable {
    let unread: NotificationCategoryCounts
    let read: NotificationCategoryCounts
    let all: NotificationCategoryCounts
}

struct NotificationCategoryCounts: Decodable {
    let all: Int
    let chapter: Int
    let chapterPlayer: Int
    let episode: Int
    let comments: Int
    let message: Int
    let card: Int
    let other: Int

    enum CodingKeys: String, CodingKey {
        case all, chapter, episode, comments, message, card, other
        case chapterPlayer = "chapter_player"
    }
}

// MARK: - Главная / вкладка «Читают» (см. HomeView/HomeViewModel)

/// «Сейчас читают» — подвкладка виджета на главной. ПОДТВЕРЖДЁН только сам
/// путь эндпоинта (см. MangaNetworkService.fetchTopViews); за какие именно
/// query-параметры отвечают три вкладки скриншота (Новинки/Набирающее
/// популярность/Популярное) — НЕ подтверждено перехватом (таблица параметров
/// в присланном дампе дошла обрывочно). Значения ниже — лучшая догадка по
/// аналогии с sort_by каталога (см. SortOption.apiSortBy); сервер молча
/// игнорирует незнакомые параметры (проверено на других эндпоинтах этого же
/// API — см. genres_and/tags_and в fetchCatalog), так что худший случай
/// неверной догадки — вкладка визуально не меняет список, а не ломает его.
enum TopViewsSort: String, CaseIterable, Identifiable {
    case newest, rising, popular
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest:  return "Новинки"
        case .rising:  return "Набирающее популярность"
        case .popular: return "Популярное"
        }
    }

    /// Ключ группы в `TopViewsPayload.items` ("1"/"2"/"3") — сама нумерация
    /// ПОДТВЕРЖДЕНА реальным 200-ответом (два дампа, time=week и
    /// time=month), но КАКОЙ ключ значит какую вкладку сервер нигде не
    /// подписывает. Судя по составу — "3" стабильно содержит устоявшуюся
    /// классику с максимальным числом просмотров (One Piece, Grand Blue) →
    /// похоже на "Популярное"; "1" — недавно добавленные тайтлы → похоже на
    /// "Новинки"; "2" — то, что осталось, → "Набирающее популярность". Тот
    /// же порядок, что на исходном скриншоте вкладок.
    var groupKey: String {
        switch self {
        case .newest:  return "1"
        case .rising:  return "2"
        case .popular: return "3"
        }
    }
}

/// Ответ `GET /media/top-views?time=` — ПОДТВЕРЖДЕНО реальным перехватом
/// (пользователь прислал два полных тела ответа, time=week и time=month,
/// оба 200): один запрос сразу возвращает все три категории, сгруппированные
/// под items."1"/"2"/"3" (см. TopViewsSort.groupKey) — НЕ плоский список с
/// пагинацией, как предполагалось раньше по обрывочному перехвату из первого
/// файла (там же "page"/"popularity" тоже, судя по всему, относились к
/// другому/устаревшему поведению этого эндпоинта). `page`/`sort_by` в
/// подтверждённых 200-ответах не участвуют вообще.
struct TopViewsPayload: Decodable {
    let timeFilter: String?
    let items: [String: [TopViewEntry]]?

    enum CodingKeys: String, CodingKey {
        case timeFilter = "time_filter"
        case items
    }
}

struct TopViewEntry: Decodable {
    let views: Int
    let media: MangaItem
}

/// Период для "Сейчас читают". Значение "day" и имя параметра "time" (см.
/// MangaNetworkService.fetchTopViews) — ПОДТВЕРЖДЕНЫ реальным 422-ответом
/// сервера при запросе без него; "week"/"month" — по аналогии с подписями на
/// скриншоте (За день/За неделю/За месяц), сами эти два значения не
/// перехвачены ни разу.
enum TopViewsPeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:   return "За день"
        case .week:  return "За неделю"
        case .month: return "За месяц"
        }
    }
}

/// Подборка ("коллекция") — ПОДТВЕРЖДЕНО реальным перехватом (агрегат
/// главной страницы, а также отдельным `GET /collections?limit=&page=&
/// sort_by=newest` — proxypin, 2026-08-26, без user_id — общая лента
/// коллекций сайта). `previews` — до трёх обложек тайтлов внутри подборки,
/// та же форма, что MangaCover.
/// Не Hashable: MangaCover (см. previews ниже) сам не Hashable, а нигде в
/// HomeView коллекции не кладутся в Set/используются как значение таба —
/// хватает Identifiable для ForEach.
struct MangaCollection: Decodable, Identifiable {
    let id: Int
    let name: String
    let views: Int?
    let favoritesCount: Int?
    let itemsCount: Int?
    /// Комментариев к коллекции — ПОДТВЕРЖДЕНО перехватом (comments_count).
    let commentsCount: Int?
    /// 18+-пометка коллекции — ПОДТВЕРЖДЕНО перехватом (adult).
    let adult: Bool?
    let votes: MangaCollectionVotes?
    let previews: [MangaCover]?

    enum CodingKeys: String, CodingKey {
        case id, name, views, previews, votes, adult
        case favoritesCount = "favorites_count"
        case itemsCount = "items_count"
        case commentsCount = "comments_count"
    }
}

struct MangaCollectionVotes: Decodable, Hashable {
    let up: Int
    let down: Int
}

// MARK: - Отзывы на тайтл (GET /reviews?reviewable_type=manga&reviewable_id=)

/// Отзыв на тайтл — ПОДТВЕРЖДЕНО реальным перехватом (proxypin, 2026-08-26):
/// `{id,model,title,content:{ProseMirror doc},views,comments_count,user,
/// rating:[{label,value}],status,type,evaluation,votes:{up,down,user},
/// metadata,site_id,created_at,updated_at}`. `content` — та же форма
/// rich-текста, что и у описания тайтла (см. SummaryDoc).
struct MangaReview: Decodable, Identifiable {
    let id: Int
    let title: String
    let contentText: String
    let views: Int
    let commentsCount: Int
    let user: FriendUser
    let rating: [ReviewRatingEntry]
    let votes: SimilarVotes?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, content, views, user, rating, votes
        case commentsCount = "comments_count"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        let doc = (try? c.decodeIfPresent(SummaryDoc.self, forKey: .content)) ?? nil
        contentText = doc?.plainText ?? ""
        views = ((try? c.decodeIfPresent(Int.self, forKey: .views)) ?? nil) ?? 0
        commentsCount = ((try? c.decodeIfPresent(Int.self, forKey: .commentsCount)) ?? nil) ?? 0
        user = (try? c.decode(FriendUser.self, forKey: .user)) ?? FriendUser(id: 0, username: "", avatarURL: nil)
        rating = ((try? c.decodeIfPresent([ReviewRatingEntry].self, forKey: .rating)) ?? nil) ?? []
        votes = (try? c.decodeIfPresent(SimilarVotes.self, forKey: .votes)) ?? nil
        if let raw = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil), !raw.isEmpty {
            createdAt = APIISODate.parse(raw)
        } else {
            createdAt = nil
        }
    }
}

struct ReviewRatingEntry: Decodable, Identifiable, Hashable {
    let label: String
    let value: Int
    var id: String { label }
}

/// Участник «Топ активных недели» — ПОДТВЕРЖДЕНО реальным перехватом (тот же
/// агрегат главной, что и MangaCollection выше — см. ту же оговорку про
/// неподтверждённый отдельный путь).
struct TopActiveUser: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    let avatarURL: URL?
    let pointsInfo: TopActiveUserPoints?

    private enum CodingKeys: String, CodingKey {
        case id, username, avatar, pointsInfo = "points_info"
    }
    private enum AvatarKeys: String, CodingKey { case url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        username = ((try? c.decodeIfPresent(String.self, forKey: .username)) ?? nil) ?? ""
        pointsInfo = (try? c.decodeIfPresent(TopActiveUserPoints.self, forKey: .pointsInfo)) ?? nil
        if let avatarC = try? c.nestedContainer(keyedBy: AvatarKeys.self, forKey: .avatar) {
            let urlString = (try? avatarC.decodeIfPresent(String.self, forKey: .url)) ?? nil
            avatarURL = urlString.flatMap(URL.init(string:))
        } else {
            avatarURL = nil
        }
    }
}

struct TopActiveUserPoints: Decodable, Hashable {
    let level: Int
    let maxLevelPoints: Int
    let currentLevelPoints: Int

    enum CodingKeys: String, CodingKey {
        case level
        case maxLevelPoints = "max_level_points"
        case currentLevelPoints = "current_level_points"
    }
}

/// Полезная нагрузка агрегата главной страницы — из ВСЕГО перехваченного
/// дампа (popular/collections/reviews/newest/latest_updates/currently_views/
/// weekly_top_users/weekly_top_views_users/news/forum/slider) сюда взяты
/// collections, weeklyTopUsers И popular (см. HomeView.popularSection —
/// раздел "Обновление популярных тайтлов", ключ был в дампе с самого
/// начала, просто раньше нигде не декодировался): остальное либо уже
/// покрыто другими, подтверждёнными эндпоинтами (newest/latest_updates —
/// см. fetchCatalog(sort:.added/.updated)), либо не нужно для экрана
/// «Читают» (reviews/news/forum/slider). JSONDecoder тихо игнорирует
/// лишние ключи верхнего уровня, которых нет в CodingKeys — остальные
/// секции агрегата не мешают декодированию. `popular` — те же элементы
/// формы MangaItem, что и `newest` (metadata.last_item, см. MangaItemMetadata) —
/// "Глава X" на карточке означает ровно то же самое, что и в «Новинках»:
/// номер последней главы тайтла, а не какой-то отдельный "ранг популярности".
///
/// ВАЖНО: путь самого этого эндпоинта НЕ ПОДТВЕРЖДЁН — см.
/// MangaNetworkService.fetchHomeWidgets.
struct HomeWidgetsPayload: Decodable {
    let collections: [MangaCollection]?
    let weeklyTopUsers: [TopActiveUser]?
    let popular: [MangaItem]?

    enum CodingKeys: String, CodingKey {
        case collections
        case weeklyTopUsers = "weekly_top_users"
        case popular
    }
}
