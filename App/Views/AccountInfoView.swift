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

    /// Id для .glassEffectID ниже (см. header/quickButtons) — капсула
    /// "Готово" здесь и круглая кнопка "назад" в каждом из четырёх пушнутых
    /// экранов (Списки тайтлов/Комментарии/Коллекции/Друзья) помечены ОДНИМ
    /// и тем же id в общем @Namespace (glassTransition, передаётся вниз
    /// параметром) — по прямой просьбе "плавный стекло-переход от кнопки
    /// готово к кнопке назад и обратно". ЧЕСТНО: это новый для кодовой базы
    /// приём (GlassEffectContainer здесь уже применялся, но НЕ через пуш
    /// NavigationStack, а .glassEffectID вообще нигде раньше не
    /// использовался) — протестировать вживую в этой среде нечем (нет
    /// симулятора), так что стоит проверить на устройстве; если морф не
    /// подхватится через пуш — деградирует просто в обычную мгновенную
    /// смену формы, ничего не сломается.
    static let dismissGlassID = "profile-dismiss-glass"
    @Namespace private var glassTransition

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

    init(userId: Int? = nil) { self.userId = userId }

    private var resolvedId: Int? { userId ?? auth.userId }
    private var isSelf: Bool { let r = resolvedId; return r != nil && r == auth.userId }
    /// Ключ для перезагрузки статистики при смене профиля ИЛИ активного сайта.
    private var statsKey: String { "\(resolvedId ?? 0)-\(site.activeSite.rawValue)" }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Theme.background.ignoresSafeArea()

                if let profile, !profile.canViewProfile {
                    closedState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header
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
                    // Баннер уходит в самый верх (под статус-бар), как hero на
                    // карточке тайтла. «Готово», аватар и плашки — часть шапки.
                    .ignoresSafeArea(edges: .top)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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

    private var topTextColor: Color { bannerTopLight ? .black : .white }

    // MARK: Закрытый профиль

    /// .frame(maxWidth/maxHeight: .infinity) — родительский ZStack в body
    /// выровнен по .topLeading (нужно для баннера/шапки в обычном
    /// состоянии), без явного растяжения этот блок прижимался к левому
    /// верхнему углу вместо центра экрана.
    private var closedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text("Профиль закрыт").font(.headline).foregroundStyle(Theme.textPrimary)
            Text(profile?.username ?? "").font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Шапка (баннер + аватар + топ-статистика)

    private var header: some View {
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
                    // Верхняя строка: «Готово» слева, заголовок по центру.
                    ZStack {
                        Text("Профиль")
                            .font(.headline)
                            .foregroundStyle(topTextColor)
                            .shadow(color: (bannerTopLight ? Color.white : Color.black).opacity(0.4), radius: 2)
                        HStack {
                            // GlassEffectContainer + .glassEffectID(Self.dismissGlassID,
                            // in: glassTransition) — та же пара id/namespace, что и у
                            // кнопки "назад" в пушнутых экранах ниже (см.
                            // quickButtons), чтобы форма плавно перетекала
                            // капсула → круг при переходе и обратно.
                            GlassEffectContainer {
                                Button { dismiss() } label: {
                                    Text("Готово")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(topTextColor)
                                        .padding(.horizontal, 18).frame(height: 46)
                                        .glassEffect(.regular.interactive(), in: Capsule())
                                        .glassEffectID(Self.dismissGlassID, in: glassTransition)
                                }
                            }
                            Spacer(minLength: 0)
                            // «Щит» — дополнительная информация о пользователе
                            // (опыт/уровень, дата регистрации, пол) — см.
                            // AdditionalInfoSheet.
                            Button { showAdditionalInfo = true } label: {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(topTextColor)
                                    .frame(width: 46, height: 46)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                        }
                    }

                    Spacer(minLength: 8)

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
                // Это sheet — статус-бара над контентом нет, поэтому «Готово»
                // прижата к самому верху баннера (без запаса под статус-бар).
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(height: 230)
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
                // Заявка ОТ этого пользователя — принять/отклонить не
                // реализовано: коды status для PUT /friendship/{id} не
                // подтверждены ни одним перехватом (см. capture 2026-08-25),
                // рисковать записью в реальный аккаунт наугад не стал.
                friendshipLabel("Ожидает вашего решения", icon: "person.crop.circle.badge.questionmark", tint: Theme.textSecondary)
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
            } else if let id = resolvedId {
                NavigationLink { UserBookmarksView(userId: id, glassTransition: glassTransition) } label: {
                    quickRow("Списки тайтлов", "square.stack.3d.up")
                }.buttonStyle(.plain)
            }

            NavigationLink { MyCommentsView(userId: resolvedId, glassTransition: glassTransition) } label: {
                quickRow("Комментарии", "text.bubble")
            }.buttonStyle(.plain)

            if let id = resolvedId {
                NavigationLink { UserCollectionsView(userId: id, glassTransition: glassTransition) } label: {
                    quickRow("Коллекции", "square.stack")
                }.buttonStyle(.plain)

                NavigationLink { FriendsView(userId: id, glassTransition: glassTransition) } label: {
                    quickRow("Друзья", "person.2")
                }.buttonStyle(.plain)
            }

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
        guard let id = resolvedId, !cancellingFriendRequest else { return }
        cancellingFriendRequest = true
        friendRequestMessage = nil
        do {
            try await MangaNetworkService.shared.cancelFriendRequest(userId: id)
            friendship = nil
        } catch {
            friendRequestMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        cancellingFriendRequest = false
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
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
            VStack(spacing: 10) {
                Image(systemName: "hammer").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                Text("«\(title)» скоро").font(.headline).foregroundStyle(Theme.textPrimary)
            }
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
