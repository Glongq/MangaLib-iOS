import SwiftUI

/// Вкладка «Уведомления» — реальный `GET /notifications` (см.
/// NotificationsViewModel/MangaNetworkService.fetchNotifications).
///
/// Автообновление "при каждом заходе в приложение": `.task` при первом
/// появлении экрана (в т.ч. когда возвращаешься на эту вкладку — `screen` в
/// RootView пересобирает вьюху при каждом переключении таба, значит `.task`
/// отрабатывает заново) + `.onChange(of: scenePhase)` при возврате из фона,
/// пока вкладка уже открыта. Потянуть-обновить (долгий свайп вниз) — тот же
/// viewModel.refresh() через `.refreshable`.
struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFilterSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
                    .safeAreaInset(edge: .top, spacing: 0) { header }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MangaItem.self) { item in
                MangaDetailView(
                    slug: item.apiSlug, fallbackTitle: item.displayTitle,
                    coverURL: item.cover?.bestURL, item: item
                )
            }
            .sheet(isPresented: $showFilterSheet) {
                NotificationFilterSheet(readFilter: $viewModel.readFilter, sortOrder: $viewModel.sortOrder)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        // Кнопка сортировки — снизу СЛЕВА, над главной панелью. Тот же приём,
        // что и у Фильтры/Сортировка в Каталоге/полоски подкатегорий в
        // Закладках: safeAreaInset СНАРУЖИ NavigationStack, чтобы корректно
        // сложиться с внешним инсетом главной панели из RootView (см.
        // комментарии там же).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                filterButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .tint(Theme.accent)
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await viewModel.refresh() }
            }
        }
    }

    // MARK: Шапка

    private var header: some View {
        Text("Уведомления")
            .font(.title3.weight(.bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
    }

    /// Круглая кнопка сортировки/фильтра — открывает NotificationFilterSheet.
    /// Бейдж — реальное число из GET /notifications/count (unread.all), не
    /// посчитано на клиенте.
    private var filterButton: some View {
        Button { showFilterSheet = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: Theme.pillControlHeight, height: Theme.pillControlHeight)

                if let unread = viewModel.counts?.unread.all, unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 6, y: -4)
                }
            }
        }
        .glassEffect(.regular.interactive(), in: Circle())
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage, viewModel.items.isEmpty {
            errorState(error)
        } else if viewModel.items.isEmpty && viewModel.isLoading {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.items.isEmpty && viewModel.hasLoadedOnce {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.items) { item in
                    row(item)
                        .onAppear {
                            guard item.id == viewModel.items.last?.id else { return }
                            Task { await viewModel.loadMoreIfNeeded(current: item) }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            // Запас снизу — чтобы последняя карточка не оказалась под
            // кнопкой сортировки/главной панелью (тот же приём, что и в
            // Закладках, см. комментарий там: 90→120).
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .refreshable { await viewModel.refresh() }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.readFilter == .unread ? "Нет новых уведомлений" : "Уведомлений нет",
            systemImage: "bell",
            description: Text("Здесь появятся новые главы, ответы и другие события.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Строка уведомления

    @ViewBuilder
    private func row(_ item: NotificationItem) -> some View {
        let core = HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.media?.cover?.bestURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceElevated)
            } failure: {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceElevated)
                    .overlay(Image(systemName: "bell.fill").foregroundStyle(Theme.textSecondary))
            }
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)

                // Команда(ы) перевода — "Армия 100 богинь", "ImageBoard Team,
                // ONIMAI.RU" и т.п. (см. NotificationItem.teamNames) —
                // подтверждённое реальным перехватом поле "teams".
                if !item.teamNames.isEmpty {
                    Text(item.teamNames)
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }

                Text(item.createdAt.relativeRussianString)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        if let media = item.media {
            NavigationLink(value: media) { core }
                .buttonStyle(.plain)
        } else {
            core
        }
    }
}

#Preview {
    NotificationsView()
        .preferredColorScheme(.dark)
}
