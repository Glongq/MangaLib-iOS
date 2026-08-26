import SwiftUI

/// Отзывы на тайтл — GET /reviews?reviewable_type=manga&reviewable_id=.
/// Карточка: автор, дата, заголовок, текст отзыва (обрезанный), оценки по
/// категориям (rating[]), голоса и число комментариев.
struct MangaReviewsView: View {
    let mangaId: Int
    let mangaTitle: String
    let siteId: Int?

    @StateObject private var vm: MangaReviewsViewModel
    @State private var profileUser: ProfileUserId?
    @ObservedObject private var themeManager = ThemeManager.shared

    init(mangaId: Int, mangaTitle: String, siteId: Int?) {
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.siteId = siteId
        _vm = StateObject(wrappedValue: MangaReviewsViewModel(mangaId: mangaId, siteId: siteId))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        // Родной системный заголовок + подзаголовок (.navigationSubtitle —
        // тот же приём, что нужен был для двухстрочной шапки "Отзывы" /
        // название тайтла) + системный back chevron, никакого своего кода
        // (эталон — Настройки/Загрузки).
        .navigationTitle("Отзывы")
        .navigationSubtitle(mangaTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadIfNeeded() }
        .sheet(item: $profileUser) { pu in
            ProfileView(userId: pu.id).preferredColorScheme(themeManager.isDarkTheme ? .dark : .light)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.reviews.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let error = vm.errorMessage, vm.reviews.isEmpty {
            emptyState(icon: "wifi.exclamationmark", text: error)
        } else if vm.reviews.isEmpty && vm.didLoad {
            emptyState(icon: "text.bubble", text: "Отзывов пока нет")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.reviews) { review in
                        reviewCard(review)
                            .onAppear { Task { await vm.loadMoreIfNeeded(current: review) } }
                    }
                    if vm.isLoadingMore {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func reviewCard(_ review: MangaReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                profileUser = ProfileUserId(id: review.user.id)
            } label: {
                HStack(spacing: 8) {
                    RemoteImage(url: review.user.avatarURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").font(.caption2).foregroundStyle(Theme.textSecondary) }
                    } failure: {
                        ZStack { Theme.surfaceElevated; Image(systemName: "person.fill").font(.caption2).foregroundStyle(Theme.textSecondary) }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())

                    Text(review.user.username).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if let date = review.createdAt {
                        Text(date.relativeRussianString).font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if !review.title.isEmpty {
                Text(review.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            }
            if !review.contentText.isEmpty {
                Text(review.contentText).font(.subheadline).foregroundStyle(Theme.textPrimary).lineLimit(6)
            }

            if !review.rating.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(review.rating) { r in
                            VStack(spacing: 2) {
                                Text("\(r.value)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                                Text(r.label).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 14) {
                if let votes = review.votes {
                    Label("\(votes.up - votes.down)", systemImage: "arrow.up").font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
                }
                Label("\(review.commentsCount)", systemImage: "text.bubble").font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
                Label("\(review.views)", systemImage: "eye").font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textSecondary)
            Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

#Preview {
    NavigationStack { MangaReviewsView(mangaId: 1, mangaTitle: "Тайтл", siteId: nil) }.preferredColorScheme(.dark)
}
