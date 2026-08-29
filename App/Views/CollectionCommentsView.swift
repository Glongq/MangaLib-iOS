import SwiftUI

/// Комментарии к коллекции — push с CollectionDetailView (кнопка
/// "Комментарии" внизу). Сортировка сверху, дерево строится через
/// Comment.groupedByParent() (тот же проверенный хелпер, что и у комментариев
/// тайтла/главы) — корневые + один уровень ответов с лёгким отступом, без
/// сворачивания глубоких тредов (для коллекции это не требовалось).
struct CollectionCommentsView: View {
    let collectionId: Int

    @StateObject private var vm: CollectionCommentsViewModel
    @State private var draft = ""
    @State private var replyingTo: Comment?
    @FocusState private var composerFocused: Bool
    // Раньше поле ввода было доступно ВСЕГДА, даже не залогиненным — в
    // отличие от всех остальных мест с комментариями в приложении
    // (MangaDetailView/ChapterCommentsSheet), где не вошедшему показывается
    // пилюля "Войдите, чтобы оставить комментарий". Выровнено.
    @ObservedObject private var auth = AuthSession.shared
    @State private var showLogin = false

    init(collectionId: Int) {
        self.collectionId = collectionId
        _vm = StateObject(wrappedValue: CollectionCommentsViewModel(collectionId: collectionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            composer
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Комментарии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        .task { await vm.loadIfNeeded() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Сортировка", selection: Binding(
                get: { vm.sort },
                set: { newValue in Task { await vm.changeSort(newValue) } }
            )) {
                ForEach(CommentSort.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").foregroundStyle(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.comments.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.comments.isEmpty {
            StateView(icon: "wifi.exclamationmark", title: "Не удалось загрузить", description: error, retry: { Task { await vm.load() } }, fillScreen: true)
        } else if vm.comments.isEmpty && vm.hasLoaded {
            StateView(icon: "text.bubble", title: "Комментариев пока нет", fillScreen: true)
        } else {
            let grouped = vm.comments.groupedByParent()
            let roots = grouped[0] ?? []
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(roots) { root in
                        commentRow(root, isReply: false)
                            .onAppear { Task { await vm.loadMoreIfNeeded(current: root) } }
                        ForEach(grouped[root.id] ?? []) { reply in
                            commentRow(reply, isReply: true)
                        }
                    }
                    if vm.isLoading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func commentRow(_ c: Comment, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: c.author?.avatarURL.flatMap(URL.init(string:))) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Theme.surfaceElevated)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.author?.username ?? "Аноним")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let date = c.date {
                        Text(date.relativeRussianString)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(c.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 14) {
                    Button { Task { await vm.vote(c, isUp: true) } } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                            Text("\(c.votesUp)")
                        }
                        .foregroundStyle(c.userVote == 1 ? Theme.accent : Theme.textSecondary)
                    }
                    Button { Task { await vm.vote(c, isUp: false) } } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                            Text("\(c.votesDown)")
                        }
                        .foregroundStyle(c.userVote == 0 ? Color.red : Theme.textSecondary)
                    }
                    Button("Ответить") {
                        replyingTo = c
                        composerFocused = true
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, isReply ? 34 : 0)
    }

    @ViewBuilder
    private var composer: some View {
        if auth.isLoggedIn {
            VStack(spacing: 0) {
                if let replyingTo {
                    HStack(spacing: 6) {
                        Text("Ответ для \(replyingTo.author?.username ?? "Аноним")")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Button { self.replyingTo = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                HStack(spacing: 8) {
                    TextField("", text: $draft, prompt: Text("Комментарий...").foregroundColor(Theme.textSecondary), axis: .vertical)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($composerFocused)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceElevated, in: Capsule())

                    Button {
                        let target = replyingTo
                        Task {
                            if await vm.post(text: draft, replyingTo: target) {
                                draft = ""
                                replyingTo = nil
                            }
                        }
                    } label: {
                        if vm.isPosting {
                            ProgressView().tint(Theme.background).frame(width: 36, height: 36)
                        } else {
                            Image(systemName: "arrow.up")
                                .foregroundStyle(Theme.background)
                                .frame(width: 36, height: 36)
                                .background(Theme.accent, in: Circle())
                        }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isPosting)
                }
                .padding(12)
            }
            .background(.ultraThinMaterial)
        } else {
            Button { showLogin = true } label: {
                Label("Войдите, чтобы оставить комментарий", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: Theme.pillControlHeight)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .sheet(isPresented: $showLogin) { LoginView() }
        }
    }
}

#Preview {
    NavigationStack { CollectionCommentsView(collectionId: 1) }.preferredColorScheme(.dark)
}
