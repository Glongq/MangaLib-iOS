import SwiftUI

/// Экран «Франшизы» (Меню → Каталог → Франшизы) — постраничный список
/// `GET /franchise` (см. FranchiseListViewModel), поиск/сортировка + прямая
/// подписка/отписка колокольчиком в строке, без захода в саму франшизу.
struct FranchiseListView: View {

    @StateObject private var vm = FranchiseListViewModel()
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Франшизы")
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
                ForEach(vm.items) { franchise in
                    row(franchise)
                        .onAppear { vm.loadMoreIfNeeded(currentItem: franchise) }
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
            Picker("Сортировка", selection: $vm.sort) {
                ForEach(FranchiseSort.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            Divider()
            Picker("Направление", selection: $vm.sortDescending) {
                Label("По возрастанию", systemImage: "arrow.up").tag(false)
                Label("По убыванию", systemImage: "arrow.down").tag(true)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    // MARK: Строка франшизы

    private func row(_ franchise: Franchise) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                FranchiseView(slugURL: franchise.slugURL, fallbackName: franchise.name)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(franchise.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    statsLine(franchise)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            subscribeBell(franchise)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Значения/подписи — прямо с сервера, готовые (уже правильно
    /// склонённые по-русски: "8 Тайтлов" vs "13882 Тайтла" и т.п., см.
    /// TeamStat/Franchise.stats) — своей склонялки не пишем.
    private func statsLine(_ franchise: Franchise) -> some View {
        HStack(spacing: 8) {
            ForEach(franchise.stats) { stat in
                if let value = stat.value, let label = stat.label {
                    Text("\(value) \(label)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func subscribeBell(_ franchise: Franchise) -> some View {
        Button { vm.toggleSubscription(franchise) } label: {
            ZStack {
                Circle().fill(Theme.surface)
                if vm.isToggling(franchise.id) {
                    ProgressView().scaleEffect(0.7)
                } else if franchise.isSubscribed {
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
        .disabled(vm.isToggling(franchise.id))
    }
}

#Preview {
    NavigationStack {
        FranchiseListView()
    }
    .preferredColorScheme(.dark)
}
