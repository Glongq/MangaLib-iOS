import SwiftUI

/// Панель комментариев в читалке — по текущей странице главы. Сверху слева
/// сортировка (Новые/Старые/Популярные), справа «Настройки». Ниже — поле ввода
/// и дерево комментариев с голосованием/ответами/сворачиванием. Тема — под
/// читалку (светлеет вместе с ней). Если комментарии отключены — светло-серое
/// «Комментарии отключены» + чип «Настройки».
struct ChapterCommentsSheet: View {
    let chapterId: Int
    let postPage: Int
    /// Номер главы для заголовка «Комментарии к главе N · Страница M» —
    /// показывается только в неинлайн-панели (вертикальный режим, кнопка
    /// "text.bubble" в bottomBar). В embedded-режиме заголовок не нужен —
    /// глава и так ясна из контекста прокрутки.
    var chapterNumber: String? = nil
    /// Закрытие при инлайн-показе (не sheet): вызывается «хваталкой» сверху
    /// (тап или свайп вниз). Панель встроена в читалку с тем же фоном, поэтому
    /// собственного модального dismiss у неё нет.
    var onClose: (() -> Void)? = nil
    /// Встроенный режим: без своего фона и без внутреннего ScrollView —
    /// комментарии текут ПРОДОЛЖЕНИЕМ страницы в общей вертикальной прокрутке
    /// читалки (горизонтальный режим). Пагинация — по мере долистывания.
    var embedded: Bool = false

    @StateObject private var vm = ChapterCommentsViewModel()
    @Environment(\.dismiss) private var dismiss

    @AppStorage("reader_theme") private var readerTheme = 0
    @Environment(\.colorScheme) private var systemColorScheme
    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    @AppStorage("comments_disabled_in_reader") private var disabledInReader = false
    @AppStorage("comments_disabled_on_card") private var disabledOnCard = false
    @AppStorage("comments_collapse_level") private var collapseFromLevel: Double = 3

    @State private var draft = ""
    @State private var replyingTo: Comment?
    @State private var expandedThreads: Set<Int> = []
    @State private var showSettings = false
    @State private var showLogin = false

    @ObservedObject private var auth = AuthSession.shared

