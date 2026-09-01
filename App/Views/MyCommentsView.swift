import SwiftUI

/// «Мои комментарии» (раздел меню → Профиль → Комментарии): список
/// комментариев аккаунта с обложкой тайтла, текстом, голосами и датой. Внизу —
/// фильтр по типу и сортировка (инлайн-меню, НЕ отдельный sheet). Тап по
/// комментарию открывает тайтл; долгий тап — удалить свой комментарий.
struct MyCommentsView: View {
    let embedded: Bool
    /// false — встроен в ProfileView без своей шапки (см.
    /// UserBookmarksView.showsOwnHeader). У этого экрана два входа —
    /// из бокового меню (embedded: true, showsOwnHeader: true, своя шапка) и
    /// из профиля (userId:, showsOwnHeader: false, общая "перетекающая"
    /// шапка профиля).
    var showsOwnHeader: Bool = true

    @StateObject private var vm: MyCommentsViewModel
    @ObservedObject private var themeManager = ThemeManager.shared

    init(embedded: Bool = false, userId: Int? = nil, showsOwnHeader: Bool = true) {
        self.embedded = embedded
        self.showsOwnHeader = showsOwnHeader
        _vm = StateObject(wrappedValue: MyCommentsViewModel(userId: userId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        // showsOwnHeader — обычный push из Меню: родной системный заголовок +
        // системный back chevron, никакого своего кода (эталон — Настройки/
        // Загрузки). Без него (встроен в ProfileView) — навбар по-прежнему
        // скрыт, шапку рисует сам ProfileView.topBar (см. AccountInfoView).
        .navigationTitle("Комментарии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsOwnHeader ? .visible : .hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { controlsBar }
        .task { await vm.loadIfNeeded() }
    }

    // MARK: Контент

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.comments.isEmpty {
            skeletonList
        } else if vm.needsLogin {
            ScrollView {
                StateView(icon: "person.crop.circle.badge.exclamationmark", title: "Нужно войти в аккаунт", fillScreen: true)
                    .containerRelativeFrame(.vertical)
            }
            .scrollIndicators(.hidden)
        } else if let error = vm.errorMessage, vm.comments.isEmpty {
            // ScrollView (не голый VStack) — иначе .refreshable ниже не от
            // чего было бы тянуть при пустом/ошибочном списке.
            ScrollView {
                StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: error, retry: { Task { await vm.reload() } }, fillScreen: true)
                    .containerRelativeFrame(.vertical)
            }
            .scrollIndicators(.hidden)
            .refreshable { await vm.reload() }
        } else if vm.visible.isEmpty && vm.didLoad {
            ScrollView {
                StateView(icon: "text.bubble", title: "Комментариев пока нет", fillScreen: true)
                    .containerRelativeFrame(.vertical)
            }
            .scrollIndicators(.hidden)
            .refreshable { await vm.reload() }
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
            .refreshable { await vm.reload() }
        }
    }

    /// Скелетон на первую загрузку — по прямой просьбе, вместо голого
    /// спиннера. Форма строки повторяет commentCard ниже (обложка 60×84 +
    /// пара строк текста), на плейсхолдерах SkeletonBox/SkeletonBar.
    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in commentSkeletonRow }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(false)
    }

    /// Раньше без своей подложки/паддинга — во время загрузки список
    /// выглядел плоским текстом, а не карточками (как в реальном
    /// commentCard). Теперь 1-в-1 форма настоящей карточки.
    private var commentSkeletonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBox()
                .frame(width: 60, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBar(width: 140)
                SkeletonBar(width: 220, height: 10)
                SkeletonBar(width: 170, height: 10)
                SkeletonBar(width: 70, height: 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
