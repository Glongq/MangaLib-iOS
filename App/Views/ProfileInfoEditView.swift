import SwiftUI
import PhotosUI

/// «Меню → Настройки → Информация» — реализовано по прямой просьбе, на
/// основе реального перехвата (аватар: 2-шаговая загрузка + PATCH профиля,
/// смена пола, "о себе"). Что РЕАЛЬНО работает, а что нет — см. комментарии
/// у соответствующих полей ниже и итоговое сообщение пользователю в чате.
struct ProfileInfoEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorText: String?

    @State private var username = ""
    @State private var about = ""
    @State private var genderId = 0 // 0 = Не указан — дефолт до загрузки реального профиля

    @State private var avatarURL: URL?
    @State private var avatarFilename: String?
    @State private var isUploadingAvatar = false
    @State private var avatarPickerItem: PhotosPickerItem?

    @State private var backgroundURL: URL?
    @State private var backgroundFilename: String?
    @State private var showBackgroundUploadNotWiredAlert = false

    private static let genders: [(id: Int, label: String)] = [(0, "Не указан"), (1, "Женский"), (2, "Мужской")]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    avatarRow
                    backgroundRow
                    card { textFieldRow(title: "Никнейм", text: $username) }
                    avatarFrameRow
                    genderCard
                    aboutCard

                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Информация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сохранить") { save() }
                    .tint(Theme.accent)
                    .disabled(isLoading || isSaving)
            }
        }
        .task { await load() }
        .onChange(of: avatarPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await uploadPickedAvatar(newItem) }
        }
        .alert("Загрузка фона пока недоступна", isPresented: $showBackgroundUploadNotWiredAlert) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("Эндпоинт загрузки фона профиля не подтверждён перехватом — нужен реальный запрос с устройства, прежде чем это можно будет включить.")
        }
    }

    // MARK: Аватар

    /// Полностью рабочее: POST /upload/image/avatar → filename, затем этот
    /// filename уходит в PATCH при "Сохранить". Мусорка справа — очистка
    /// локально (реально уберётся на сервере после "Сохранить", когда
    /// avatar уйдёт как null — ПОДТВЕРЖДЕНО: null = "без аватара").
    private var avatarRow: some View {
        card {
            HStack(spacing: 14) {
                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    ZStack {
                        Group {
                            if let avatarURL {
                                RemoteImage(url: avatarURL) { $0.resizable().scaledToFill() } placeholder: { placeholderAvatar }
                            } else {
                                placeholderAvatar
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                        if isUploadingAvatar {
                            Circle().fill(.black.opacity(0.4))
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(isUploadingAvatar)

                Text("Изменить аватар").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)

                if avatarFilename != nil {
                    Button {
                        avatarFilename = nil
                        avatarURL = nil
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
        }
    }

    private var placeholderAvatar: some View {
        Circle().fill(Theme.surface).overlay(
            Image(systemName: "person.fill").foregroundStyle(Theme.textSecondary)
        )
    }

    private func uploadPickedAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false; avatarPickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let uploaded = try await MangaNetworkService.shared.uploadAvatarImage(data, filename: "avatar.jpg", mimeType: "image/jpeg")
            avatarFilename = uploaded.filename
            avatarURL = uploaded.url.flatMap(URL.init(string:))
        } catch {
            errorText = "Не удалось загрузить аватар: \(error.localizedDescription)"
        }
    }

    // MARK: Фон

    /// "Изменить фон" — НЕ подключено к сети: эндпоинт загрузки фона ни разу
    /// не встречался в перехватах (только имя поля "cover" в PATCH и
    /// "background" в ответе, но не сам upload-запрос) — гадать URL не
    /// стали. Удаление (мусорка) РЕАЛЬНО работает — использует тот же
    /// подтверждённый PATCH, что и аватар (cover: null).
    private var backgroundRow: some View {
        card {
            Button {
                showBackgroundUploadNotWiredAlert = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                    Text("Изменить фон").foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if backgroundFilename != nil {
                Divider().overlay(Theme.separator).padding(.leading, 16 + 24 + 14)
                HStack(spacing: 14) {
                    Color.clear.frame(width: 24)
                    Text("Убрать текущий фон").foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        backgroundFilename = nil
                        backgroundURL = nil
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }
        }
    }

    // MARK: Рамка аватара

    /// Заглушка — по каталогу рамок (доступные варианты, id, превью, платные
    /// ли) в перехватах нет НИ ОДНОГО значения, только само название поля
    /// avatar_frame_id в запросе полей профиля — построить рабочий выбор не
    /// из чего.
    private var avatarFrameRow: some View {
        NavigationLink {
            StubView(title: "Рамка аватара")
        } label: {
            card {
                HStack(spacing: 14) {
                    Image(systemName: "circle.dashed")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24)
                    Text("Рамка аватара").foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Пол / О себе

    private var genderCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Пол").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Picker("Пол", selection: $genderId) {
                    ForEach(Self.genders, id: \.id) { g in
                        Text(g.label).tag(g.id)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
        }
    }

    private var aboutCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("О себе").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                TextEditor(text: $about)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
        }
    }

    // MARK: Общее

    private func textFieldRow(title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            TextField("", text: text, prompt: Text(title).foregroundColor(Theme.textSecondary))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    // Радиус — эталон из раздела "Меню" (см. SideMenuView.cardCornerRadius).
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: Загрузка / сохранение

    private func load() async {
        guard let userId = AuthSession.shared.userId else { isLoading = false; return }
        do {
            let profile = try await MangaNetworkService.shared.fetchUserProfile(id: userId)
            username = profile.username
            about = profile.about ?? ""
            genderId = profile.genderId ?? 0
            avatarURL = profile.avatarFilename != nil ? profile.avatarURL : nil
            avatarFilename = profile.avatarFilename
            backgroundURL = profile.backgroundFilename != nil ? profile.backgroundURL : nil
            backgroundFilename = profile.backgroundFilename
        } catch {
            errorText = "Не удалось загрузить профиль: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func save() {
        guard let userId = AuthSession.shared.userId else { return }
        isSaving = true
        errorText = nil
        Task {
            do {
                _ = try await MangaNetworkService.shared.updateProfileInfo(
                    userId: userId,
                    avatarFilename: avatarFilename,
                    coverFilename: backgroundFilename,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    genderId: genderId,
                    about: about
                )
                AuthSession.shared.refreshProfile()
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorText = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    NavigationStack { ProfileInfoEditView() }
        .preferredColorScheme(.dark)
}
