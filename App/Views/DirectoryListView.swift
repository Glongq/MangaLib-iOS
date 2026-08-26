import SwiftUI

/// Список одного вида каталожной сущности (Команды/Персонажи/Люди/
/// Издательства) — Меню → Каталог → соответствующий пункт. Один и тот же
/// экран на все четыре, см. DirectoryKind/DirectoryListViewModel — 1-в-1
/// паттерн FranchiseListView, плюс обложка-миниатюра слева (у франшизы её
/// не было). Тап по строке: Команды/Персонажи ведут на УЖЕ существующие
/// TeamView/CharacterView (свои полноценные экраны), Люди/Издательства — на
/// новый общий DirectoryDetailView (см. destination).
struct DirectoryListView: View {

    @StateObject private var vm: DirectoryListViewModel
    @ObservedObject private var themeManager = ThemeManager.shared

    init(kind: DirectoryKind) {
        _vm = StateObject(wrappedValue: DirectoryListViewModel(kind: kind))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle(vm.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        // .always — поиск сразу развёрнутой пилюлей, без адаптивного
        // сворачивания на стартовой позиции (тот же фикс, что и в Каталоге).
        .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск по названию")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        .tint(Theme.accent)
        .task { vm.loadInitialIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.errorMessage, vm.items.isEmpty {
            errorState(error)
        } else if vm.items.isEmpty && vm.isLoading {
            ProgressView().tint(Theme.accent)
        } else if vm.items.isEmpty && vm.didLoadOnce {
            ContentUnavailableView.search(text: vm.query)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(vm.items) { entity in
                    row(entity)
                        .onAppear { vm.loadMoreIfNeeded(currentItem: entity) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)

            if vm.isLoadingMore {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
            Button { vm.retry() } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: Сортировка

    private var sortMenu: some View {
        Menu {
            Picker("Сортировка", selection: Binding(
                get: { vm.sort }, set: { vm.changeSort($0) }
            )) {
                ForEach(vm.kind.sortOptions) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            if vm.kind.sortOptions.count > 1 {
                Divider()
                Picker("Направление", selection: $vm.sortDescending) {
                    Label("По возрастанию", systemImage: "arrow.up").tag(false)
                    Label("По убыванию", systemImage: "arrow.down").tag(true)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    // MARK: Строка

    @ViewBuilder
    private func row(_ entity: DirectoryEntity) -> some View {
        switch vm.kind.targetModel {
        case "team":
            NavigationLink {
                TeamView(slugURL: entity.slugURL, fallbackName: entity.displayName, coverURL: entity.coverURL)
            } label: { rowContent(entity) }
            .buttonStyle(.plain)
        case "character":
            NavigationLink {
                CharacterView(slugURL: entity.slugURL, fallbackName: entity.displayName, coverURL: entity.coverURL)
            } label: { rowContent(entity) }
            .buttonStyle(.plain)
        default:
            NavigationLink {
                DirectoryDetailView(kind: vm.kind, slugURL: entity.slugURL, fallbackName: entity.displayName, coverURL: entity.coverURL)
            } label: { rowContent(entity) }
            .buttonStyle(.plain)
        }
    }

    /// Обложка — то же соотношение 2:3, что и у "хиро"-аватара в самой
    /// карточке команды (см. TeamView.heroHeader: avatarHeight = avatarSize*
    /// 3/2), только заметно меньше и БЕЗ отступов — высота обложки задаёт
    /// высоту всей строки целиком, обложка заполняет подложку слева от края
    /// до края (по прямой просьбе), а не плавает по центру с паддингом, как
    /// раньше (44×44 с закруглением со всех сторон).
    private static let rowCoverWidth: CGFloat = 64
    private static let rowCoverHeight: CGFloat = 96

    private func rowContent(_ entity: DirectoryEntity) -> some View {
        HStack(spacing: 0) {
            RemoteImage(url: entity.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: vm.kind.placeholderIcon).foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: Self.rowCoverWidth, height: Self.rowCoverHeight)
            .clipped()
            // Закругление ТОЛЬКО с левой стороны — обложка встык с текстом
            // справа, без отдельной подложки под собой.
            .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 16))

            VStack(alignment: .leading, spacing: 6) {
                Text(entity.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                statsChipsRow(entity)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.kind.sourceType != nil {
                subscribeBell(entity)
                    .padding(.trailing, 10)
            }
        }
        .frame(height: Self.rowCoverHeight)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Короткие чипы-метаданные — иконка + значение (short, уже отформатировано
    /// сервером вроде "105.8 М"/"1,9 К"), в формате чипов из самой карточки
    /// команды (Capsule/pill), только компактнее и на подложку потемнее
    /// (Theme.surface — сама строка уже surfaceElevated, иначе чип слился бы
    /// с фоном). Порядок и иконки — по прямой просьбе: тайтлы → лайки →
    /// подписчики; любой другой tag, который вдруг пришлёт сервер, тоже
    /// показываем (нейтральной иконкой), а не молча теряем.
    private static let statIconOrder: [(tag: String, icon: String)] = [
        ("titles", "book.closed.fill"),
        ("likes", "heart.fill"),
        ("subscribes", "person.3.fill")
    ]

    private func statsChipsRow(_ entity: DirectoryEntity) -> some View {
        var used = Set<String>()
        var chips: [(id: String, icon: String, value: String)] = []
        for (tag, icon) in Self.statIconOrder {
            if let stat = entity.stats.first(where: { $0.tag == tag }), let short = stat.short {
                chips.append((tag, icon, short))
                used.insert(tag)
            }
        }
        for stat in entity.stats where !used.contains(stat.tag ?? "") {
            if let short = stat.short {
                chips.append((stat.id, "circle.fill", short))
            }
        }
        return HStack(spacing: 6) {
            ForEach(chips, id: \.id) { chip in
                statChip(icon: chip.icon, value: chip.value)
            }
        }
    }

    private func statChip(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(value).font(.caption2.weight(.medium))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.surface, in: Capsule())
    }

    private func subscribeBell(_ entity: DirectoryEntity) -> some View {
        Button {
            vm.toggleSubscription(entity)
        } label: {
            ZStack {
                Circle().fill(Theme.surface)
                if vm.isToggling(entity.id) {
                    ProgressView().scaleEffect(0.7)
                } else if entity.isSubscribed {
                    ZStack {
                        Image(systemName: "bell.fill")
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                            .offset(x: 7, y: -7)
                    }
                    .foregroundStyle(Theme.textPrimary)
                } else {
                    Image(systemName: "bell")
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(vm.isToggling(entity.id))
    }
}

#Preview {
    NavigationStack {
        DirectoryListView(kind: .people)
    }
    .preferredColorScheme(.dark)
}
