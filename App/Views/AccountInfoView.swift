import SwiftUI
import UIKit

/// Обёртка над id пользователя для `.sheet(item:)` (открытие чужого профиля).
struct ProfileUserId: Identifiable { let id: Int }

/// Профиль пользователя (свой или чужого — по `userId`): баннер, аватар-обложка
/// слева-сверху, статистика справа (создано тайтлов / загружено глав / кол-во
/// комментариев). Ниже — отдельными подложками статистика по жанрам и по тегам
/// (горизонтальные цветные чипы, зависят от активного сайта через Site-Id) и
/// быстрые кнопки. Данные: GET /user/{id} и /user/{id}/stats.
struct ProfileView: View {
    /// nil — свой профиль (id берётся из AuthSession).
    let userId: Int?

    @ObservedObject private var auth = AuthSession.shared
    @ObservedObject private var site = SiteSession.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var profile: UserProfile?
    @State private var stats: UserStats?
    @State private var loadingProfile = false
    /// Светлый ли верх баннера — если да, надписи «Профиль»/«Готово» делаем
    /// чёрными (и не затемняем верх), чтобы читались на светлом фоне.
    @State private var bannerTopLight = false

    /// Статус дружбы с ЧУЖИМ профилем (nil на своём — кнопка не показывается).
    @State private var friendship: FriendshipEntry?
    @State private var sendingFriendRequest = false
    @State private var friendRequestMessage: String?
    @State private var showAdditionalInfo = false
    /// Повторный тап по "Заявка отправлена" — запрашивает подтверждение
    /// отмены (см. friendshipRow/cancelFriendRequest).
    @State private var showCancelFriendRequestConfirm = false
    @State private var cancellingFriendRequest = false
    /// Принять/отклонить входящую заявку (см. friendshipRow, ветка
    /// isAwaitingConfirmation) — коды status для PUT /friendship/{id}
    /// теперь ПОДТВЕРЖДЕНЫ (см. MangaNetworkService.respondToFriendRequest).
    @State private var respondingToFriendRequest = false
    /// Какой из "быстрых" разделов сейчас открыт ВНУТРИ профиля, вместо
    /// push'а через NavigationLink на отдельный экран — по прямой просьбе
    /// сделать так, чтобы левая кнопка шапки (щит ↔ назад) плавно перетекала
    /// одна в другую (см. topBar), а не просто появлялась/исчезала отдельно:
    /// два разных экрана, соединённых через push NavigationStack, всегда
    /// ДВЕ РАЗНЫЕ View (проверено — см. предыдущую попытку с .glassEffectID
    /// через push, эффекта не было вообще), а перетечь друг в друга может
    /// только ОДНА и та же View. Поэтому раздел теперь просто подменяет
    /// контент под ОБЩЕЙ, постоянной шапкой (topBar) вместо пуша.
    @State private var subScreen: ProfileSubScreen?
    /// Разделы, которые хоть раз открывали за время жизни этого экрана —
    /// однажды смонтированный раздел остаётся в дереве насовсем (просто
    /// уезжает за кадр, см. subScreenLayer), поэтому его @StateObject и уже
    /// загруженные данные не создаются и не грузятся заново при повторном
    /// открытии (по прямой просьбе — "постоянно подгружает вкладки, вместо
    /// того чтобы это сделать 1 раз").
    @State private var openedScreens: Set<ProfileSubScreen> = []

    enum ProfileSubScreen: Hashable {
        case bookmarks, comments, collections, friends

        var title: String {
            switch self {
            case .bookmarks:   return "Списки тайтлов"
            case .comments:    return "Комментарии"
            case .collections: return "Коллекции"
            case .friends:     return "Друзья"
            }
        }
    }

    init(userId: Int? = nil) { self.userId = userId }

    private var resolvedId: Int? { userId ?? auth.userId }
    private var isSelf: Bool { let r = resolvedId; return r != nil && r == auth.userId }
    /// Ключ для перезагрузки статистики при смене профиля ИЛИ активного сайта.
    private var statsKey: String { "\(resolvedId ?? 0)-\(site.activeSite.rawValue)" }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()

