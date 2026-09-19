import SwiftUI

/// "Перевод" sub-sheet — opened from ExternalReaderSettingsSheet, same
/// sheet-in-sheet pattern as its "Переключение страниц" (pagingSheet).
/// All settings are external-reader-only (`external_reader_ocr_*` keys),
/// the main app reader is unaffected.
struct ExternalTranslationSettingsSheet: View {
    let readerTheme: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme

    @AppStorage("external_reader_ocr_enabled") private var enabled = false
    @AppStorage("external_reader_ocr_source_lang") private var sourceLang = "auto"
    @AppStorage("external_reader_ocr_target_lang") private var targetLang = "ru"
    @AppStorage("external_reader_ocr_style") private var style = 0
    @AppStorage("external_reader_ocr_stage_b_enabled") private var stageBEnabled = false
    @AppStorage("external_reader_ocr_stage_b_engine") private var stageBEngine = 0
    @AppStorage("external_reader_ocr_stage_b_local_url") private var localURL = ""
    @AppStorage("external_reader_ocr_stage_b_local_model") private var localModel = ""
    @AppStorage("external_reader_ocr_stage_b_cloud_url") private var cloudURL = "https://api.openai.com"
    @AppStorage("external_reader_ocr_stage_b_cloud_model") private var cloudModel = ""

    /// Not @AppStorage — a real secret, goes through the same
    /// KeychainHelper the app already uses for auth tokens (see
    /// AuthSession/PixivProvider), not plain UserDefaults.
    @State private var cloudAPIKey: String = ""
    @State private var connectionState: ConnectionState = .idle

    private enum ConnectionState { case idle, testing, success, failure }

    private static let keychain = KeychainHelper(service: "com.glongq.MangaLib.ocrTranslation")
    private static let cloudAPIKeyAccount = "stageBCloudAPIKey"

    private var palette: ReaderPalette { .make(theme: readerTheme, system: systemColorScheme) }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    toggleRow("Переводить текст на страницах", isOn: $enabled)

                    if enabled {
                        label("Язык оригинала")
                        Picker("", selection: $sourceLang) {
                            Text("Авто").tag("auto")
                            Text("Японский").tag("ja")
                            Text("Корейский").tag("ko")
                            Text("Китайский").tag("zh")
                            Text("Английский").tag("en")
                        }.pickerStyle(.segmented)

                        label("Язык перевода")
                        Picker("", selection: $targetLang) {
                            Text("Русский").tag("ru")
                            Text("Английский").tag("en")
                        }.pickerStyle(.segmented)

                        label("Стиль оверлея")
                        Picker("", selection: $style) {
                            Text("Подложка").tag(0)
                            Text("Только текст").tag(1)
                        }.pickerStyle(.segmented)

                        toggleRow("Улучшать перевод нейросетью", isOn: $stageBEnabled)
                        caption("Дополнительно причёсывает машинный перевод стилистически — подменяет текст на экране через несколько секунд после появления обычного перевода. Недоступность сервера просто не даёт улучшения, без ошибок.")

                        if stageBEnabled {
                            label("Движок")
                            Picker("", selection: $stageBEngine) {
                                Text("Локально (LM Studio)").tag(0)
                                Text("Облачный API").tag(1)
                            }.pickerStyle(.segmented)

                            if stageBEngine == 0 {
                                fieldRow("Адрес LM Studio", text: $localURL, placeholder: "http://192.168.1.23:1234")
                                fieldRow("Модель (опционально)", text: $localModel, placeholder: "")
                            } else {
                                fieldRow("Base URL", text: $cloudURL, placeholder: "https://api.openai.com")
                                secureFieldRow("API-ключ", text: $cloudAPIKey)
                                fieldRow("Модель", text: $cloudModel, placeholder: "gpt-4o-mini")
                            }

                            testConnectionRow
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .tint(Theme.accent)
        .onAppear { cloudAPIKey = Self.keychain.readString(Self.cloudAPIKeyAccount) ?? "" }
        .onChange(of: cloudAPIKey) { _, newValue in
            if newValue.isEmpty {
                Self.keychain.delete(Self.cloudAPIKeyAccount)
            } else {
                Self.keychain.save(newValue, for: Self.cloudAPIKeyAccount)
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("Перевод").font(.headline).foregroundStyle(palette.foreground)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(palette.foreground)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
            }
        }
    }

    private var testConnectionRow: some View {
        HStack(spacing: 12) {
            Button("Проверить соединение") { testConnection() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

            switch connectionState {
            case .idle: EmptyView()
            case .testing: ProgressView()
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func testConnection() {
        guard let client = currentRephraseClient() else {
            connectionState = .failure
            return
        }
        connectionState = .testing
        Task {
            let ok = await client.testConnection()
            await MainActor.run { connectionState = ok ? .success : .failure }
        }
    }

    private func currentRephraseClient() -> RephraseClient? {
        if stageBEngine == 0 {
            guard let url = URL(string: localURL), !localURL.isEmpty else { return nil }
            return RephraseClient(engine: .local(baseURL: url, model: localModel))
        } else {
            guard let url = URL(string: cloudURL), !cloudAPIKey.isEmpty else { return nil }
            return RephraseClient(engine: .cloud(baseURL: url, apiKey: cloudAPIKey, model: cloudModel))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 22.5, weight: .semibold)).foregroundStyle(palette.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(palette.secondary).padding(.horizontal, 4)
    }

    private func toggleRow(_ text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text).foregroundStyle(palette.foreground)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(palette.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(palette.foreground)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func secureFieldRow(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(palette.secondary)
            SecureField("sk-...", text: text)
                .foregroundStyle(palette.foreground)
        }
        .padding(16)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
