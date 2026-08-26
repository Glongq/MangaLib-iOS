import SwiftUI

/// «Мои комментарии» (раздел меню → Профиль → Комментарии): список
/// комментариев аккаунта с обложкой тайтла, текстом, голосами и датой. Внизу —
/// фильтр по типу и сортировка (инлайн-меню, НЕ отдельный sheet). Тап по
/// комментарию открывает тайтл; долгий тап — удалить свой комментарий.
struct MyCommentsView: View {
    let embedded: Bool

    @StateObject private var vm: MyCommentsViewModel
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    init(embedded: Bool = false, userId: Int? = nil) {
        self.embedded = embedded
        _vm = StateObject(wrappedValue: MyCommentsViewModel(userId: userId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { controlsBar }
        .task { await vm.loadIfNeeded() }
    }

    // MARK: Шапка

    /// Позиция кнопки "назад" и заголовка — та же, что и в шапке "Профиль"
    /// (см. AccountInfoView.header: padding.top 14) — раньше здесь было 8.
    private var header: some View {
        ZStack {
            Text("Комментарии").font(.headline).foregroundStyle(Theme.textPrimary)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.comments.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let error = vm.errorMessage, vm.comments.isEmpty {
            emptyState(icon: "wifi.exclamationmark", text: error) { Task { await vm.reload() } }
        } else if vm.visible.isEmpty && vm.didLoad {
            emptyState(icon: "text.bubble", text: "Комментариев нет", retry: nil)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.visible) { c in
                        commentRow(c)
                            .onAppear { Task { await vm.loadMoreIfNeeded(current: c) } }
                    }
                    if vm.isLoadingMore {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func commentRow(_ c: UserComment) -> some View {
        if let slug = c.slugURL {
            NavigationLink {
                MangaDetailView(slug: slug, fallbackTitle: c.title ?? "", coverURL: c.coverURL)
            } label: {
                commentCard(c)
            }
            .buttonStyle(.plain)
            .contextMenu { deleteButton(c) }
        } else {
            commentCard(c)
                .contextMenu { deleteButton(c) }
        }
    }

    private func deleteButton(_ c: UserComment) -> some View {
        Button(role: .destructive) {
            Task { await vm.delete(c) }
        } label: {
            Label("Удалить комментарий", systemImage: "trash")
        }
    }

    private func commentCard(_ c: UserComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if c.coverURL != nil {
                RemoteImage(url: c.coverURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    SkeletonBox()
                } failure: {
                    ZStack { Theme.surfaceElevated; Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
                }
                // Тот же размер обложки, что и в Истории (60×84) — единый вид карточек списка.
                .frame(width: 60, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // maxWidth: .infinity — без этого VStack (и Text внутри) меряет
            // себя по идеальной ширине контента, а не по доступной ширине
            // ряда: HStack тогда не распределяет лишнее место, и справа
            // остаётся пустая "мёртвая зона" вместо переноса строк текста.
            VStack(alignment: .leading, spacing: 4) {
                if let title = c.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if let sub = c.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                }

                Text(c.plainText.isEmpty ? "—" : c.plainText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                // Значки и дата — отдельной строкой под текстом.
                HStack(spacing: 12) {
                    if let d = c.createdAt {
                        Text(d.relativeRussianString)
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Label("\(c.up - c.down)", systemImage: "arrow.up")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func emptyState(icon: String, text: String, retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            if let retry {
                Button("Повторить", action: retry)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: Фильтр / сортировка (инлайн внизу, не sheet)

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Фильтр", selection: $vm.filter) {
                    ForEach(MyCommentsViewModel.Filter.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                pill(icon: "line.3.horizontal.decrease", text: vm.filter.title)
            }

            Menu {
                Picker("Сортировка", selection: $vm.sort) {
                    ForEach(MyCommentsViewModel.Sort.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                pill(icon: "arrow.up.arrow.down", text: vm.sort.title)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            Text(text).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.pillControlHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

#Preview {
    NavigationStack { MyCommentsView() }.preferredColorScheme(.dark)
}