                if let profile, !profile.canViewProfile {
                    closedState
                } else {
                    // Корневой профиль и каждый открывавшийся хоть раз раздел —
                    // ОДНОВРЕМЕННО в дереве (см. openedScreens/subScreenLayer),
                    // просто со смещением/прозрачностью не-активного. Раньше
                    // раздел был отдельной веткой if/else и полностью
                    // уничтожался при закрытии — @StateObject внутри (вместе со
                    // всеми загруженными данными) создавался заново при каждом
                    // повторном открытии, отсюда жалоба "постоянно подгружает
                    // вместо того чтобы сделать 1 раз". Теперь однажды открытый
                    // раздел остаётся смонтированным и просто уезжает за кадр —
                    // данные грузятся только один раз за всё время жизни экрана.
                    ZStack {
                        profileRootContent
                            .opacity(subScreen == nil ? 1 : 0)
                            .offset(x: subScreen == nil ? 0 : -Self.slideDistance)
                            .allowsHitTesting(subScreen == nil)

                        subScreenLayer(.bookmarks)
                        subScreenLayer(.comments)
                        subScreenLayer(.collections)
                        subScreenLayer(.friends)
                    }
                }

                // topBar — ОТДЕЛЬНЫМ слоем поверх (не часть прокручиваемого
                // heroBanner, как раньше), т.к. должен оставаться ОДНОЙ и той
                // же View независимо от того, что сейчас показано под ним —
                // корневой профиль или один из разделов (см. subScreen).
                topBar
            }
            .ignoresSafeArea(edges: .top)
            // РЕАЛЬНЫЙ (просто прозрачный) navigation bar — не .toolbar(.hidden...),
            // как было. Причина та же, что и у аналогичного фикса в
            // MangaDetailView/TeamView/CharacterView/DirectoryDetailView:
            // когда КОРЕНЬ NavigationStack полностью прячет бар, а ПУШНУТЫЙ
            // экран (например, MangaDetailView из «Списки тайтлов», TeamView
            // из избранных команд) показывает свой настоящий бар с toolbar-
            // кнопками, — эти кнопки визуально задваивались/наезжали друг на
            // друга (жаловались: "две кнопки друг на друга налаживаются").
            // topBar здесь (шапка профиля со щитом/"Готово") — ОТДЕЛЬНЫЙ
            // ручной слой (см. выше), от системного бара вообще не зависит —
            // с ним ничего не меняется, просто у самого бара больше нет
            // рассинхронизации с тем, что показывают пушнутые экраны.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task(id: resolvedId) { await loadProfile() }
        .task(id: statsKey) { await loadStats() }
        .task(id: profile?.backgroundURL) { await computeBannerBrightness() }
        .task(id: resolvedId) { await loadFriendshipIfNeeded() }
        .sheet(isPresented: $showAdditionalInfo) {
            AdditionalInfoSheet(profile: profile)
                .presentationDetents([.medium, .large])
        }
        // Системный центрированный alert (не шторка снизу) — по прямой просьбе.
        .alert("Отменить заявку?", isPresented: $showCancelFriendRequestConfirm) {
            Button("Да", role: .destructive) { Task { await cancelFriendRequest() } }
            Button("Нет", role: .cancel) {}
        } message: {
            Text("Вы уверены, что хотели отменить заявку?")
        }
    }

    /// Замер средней яркости верхней части баннера → выбор цвета надписей.
    private func computeBannerBrightness() async {
        guard let url = profile?.backgroundURL,
              let img = await RemoteImageLoader.fetchImage(candidates: [url]),
              let b = Self.topBrightness(img) else {
            bannerTopLight = false
            return
        }
        bannerTopLight = b > 0.68
    }

    /// Средняя яркость (luma) верхней трети картинки: рисуем регион в 1×1 и
    /// читаем усреднённый пиксель.
    private static func topBrightness(_ image: UIImage) -> CGFloat? {
        guard let cg = image.cgImage else { return nil }
        let topH = max(1, cg.height / 3)
        guard let cropped = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: topH)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// Затемнение баннера: на светлом верхе почти не затемняем сверху (чтобы
    /// читались чёрные надписи), на тёмном — сильнее (для белых).
    private var bannerGradient: LinearGradient {
        let top = bannerTopLight ? 0.06 : 0.55
        let mid = bannerTopLight ? 0.14 : 0.28
        return LinearGradient(colors: [.black.opacity(top), .black.opacity(mid), .black.opacity(0.62)],
                              startPoint: .top, endPoint: .bottom)
    }

    /// Без баннера-фото за спиной (см. topBar/subScreen) — обычный
    /// Theme.textPrimary, как и на всех остальных экранах приложения.
    private var topTextColor: Color { subScreen != nil ? Theme.textPrimary : (bannerTopLight ? .black : .white) }

    // MARK: Закрытый профиль

    /// .frame(maxWidth/maxHeight: .infinity) — родительский ZStack в body
    /// выровнен по .topLeading (нужно для баннера/шапки в обычном
    /// состоянии), без явного растяжения этот блок прижимался к левому
    /// верхнему углу вместо центра экрана.
    private var closedState: some View {
        StateView(icon: "lock.fill", title: "Профиль закрыт", description: profile?.username, fillScreen: true)
    }

    // MARK: Шапка (постоянная topBar поверх + баннер/аватар/статистика под ней)

    /// Высота topBar (44 кнопка + 14 отступ сверху + 12 снизу) — heroBanner
    /// ниже отступает на эту же величину, чтобы аватар не залезал под неё;
    /// subScreenLayer тоже использует её же для своего верхнего отступа.
    private static let topBarHeight: CGFloat = 70
    /// Смещение "за кадр" для неактивного корня/раздела (см. subScreenLayer)
    /// — заведомо больше ширины любого экрана, чтобы уезжающая сторона была
    /// гарантированно не видна и не кликабельна до конца анимации.
    private static let slideDistance: CGFloat = 500

    /// Постоянный слой поверх всего — заголовок по центру + кнопки по краям.
    /// ОДНА и та же View независимо от того, открыт ли раздел (subScreen).
    ///
    /// - Иконка слева (щит ↔ назад) — настоящий морф SF Symbol через
    ///   `.contentTransition(.symbolEffect(.replace))`: glassEffect-круг стоит
    ///   СТАТИЧНО на самой Button (не пересоздаётся), меняется только
    ///   systemName у Image — тот же приём, что уже работает в читалке (см.
    ///   MangaReaderView.bookmarkButton), а не имитация через смену id.
    /// - Заголовок и "Готово" — у Text/Capsule нет аналога symbolEffect,
    ///   поэтому они по-прежнему на блюр-фейде (см. AnyTransition.blurFade в
    ///   Theme.swift, тот же приём, что у скрытия интерфейса читалки по тапу):
    ///   заголовок пересоздаётся через `.id(subScreen)` (иначе смена текста
    ///   вообще не попадает под .transition), "Готово" просто гасится
    ///   opacity+blur, пока открыт раздел, и так же проявляется обратно.
    private var topBar: some View {
        ZStack {
            Text(subScreen?.title ?? "Профиль")
                .font(.headline)
                .foregroundStyle(topTextColor)
                .shadow(color: (subScreen == nil && !bannerTopLight ? Color.black : Color.clear).opacity(0.4), radius: 2)
                .id(subScreen)
                .transition(.blurFade(radius: 8))

            HStack {
                Button {
                    if subScreen != nil {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { subScreen = nil }
                    } else {
                        showAdditionalInfo = true
                    }
                } label: {
                    Image(systemName: subScreen == nil ? "shield.lefthalf.filled" : "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(topTextColor)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())

                Spacer(minLength: 0)

                Button { dismiss() } label: {
                    Text("Готово")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(topTextColor)
                        .padding(.horizontal, 18).frame(height: 44)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .opacity(subScreen == nil ? 1 : 0)
                .blur(radius: subScreen == nil ? 0 : 8)
                .allowsHitTesting(subScreen == nil)
            }
        }
        .padding(.horizontal, 16)
        // Это sheet — статус-бара над контентом нет, поэтому кнопки прижаты
        // к самому верху (без запаса под статус-бар).
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var heroBanner: some View {
        GeometryReader { geo in
            // Доступная ширина под плашки = экран − боковые поля − аватар − зазор.
            let statsW = statsWidth(available: geo.size.width - 32 - 104 - 12)

            ZStack(alignment: .topLeading) {
                RemoteImage(url: profile?.backgroundURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Theme.surfaceElevated } failure: { Theme.surfaceElevated }
                .frame(width: geo.size.width, height: 230)
                .clipped()
                // Затемнение как у hero-фона на карточке (адаптивное: на
                // светлом верхе почти не затемняем, чтобы читался чёрный текст).
                .overlay(bannerGradient)

                VStack(spacing: 0) {
                    // Место под topBar (отдельный слой поверх, см. body) —
                    // раньше кнопки были частью этого VStack, теперь только отступ.
                    Spacer(minLength: Self.topBarHeight)

                    // Аватар (слева) + статистика (справа), по центру баннера.
                    HStack(alignment: .center, spacing: 12) {
                        RemoteImage(url: profile?.avatarURL ?? (isSelf ? auth.avatarURL : nil)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { avatarPlaceholder } failure: { avatarPlaceholder }
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 8) {
                            statCard("Создано тайтлов", stats?.mangaCreated, width: statsW)
                            statCard("Загружено глав", stats?.chaptersUploaded, width: statsW)
                            statCard("Кол-во комментариев", stats?.comments, width: statsW)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 230)
    }

    /// Корневой контент профиля (баннер/статистика/быстрые кнопки) —
    /// вынесен из body отдельным свойством, чтобы им можно было управлять
    /// (opacity/offset) как одним из слоёв в общем ZStack (см. body).
    private var profileRootContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroBanner
                infoBlock

                if profile?.canViewStatistics ?? true {
                    statsSection("Статистика по жанрам", stats?.genres ?? [])
                    statsSection("Статистика по тегам", stats?.tags ?? [])
                }

                quickButtons

                if isSelf { actions }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    /// Один раздел (см. subScreen/openedScreens) — смонтирован, только если
    /// его хоть раз открывали (ленивая, но НЕОДНОКРАТНАЯ загрузка), и после
    /// этого остаётся в дереве насовсем: активный раздел — на месте,
    /// остальные (включая уже закрытые) — просто уезжают за кадр
    /// (opacity/offset), а не удаляются — поэтому их @StateObject/данные не
    /// пересоздаются и не грузятся заново при повторном открытии.
    @ViewBuilder
    private func subScreenLayer(_ screen: ProfileSubScreen) -> some View {
        if openedScreens.contains(screen) {
            Group {
                switch screen {
                case .bookmarks:
                    if let id = resolvedId { UserBookmarksView(userId: id, showsOwnHeader: false) }
                case .comments:
                    MyCommentsView(userId: resolvedId, showsOwnHeader: false)
                case .collections:
                    if let id = resolvedId { UserCollectionsView(userId: id, showsOwnHeader: false) }
                case .friends:
                    if let id = resolvedId { FriendsView(userId: id, showsOwnHeader: false) }
                }
            }
            .padding(.top, Self.topBarHeight)
            .opacity(subScreen == screen ? 1 : 0)
            .offset(x: subScreen == screen ? 0 : Self.slideDistance)
            .allowsHitTesting(subScreen == screen)
        }
    }

    private func openSubScreen(_ screen: ProfileSubScreen) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            openedScreens.insert(screen)
            subScreen = screen
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Theme.surfaceElevated
            Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(Theme.textSecondary)
        }
    }

    /// Ширина плашек статистики — фиксированная (числа сокращаются, так что
    /// всегда влезают); на всякий случай ограничена доступным местом, чтобы
    /// интерфейс не растягивался в бока на узких экранах.
    private func statsWidth(available: CGFloat) -> CGFloat {
        min(190, max(140, available))
    }

    /// Короткий формат числа: 1.4k, 10.2k, 100.9k, 1.2m — чтобы длинные
    /// значения не ужимались и не растягивали плашки.
    private static func shortNum(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fm", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    private func statCard(_ label: String, _ value: Int?, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value.map { Self.shortNum($0) } ?? "—")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile?.username ?? (isSelf ? auth.username : nil) ?? "Профиль")
                .font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            // Уровень и пол одной строкой с ровным разделителем « · ».
            let metaParts = [profile?.level.map { "Уровень \($0)" }, profile?.genderLabel]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            // "Последний вход" — именно login_streak.lastLoginAt (когда
            // реально логинился), а не lastOnlineAt (когда что-то делал —
            // обновляется чаще и не то же самое, см. комментарии в
            // UserProfile). Показываем, только если сервер реально прислал.
            if let lastLogin = profile?.lastLoginAt {
                Text("Последний вход \(lastLogin.relativeRussianString)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let about = profile?.about, !about.isEmpty {
                Text(about).font(.subheadline).foregroundStyle(Theme.textPrimary).padding(.top, 6)
            }

            if !isSelf { friendshipRow.padding(.top, 10) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Дружба (кнопка «Добавить в друзья» и текущий статус)

    @ViewBuilder
    private var friendshipRow: some View {
        let status = friendship?.status
        HStack(spacing: 10) {
            if status?.isFriend == true {
                friendshipLabel("Вы друзья", icon: "checkmark.circle.fill", tint: Theme.accent)
            } else if status?.isRequested == true {
                // Повторный тап — предложить отменить заявку (см.
                // showCancelFriendRequestConfirm/cancelFriendRequest).
                Button {
                    showCancelFriendRequestConfirm = true
                } label: {
                    if cancellingFriendRequest {
                        friendshipLabel("Отмена...", icon: "clock", tint: Theme.textSecondary)
                    } else {
                        friendshipLabel("Заявка отправлена", icon: "clock", tint: Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(cancellingFriendRequest)
            } else if status?.isAwaitingConfirmation == true {
                // Заявка ОТ этого пользователя — ПОДТВЕРЖДЕНО перехватом:
                // PUT /friendship/{id} {"status":2} отклоняет (см.
                // MangaNetworkService.respondToFriendRequest), status:1 —
                // принять (по аналогии с PUT /friendship/bulk).
                if respondingToFriendRequest {
                    friendshipLabel("Секунду...", icon: "clock", tint: Theme.textSecondary)
                } else {
                    Button { Task { await respondToFriendRequest(accept: false) } } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Button { Task { await respondToFriendRequest(accept: true) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("Принять")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { await sendFriendRequest() }
                } label: {
                    HStack(spacing: 6) {
                        if sendingFriendRequest {
                            ProgressView().tint(Theme.textPrimary).controlSize(.small)
                        } else {
                            Image(systemName: "person.badge.plus")
                        }
                        Text("Добавить в друзья")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(sendingFriendRequest)
            }
        }
        if let message = friendRequestMessage {
            Text(message).font(.caption).foregroundStyle(Theme.textSecondary).padding(.top, 4)
        }
    }

    private func friendshipLabel(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.surfaceElevated, in: Capsule())
    }

    // MARK: Статистика жанров/тегов (цветные чипы, горизонтально)

    @ViewBuilder
    private func statsSection(_ title: String, _ entries: [UserStatEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            statChip(e, color: Self.hueColor(i, entries.count))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func statChip(_ e: UserStatEntry, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(e.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(e.value)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(color, in: Capsule())
    }

    /// Цвет по индексу: тон идёт по кругу от красного (0) к сине-фиолетовому,
    /// так что соседние чипы отличаются буквально на пол-тона, а весь ряд —
    /// радуга в порядке тона.
    static func hueColor(_ index: Int, _ count: Int) -> Color {
        let t = count <= 1 ? 0 : Double(index) / Double(count - 1)
        let hue = t * 0.78            // 0 — красный, 0.78 — сине-фиолетовый
        return Color(hue: hue, saturation: 0.72, brightness: 0.82)
    }

    // MARK: Быстрые кнопки (каждая своей подложкой)

    private var quickButtons: some View {
        VStack(spacing: 10) {
            // «Списки тайтлов» — на своём профиле переход в локальную вкладку
            // Закладки (папка «Читаю»); на чужом — экран с РЕАЛЬНЫМИ папками
            // закладок этого пользователя (GET /bookmarks/folder/{userId}),
            // см. UserBookmarksView.
            if isSelf {
                Button {
                    CatalogNavigator.shared.openBookmarks(folderId: BookmarkFolder.reading.id)
                    dismiss()
                } label: {
                    quickRow("Списки тайтлов", "square.stack.3d.up")
                }.buttonStyle(.plain)
            } else if resolvedId != nil {
                Button { openSubScreen(.bookmarks) } label: {
                    quickRow("Списки тайтлов", "square.stack.3d.up")
                }.buttonStyle(.plain)
            }

            Button { openSubScreen(.comments) } label: {
                quickRow("Комментарии", "text.bubble")
            }.buttonStyle(.plain)

            if resolvedId != nil {
                Button { openSubScreen(.collections) } label: {
                    quickRow("Коллекции", "square.stack")
                }.buttonStyle(.plain)

                Button { openSubScreen(.friends) } label: {
                    quickRow("Друзья", "person.2")
                }.buttonStyle(.plain)
            }

            // "Личка" — эндпоинты личных сообщений (GET /messenger/threads?
            // page=&archived=, GET /messenger/threads/find/{userId}) реально
            // ПОДТВЕРЖДЕНЫ перехватом, но список в капче был пуст — форма
            // отдельного треда/сообщения ни разу не перехвачена, поэтому
            // честная заглушка (тот же StubListView, что и "Избранное"),
            // а не выдуманный экран переписки.
            NavigationLink { StubListView(title: "Сообщения") } label: {
                quickRow("Сообщения", "message")
            }.buttonStyle(.plain)

            NavigationLink { StubListView(title: "Избранное") } label: {
                quickRow("Избранное", "heart")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private func quickRow(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.accent).frame(width: 24)
            Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Действия (только свой профиль)

    private var actions: some View {
        VStack(spacing: 14) {
            NavigationLink { NetworkLogsView() } label: {
                Text("Логи сети (debug)")
                    .font(.headline).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .glassEffect(.regular.interactive(), in: Capsule())

            Button {
                auth.logout(); dismiss()
            } label: {
                Text("Выйти")
                    .font(.headline).foregroundStyle(.red)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
    }

    // MARK: Загрузка

    private func loadProfile() async {
        guard let id = resolvedId else { return }
        loadingProfile = true
        profile = try? await MangaNetworkService.shared.fetchUserProfile(id: id)
        loadingProfile = false
    }

    private func loadStats() async {
        guard let id = resolvedId else { return }
        stats = try? await MangaNetworkService.shared.fetchUserStats(id: id)
    }

    private func loadFriendshipIfNeeded() async {
        guard !isSelf, let id = resolvedId else { friendship = nil; return }
        friendship = try? await MangaNetworkService.shared.fetchFriendshipStatus(userId: id)
    }

    private func sendFriendRequest() async {
        guard let id = resolvedId, !sendingFriendRequest else { return }
        sendingFriendRequest = true
        friendRequestMessage = nil
        do {
            friendship = try await MangaNetworkService.shared.sendFriendRequest(recipientId: id)
        } catch {
            friendRequestMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        sendingFriendRequest = false
    }

    private func cancelFriendRequest() async {
        // DELETE /friendship/{id записи}, не {id пользователя} — см.
        // MangaNetworkService.cancelFriendRequest.
        guard let friendshipId = friendship?.id, !cancellingFriendRequest else { return }
        cancellingFriendRequest = true
        friendRequestMessage = nil
        do {
            try await MangaNetworkService.shared.cancelFriendRequest(friendshipId: friendshipId)
            friendship = nil
        } catch {
            friendRequestMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        cancellingFriendRequest = false
    }

    private func respondToFriendRequest(accept: Bool) async {
        guard let friendshipId = friendship?.id, !respondingToFriendRequest else { return }
        respondingToFriendRequest = true
        friendRequestMessage = nil
        do {
            friendship = try await MangaNetworkService.shared.respondToFriendRequest(id: friendshipId, accept: accept)
        } catch {
            friendRequestMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        respondingToFriendRequest = false
    }
}

/// Заглушка для ещё не реализованных разделов профиля.
/// «Дополнительная информация» — кнопка-щит в шапке профиля. Опыт/уровень,
/// дата регистрации, пол. НЕ содержит "В составе команд" — ни один
/// перехваченный запрос (см. журнал разбора network-капч этой сессии) не
/// вскрыл эндпоинт "команды пользователя", поэтому его тут нет — рисковать
/// и придумывать путь не стали. Каждая строка показывается, только если
/// соответствующее поле реально пришло от сервера.
private struct AdditionalInfoSheet: View {
    let profile: UserProfile?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if profile?.level != nil || profile?.totalPoints != nil {
                        experienceCard
                    }
                    if let date = profile?.createdAt {
                        infoRow(icon: "calendar", title: "Дата регистрации", value: Self.dateFormatter.string(from: date))
                    }
                    infoRow(icon: "person", title: "Пол",
                            value: (profile?.genderLabel?.isEmpty == false ? profile?.genderLabel : nil) ?? "Не указан")
                    if let teams = profile?.teams, !teams.isEmpty {
                        teamsSection(teams)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Дополнительная информация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Крестик вместо текста "Готово" — тот же размер/цвет, что и
                // у CreditsSheet/TeamMembersSheet (тот же класс маленьких
                // sheet-экранов), по прямой просьбе выровнять.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    @ViewBuilder
    private var experienceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "star.circle.fill").foregroundStyle(Theme.accent)
                Text("Опыт").font(.headline).foregroundStyle(Theme.textPrimary)
            }
            if let level = profile?.level {
                Text("Уровень \(level)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            }
            if let current = profile?.currentLevelPoints, let max = profile?.maxLevelPoints, max > 0 {
                ProgressView(value: Double(current), total: Double(max)).tint(Theme.accent)
                Text("\(current) из \(max) до следующего уровня")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let total = profile?.totalPoints {
                Text("Всего опыта: \(total)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// «В составе команд» — ПОДТВЕРЖДЕНО перехватом (ключ "teams" реально
    /// есть в /user/{id}, см. UserProfile.teams), хотя у самого
    /// перехваченного пользователя список был пуст — поэтому секция
    /// показывается только когда команды реально есть.
    private func teamsSection(_ teams: [ChapterTeam]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("В составе команд").font(.headline).foregroundStyle(Theme.textPrimary)
            VStack(spacing: 8) {
                ForEach(teams) { team in
                    if let slugURL = team.slugURL {
                        NavigationLink {
                            TeamView(slugURL: slugURL, fallbackName: team.name, coverURL: team.avatarURL)
                        } label: {
                            teamRow(team)
                        }
                        .buttonStyle(.plain)
                    } else {
                        teamRow(team)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func teamRow(_ team: ChapterTeam) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: team.avatarURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ZStack { Theme.surfaceElevated; Image(systemName: "person.3.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: "person.3.fill").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(team.name).font(.subheadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            if team.slugURL != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct StubListView: View {
    let title: String
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            StateView(icon: "hammer", title: title, description: "Раздел в разработке.", fillScreen: true)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Свой профиль (пункт меню) — тонкая обёртка над ProfileView.
struct AccountInfoView: View {
    var body: some View { ProfileView(userId: nil) }
}

#Preview {
    ProfileView(userId: nil).preferredColorScheme(.dark)
}
