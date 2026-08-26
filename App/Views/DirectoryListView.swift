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
        .searchable(text: $vm.query, prompt: "Поиск по названию")
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
                    Text(option.title).tag(option)
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

    private func rowContent(_ entity: DirectoryEntity) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: entity.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                SkeletonBox()
            } failure: {
                ZStack { Theme.surfaceElevated; Image(systemName: vm.kind.placeholderIcon).foregroundStyle(Theme.textSecondary) }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(entity.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                statsLine(entity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if vm.kind.sourceType != nil {
                subscribeBell(entity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

    private func statsLine(_ entity: DirectoryEntity) -> some View {
        HStack(spacing: 8) {
            ForEach(entity.stats) { stat in
                if let value = stat.value, let label = stat.label {
                    Text("\(value) \(label)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
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