    var body: some View {
        Group {
            if embedded {
                // Продолжение страницы: без фона (просвечивает фон читалки) и
                // без своего ScrollView — список течёт в общей прокрутке.
                VStack(spacing: 0) {
                    header
                    if disabledInReader {
                        embeddedDisabledState
                    } else {
                        embeddedContent
                    }
                }
            } else {
                ZStack {
                    palette.background.ignoresSafeArea()
                    VStack(spacing: 0) {
                        if onClose != nil { grabber }
                        header
                        if disabledInReader {
                            disabledState
                        } else {
                            content
                        }
                    }
                }
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(palette.isLight ? .light : .dark)
            }
        }
        .tint(Theme.accent)
        .task(id: postPage) {
            vm.configure(chapterId: chapterId, postPage: postPage)
            if !disabledInReader { await vm.loadIfNeeded() }
        }
        .sheet(isPresented: $showSettings) {
            CommentSettingsSheet(
                disabledInReader: $disabledInReader,
                disabledOnCard: $disabledOnCard,
                collapseFromLevel: $collapseFromLevel,
                palette: palette
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLogin) { LoginView() }
    }

    /// «Хваталка» сверху для инлайн-панели: тап или свайп вниз — закрыть.
    private var grabber: some View {
        Image(systemName: "chevron.compact.down")
            .font(.title2)
            .foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture { onClose?() }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { v in if v.translation.height > 40 { onClose?() } }
            )
            .padding(.top, 6)
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Заголовок только у неинлайн-панели (вертикальный режим) — в
            // embedded-режиме (продолжением страницы) он не нужен.
            if let chapterNumber {
                Text("Комментарии к главе \(chapterNumber) · Страница \(postPage)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Menu {
                    Picker("Сортировка", selection: Binding(
                        get: { vm.sort },
                        set: { s in Task { await vm.changeSort(s) } }
                    )) {
                        ForEach(CommentSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    pill(vm.sort.title, systemImage: "arrow.up.arrow.down")
                }

                Spacer()

                Button { showSettings = true } label: {
                    pill("Настройки", systemImage: "slider.horizontal.3")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(palette.surface, in: Capsule())
    }

    /// Чип-кнопка «Настройки», ведущая в CommentSettingsSheet — используется
    /// в состоянии «отключено» вместо простой текстовой ссылки, чтобы явно
    /// читалась как кнопка (тот же стиль pill(), что и в шапке).
    private var disabledSettingsChip: some View {
        Button { showSettings = true } label: {
            pill("Настройки", systemImage: "slider.horizontal.3")
        }
    }

    private var disabledState: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Комментарии отключены")
                .font(.subheadline)
                .foregroundStyle(palette.secondary)
            disabledSettingsChip
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Та же «отключено» надпись, но для встроенного режима (продолжением
    /// страницы в читалке) — без Spacer'ов на всю высоту, просто блок в потоке.
    private var embeddedDisabledState: some View {
        VStack(spacing: 12) {
            Text("Комментарии отключены")
                .font(.subheadline)
                .foregroundStyle(palette.secondary)
            disabledSettingsChip
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: Контент

    private var content: some View {
        VStack(spacing: 0) {
            composeBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().overlay(palette.separator)

            ScrollView {
                if vm.isLoading && vm.comments.isEmpty {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, minHeight: 140)
                } else if let error = vm.error, vm.comments.isEmpty {
                    VStack(spacing: 10) {
                        Text(error).font(.footnote).foregroundStyle(palette.secondary)
                        Button("Повторить") { Task { await vm.load() } }
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                } else if vm.comments.isEmpty && vm.hasLoaded {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(palette.secondary)
                        Text("Пока нет комментариев к этой странице")
                            .font(.subheadline).foregroundStyle(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    list
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Встроенный контент (без ScrollView) — течёт в общей прокрутке читалки.
    private var embeddedContent: some View {
        VStack(spacing: 0) {
            composeBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().overlay(palette.separator)

            if vm.isLoading && vm.comments.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, minHeight: 140)
            } else if let error = vm.error, vm.comments.isEmpty {
                VStack(spacing: 10) {
                    Text(error).font(.footnote).foregroundStyle(palette.secondary)
                    Button("Повторить") { Task { await vm.load() } }
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else if vm.comments.isEmpty && vm.hasLoaded {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(palette.secondary)
                    Text("Пока нет комментариев к этой странице")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                list
            }
        }
    }

    private var list: some View {
        let grouped = vm.comments.groupedByParent()
        let roots = grouped[0] ?? []
        return LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(roots) { root in
                node(root, grouped: grouped)
                    .padding(12)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onAppear {
                        guard root.id == roots.last?.id else { return }
                        Task { await vm.loadMoreIfNeeded(current: root) }
                    }
            }
            if vm.isLoading && !vm.comments.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .padding(16)
    }

    // MARK: Дерево (рекурсия через AnyView — как в карточке)

    private func node(_ comment: Comment, grouped: [Int: [Comment]]) -> AnyView {
        let children = grouped[comment.id] ?? []
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                row(comment)
                if !children.isEmpty {
                    if let firstLevel = children.first?.commentLevel,
                       Double(firstLevel) >= collapseFromLevel, !expandedThreads.contains(comment.id) {
                        Button {
                            expandedThreads.insert(comment.id)
                        } label: {
                            Label("Показать ответы (\(children.count))", systemImage: "chevron.down")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.leading, 28)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(children) { child in
                                Divider().overlay(palette.separator)
                                node(child, grouped: grouped)
                            }
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func threadBars(_ level: Int) -> some View {
        if level > 0 {
            HStack(spacing: 4) {
                ForEach(0..<level, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(palette.separator).frame(width: 2)
                }
            }
        }
    }

    private func row(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            threadBars(comment.commentLevel)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    RemoteImage(url: comment.author?.avatarURL.flatMap(URL.init(string:))) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(palette.surface)
                    } failure: {
                        Circle().fill(palette.surface).overlay(
                            Image(systemName: "person.fill").font(.footnote).foregroundStyle(palette.secondary)
                        )
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.author?.username ?? "Аноним")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.foreground)
                        if let date = comment.date {
                            Text(date.relativeRussianString)
                                .font(.caption2).foregroundStyle(palette.secondary)
                        }
                    }
                }

                if !comment.text.isEmpty {
                    Text(comment.text).font(.subheadline).foregroundStyle(palette.foreground)
                }

                HStack(spacing: 16) {
                    Button { replyingTo = comment } label: {
                        Text("Ответить").font(.caption.weight(.medium)).foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    HStack(spacing: 5) {
                        Button {
                            if auth.isLoggedIn { Task { await vm.vote(comment, isUp: true) } } else { showLogin = true }
                        } label: {
                            Image(systemName: comment.userVote == 1 ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                                .font(.system(size: 11))
                                .foregroundStyle(comment.userVote == 1 ? .green : palette.secondary)
                        }
                        .buttonStyle(.plain)

                        Text("\(comment.score)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(scoreColor(comment.score))

                        Button {
                            if auth.isLoggedIn { Task { await vm.vote(comment, isUp: false) } } else { showLogin = true }
                        } label: {
                            Image(systemName: comment.userVote == 0 ? "arrowtriangle.down.fill" : "arrowtriangle.down")
                                .font(.system(size: 11))
                                .foregroundStyle(comment.userVote == 0 ? .red : palette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score > 0 { return .green }
        if score < 0 { return .red }
        return palette.secondary
    }

    // MARK: Поле ввода

    @ViewBuilder
    private var composeBar: some View {
        if auth.isLoggedIn {
            VStack(alignment: .leading, spacing: 6) {
                if let replyingTo {
                    HStack(spacing: 6) {
                        Text("Ответ \(replyingTo.author?.username ?? "аноним")")
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                        Button { self.replyingTo = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Написать комментарий...", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button {
                        let text = draft
                        let parent = replyingTo
                        draft = ""; replyingTo = nil
                        Task { let ok = await vm.post(text: text, replyingTo: parent); if !ok { draft = text } }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(trimmed.isEmpty ? palette.secondary : Theme.accent)
                    }
                    .disabled(trimmed.isEmpty || vm.isPosting)
                }
            }
            .padding(.top, 4)
        } else {
            Button { showLogin = true } label: {
                Label("Войдите, чтобы оставить комментарий", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.foreground)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(palette.surface, in: Capsule())
            }
            .padding(.top, 4)
        }
    }
}
